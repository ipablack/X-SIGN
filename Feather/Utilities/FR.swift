//
//  FR.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation
import OSLog
import UIKit.UIImage
import ZsignC
import NimbleJSON
import NimbleExtensions
import AltSourceKit
import CryptoKit

// MARK: - Serial package work gate
actor FRPackageWorkGate {
    static let shared = FRPackageWorkGate()
    // A private import workspace never needs the native signing engine.
    static let imports = FRPackageWorkGate()
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

    @discardableResult
    static func importPackageFile(
        _ ipa: URL,
        download: Download? = nil,
        sourceProvenance: SourceAppProvenance? = nil,
        consumeTemporaryFile: Bool = false,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            let enqueued = ProcessInfo.processInfo.systemUptime
            await FRPackageWorkGate.imports.acquire()
            let started = ProcessInfo.processInfo.systemUptime
            let handler = AppFileHandler(file: ipa, download: download, sourceProvenance: sourceProvenance, consumeTemporaryFile: consumeTemporaryFile)
            do {
                try Task.checkCancellation()
                try await handler.copy()
                let staged = ProcessInfo.processInfo.systemUptime
                try handler.extract()
                let extracted = ProcessInfo.processInfo.systemUptime
                try Task.checkCancellation()
                try await handler.move()
                try Task.checkCancellation()
                try await handler.addToDatabase()
                try? await handler.clean()
                let uuid = handler.resultUUID
                let finished = ProcessInfo.processInfo.systemUptime
                Logger.misc.info("IPA import timings (s): queue=\(started - enqueued) stage=\(staged - started) unpack=\(extracted - staged) save=\(finished - extracted)")
                await FRPackageWorkGate.imports.release()
                await MainActor.run { completion(.success(uuid)) }
            } catch {
                try? await handler.clean()
                try? FileManager.default.removeItem(at: FileManager.default.unsigned(handler.resultUUID))
                await FRPackageWorkGate.imports.release()
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
        requireRequestedEdits: Bool = false,
        preserveEditedBundleID: Bool = false,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        // Same signing engine path as Feather: native Zsign handler under the
        // existing serial package gate. Installation is a separate server step.
        signPackageFileLocally(app,using:options,icon:icon,certificate:certificate,
            preserveBundleForBatch:preserveBundleForBatch,selfUpdatePermit:selfUpdatePermit,
            requireRequestedEdits:requireRequestedEdits,preserveEditedBundleID:preserveEditedBundleID,completion:completion)
    }

    private static func signPackageFileLocally(
        _ app: AppInfoPresentable,
        using options: Options,
        icon: UIImage?,
        certificate: CertificatePair?,
        preserveBundleForBatch: Bool = false,
        selfUpdatePermit: XSignVerifiedSelfUpdate? = nil,
        requireRequestedEdits: Bool,
        preserveEditedBundleID: Bool,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            await FRPackageWorkGate.shared.acquire()
            @Sendable func finish(_ result: Result<String, Error>) async {
                await FRPackageWorkGate.shared.release()
                await MainActor.run { completion(result) }
            }

            let permittedSelfUpdate = await MainActor.run { selfUpdatePermit?.permits(app) ?? false }
            if !permittedSelfUpdate, let reason = await XSignRemoteManager.shared.prepareProtectedOperation() {
                await finish(.failure(NSError(domain: "XSign.Policy", code: 403,
                    userInfo: [NSLocalizedDescriptionKey: reason])))
                return
            }
            let locks = await MainActor.run { XSignSecurityEnforcer.shared.locks }
            if requireRequestedEdits {
                let deniedMetadata = !locks.allowsAppMetadataEditing &&
                    (options.appName != nil || options.appIdentifier != nil || options.appVersion != nil)
                let deniedIcon = !locks.allowsIconChanges && icon != nil
                let deniedInjection = !locks.allowsLibraryInjection && !options.injectionFiles.isEmpty
                if deniedMetadata || deniedIcon || deniedInjection {
                    await finish(.failure(NSError(domain: "XSign.Policy", code: 403,
                        userInfo: [NSLocalizedDescriptionKey: "تغيّرت صلاحيات التخصيص. حدّث الصلاحيات وراجع التعديلات قبل التوقيع."])))
                    return
                }
            }
            var permittedOptions = options
            var signingCertificate = certificate
            if preserveEditedBundleID { permittedOptions.matchCertificateAppID = false }
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
            if !locks.allowsLibraryInjection {
                permittedOptions.injectionFiles = []
                permittedOptions.experiment_replaceSubstrateWithEllekit = false
            }
            let container = await MainActor.run { Storage.shared.getUuidDirectory(for: app) }
            guard let container, let appDirectory = FileManager.default.getPath(in: container, for: "app") else {
                await finish(.failure(SigningFileHandlerError.appNotFound))
                return
            }
            if permittedOptions.signingOption == .default {
                do {
                    let info = try XSignAppMetadata.readInfo(at: appDirectory.appendingPathComponent("Info.plist"))
                    guard let original = info["CFBundleIdentifier"] as? String, !original.isEmpty else {
                        throw NSError(domain: "XSign.Metadata", code: 400, userInfo: [NSLocalizedDescriptionKey: "ملف معلومات التطبيق لا يحتوي على بندل صالح."])
                    }
                    let current = permittedOptions.appIdentifier ?? original
                    let protectedID = selfUpdatePermit == nil ? Bundle.main.bundleIdentifier : nil
                    if current != original, current == protectedID {
                        throw XSignProvisioningProfile.ProfileError.protectedApplication
                    }
                    if selfUpdatePermit == nil {
                        signingCertificate = await Storage.shared.signingCertificate(for: current, preferred: certificate)
                    }
                    guard let selectedCertificate = signingCertificate else {
                        if preserveEditedBundleID, certificate != nil {
                            throw XSignProvisioningProfile.ProfileError.mismatch
                        }
                        throw SigningFileHandlerError.missingCertifcate
                    }
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
                    await finish(.failure(error))
                    return
                }
            }
            let handler = SigningHandler(app: app, options: permittedOptions, isVerifiedSelfUpdate: permittedSelfUpdate)
            handler.appCertificate = signingCertificate
            handler.appIcon = locks.allowsIconChanges ? icon : nil
            do {
                try handler.copy(from: appDirectory)
                try await handler.modify()
                try? await handler.clean()
                let uuid = handler.resultUUID
                await finish(.success(uuid))
            } catch {
                try? await handler.clean()
                try? FileManager.default.removeItem(at: FileManager.default.signed(handler.resultUUID))
                await finish(.failure(error))
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
