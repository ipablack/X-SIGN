//
//  ZsignHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import Foundation
import Zsign
import UIKit

final class ZsignHandler {
	var hadError: Error?
	
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
	}
	
	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}
		
		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		if !Zsign.removeDylibs(appExecutable: execPath, using: _options.disInjectionFiles) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}
	
	func sign() async throws {
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}

        let credentials = try await MainActor.run { () throws -> (String, String, String) in
            guard !cert.revoked, cert.expiration.map({ $0 > Date() }) ?? true,
                  let provision = Storage.shared.getFile(.provision, from: cert),
                  let key = Storage.shared.getFile(.certificate, from: cert),
                  FileManager.default.isReadableFile(atPath: provision.path),
                  FileManager.default.isReadableFile(atPath: key.path) else {
                throw NSError(domain: "XSign.Signing", code: 401, userInfo: [NSLocalizedDescriptionKey: "الشهادة غير متاحة أو منتهية أو ملغاة. اختر شهادة صالحة."])
            }
            return (provision.path, key.path, cert.password ?? "")
        }
        if let entitlements = _options.appEntitlementsFile {
            _ = try XSignAppMetadata.readInfo(at: entitlements)
        }
        let success = Zsign.sign(
            appPath: _appUrl.relativePath,
            provisionPath: credentials.0,
            p12Path: credentials.1,
            p12Password: credentials.2,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			removeProvision: _options.removeProvisioning,
			completion: { _ in }
		)
        guard success else {
            hadError = SigningFileHandlerError.signFailed
            throw SigningFileHandlerError.signFailed
        }
	}
	
	func adhocSign() async throws {
		let success = Zsign.sign(
			appPath: _appUrl.relativePath,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			adhoc: true,
			removeProvision: _options.removeProvisioning,
			completion: { _ in }
		)
        guard success else {
            hadError = SigningFileHandlerError.signFailed
            throw SigningFileHandlerError.signFailed
        }
	}
}
