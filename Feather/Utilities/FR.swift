//
//  FR.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import UIKit.UIImage
import ZsignC
import NimbleJSON
import AltSourceKit
import IDeviceSwift
import CryptoKit

// MARK: - Serial package work gate
private actor FRPackageWorkGate {
    static let shared = FRPackageWorkGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

enum FR {
    static func handlePackageFile(
        _ ipa: URL,
        download: Download? = nil,
        sourceProvenance: SourceAppProvenance? = nil,
        consumeTemporaryFile: Bool = false,
        completion: @escaping (Error?) -> Void
    ) {
        importPackageFile(ipa, download: download, sourceProvenance: sourceProvenance, consumeTemporaryFile: consumeTemporaryFile) { result in
            switch result {
            case .success: completion(nil)
            case .failure(let error): completion(error)
            }
        }
    }

    static func importPackageFile(
        _ ipa: URL,
        download: Download? = nil,
        sourceProvenance: SourceAppProvenance? = nil,
        consumeTemporaryFile: Bool = false,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        Task.detached {
            await FRPackageWorkGate.shared.acquire()
            let handler = AppFileHandler(file: ipa, download: download, sourceProvenance: sourceProvenance, consumeTemporaryFile: consumeTemporaryFile)
            do {
                try await handler.copy()
                try await handler.extract()
                try await handler.move()
                try await handler.addToDatabase()
                try? await handler.clean()
                let uuid = handler.resultUUID
                await FRPackageWorkGate.shared.release()
                await MainActor.run { completion(.success(uuid)) }
            } catch {
                try? await handler.clean()
                try? FileManager.default.removeItem(at: FileManager.default.unsigned(handler.resultUUID))
                await FRPackageWorkGate.shared.release()
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    static func signPackageFile(
        _ app: AppInfoPresentable,
        using options: Options,
        icon: UIImage?,
        certificate: CertificatePair?,
        completion: @escaping (Error?) -> Void
    ) {
        signPackageFileWithResult(app, using: options, icon: icon, certificate: certificate) { result in
            switch result {
            case .success: completion(nil)
            case .failure(let error): completion(error)
            }
        }
    }

    static func signPackageFileWithResult(
        _ app: AppInfoPresentable,
        using options: Options,
        icon: UIImage?,
        certificate: CertificatePair?,
        preserveBundleForBatch: Bool = false,
        selfUpdatePermit: XSignVerifiedSelfUpdate? = nil,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        // Same signing engine path as Feather: native Zsign handler under the
        // existing serial package gate. Installation is a separate server step.
        signPackageFileLocally(app,using:options,icon:icon,certificate:certificate,
            preserveBundleForBatch:preserveBundleForBatch,selfUpdatePermit:selfUpdatePermit,completion:completion)
    }

    private static func signPackageFileLocally(
        _ app: AppInfoPresentable,
        using options: Options,
        icon: UIImage?,
        certificate: CertificatePair?,
        preserveBundleForBatch: Bool = false,
        selfUpdatePermit: XSignVerifiedSelfUpdate? = nil,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        Task.detached {
            await FRPackageWorkGate.shared.acquire()
            let permittedSelfUpdate = await MainActor.run { selfUpdatePermit?.permits(app) ?? false }
            if !permittedSelfUpdate, let reason = await XSignRemoteManager.shared.prepareProtectedOperation() {
                await FRPackageWorkGate.shared.release()
                await MainActor.run { completion(.failure(NSError(domain: "XSign.Policy", code: 403,
                    userInfo: [NSLocalizedDescriptionKey: reason]))) }
                return
            }
            let locks = await MainActor.run { XSignSecurityEnforcer.shared.locks }
            var permittedOptions = options
            var signingCertificate = certificate
            if !locks.allowsAppMetadataEditing {
                permittedOptions.appName = nil
                permittedOptions.appIdentifier = nil
                permittedOptions.matchCertificateAppID = false
                permittedOptions.appVersion = nil
                permittedOptions.identifiers = [:]
                permittedOptions.displayNames = [:]
                permittedOptions.ppqProtection = false
                permittedOptions.dynamicProtection = false
                permittedOptions.changeLanguageFilesForCustomDisplayName = false
            }
            permittedOptions.appName = permittedOptions.appName?.trimmingCharacters(in: .whitespacesAndNewlines)
            permittedOptions.appIdentifier = permittedOptions.appIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            permittedOptions.appVersion = permittedOptions.appVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
            if locks.lock_dylib_injection ?? true {
                permittedOptions.injectionFiles = []
                permittedOptions.experiment_replaceSubstrateWithEllekit = false
            }
            if permittedOptions.signingOption == .default {
                do {
                    let original = try await MainActor.run { () throws -> String in
                        guard let directory = Storage.shared.getAppDirectory(for: app) else {
                            throw SigningFileHandlerError.appNotFound
                        }
                        let info = try XSignAppMetadata.readInfo(at: directory.appendingPathComponent("Info.plist"))
                        guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
                            throw NSError(domain: "XSign.Metadata", code: 400, userInfo: [NSLocalizedDescriptionKey: "ملف معلومات التطبيق لا يحتوي على بندل صالح."])
                        }
                        return identifier
                    }
                    let current = permittedOptions.appIdentifier ?? original
                    let protectedID = selfUpdatePermit == nil ? Bundle.main.bundleIdentifier : nil
                    if current != original, current == protectedID {
                        throw XSignProvisioningProfile.ProfileError.protectedApplication
                    }
                    if selfUpdatePermit == nil {
                        signingCertificate = await Storage.shared.signingCertificate(for: current, preferred: certificate)
                    }
                    guard let selectedCertificate = signingCertificate else { throw SigningFileHandlerError.missingCertifcate }
                    if permittedOptions.matchCertificateAppID == true, locks.allowsAppMetadataEditing, selfUpdatePermit == nil,
                       let url = await MainActor.run(body: { Storage.shared.getFile(.provision, from: selectedCertificate) }),
                       let profile = try? XSignProvisioningProfile.read(at: url),
                       let resolved = try? profile.signingIdentifier(for: current, allowRemap: true,
                           metadataEditingAllowed: true, preserveBatchIdentity: preserveBundleForBatch, protectedIdentifier: protectedID) {
                        if resolved != original { permittedOptions.appIdentifier = resolved }
                        if !profile.isWildcard {
                            permittedOptions.ppqProtection = false
                            permittedOptions.dynamicProtection = false
                        }
                    }
                } catch {
                    await FRPackageWorkGate.shared.release()
                    await MainActor.run { completion(.failure(error)) }
                    return
                }
            }
            let handler = SigningHandler(app: app, options: permittedOptions, isVerifiedSelfUpdate: permittedSelfUpdate)
            handler.appCertificate = signingCertificate
            handler.appIcon = (locks.lock_icon_change ?? true) ? nil : icon
            do {
                try await handler.copy()
                try await handler.modify()
                try? await handler.clean()
                let uuid = handler.resultUUID
                await FRPackageWorkGate.shared.release()
                await MainActor.run { completion(.success(uuid)) }
            } catch {
                try? await handler.clean()
                try? FileManager.default.removeItem(at: FileManager.default.signed(handler.resultUUID))
                await FRPackageWorkGate.shared.release()
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

	static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String = "",
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = CertificateFileHandler(
				key: p12URL,
				provision: provisionURL,
				password: p12Password,
				nickname: certificateName.isEmpty ? nil : certificateName,
				isDefault: isDefault
			)

			do {
				try await handler.copy()
				try await handler.addToDatabase()
				await MainActor.run {
					completion(nil)
				}
			} catch {
                await handler.cleanAfterFailure()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}

	static func checkPasswordForCertificate(
		for key: URL,
		with password: String,
		using provision: URL
	) -> Bool {
		defer {
			password_check_fix_free(provision.path)
		}

		password_check_fix(provision.path)

		if (!p12_password_check(key.path, password)) {
			return false
		}

		return true
	}

    static func handleSource(_ urlString: String, onFailure: ((Error) -> Void)? = nil, competion: @escaping () -> Void) {
        guard let input = XSignManagedSource.httpsURL(urlString) else {
            onFailure?(XSignCatalogError.invalidURL)
            return
        }
        let url = XSignCatalogIO.canonicalURL(input)
        Task { @MainActor in
            guard XSignRemoteManager.shared.config?.dashboard?.userSourcesEnabled != false else {
                let error=NSError(domain:"XSign.Sources",code:403,userInfo:[NSLocalizedDescriptionKey:"إضافة مصادر شخصية متوقفة من إدارة المتجر."])
                if let onFailure { onFailure(error) }
                else { UIAlertController.showAlertWithOk(title:"المصادر",message:error.localizedDescription) }
                return
            }
            do {
                let record = try await XSignCatalogIO.shared.fetch(url)
                let existing = Storage.shared.getSources().first { $0.sourceURL.map(XSignCatalogIO.canonicalURL) == url }
                let identifier = existing?.identifier ?? "xsign.user." + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
                let finish: (Error?) -> Void = { error in
                    if let error {
                        if let onFailure { onFailure(error) }
                        else { UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription) }
                        return
                    }
                    XSignDashboardSources.registerUser(url)
                    let sources = Storage.shared.getSources()
                    if let source = sources.first(where: { source in
                        source.sourceURL.map { XSignCatalogIO.canonicalURL($0) == url } == true || source.identifier == identifier
                    }) {
                        SourcesViewModel.shared.seed(record, for: source)
                    }
                    AppStoreCacheManager.shared.acceptRepository(record, from: url)
                    AppStoreCacheManager.shared.rebuildCacheIfNeeded(sources: sources, repositoriesMap: SourcesViewModel.shared.sources)
                    competion()
                    Task { @MainActor in
                        await AppStoreCacheManager.shared.ensureFetched(sources: sources, viewModel: .shared)
                    }
                }
                if Storage.shared.sourceExists(identifier) { finish(nil) }
                else { Storage.shared.addSource(url, repository: record.repository, id: identifier, completion: finish) }
            } catch {
                if let onFailure { onFailure(error) }
                else { UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription) }
            }
        }
    }

}
