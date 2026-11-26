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
    struct Credentials: Sendable {
        let provisionPath: String
        let certificatePath: String
        let password: String
    }

	var hadError: Error?
	
	private var _appUrl: URL
	private var _options: Options
	
	init(appUrl: URL, options: Options = OptionsManager.shared.options) {
		self._appUrl = appUrl
		self._options = options
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
	
	func sign(with credentials: Credentials) async throws {
        // Let the embedded Zsign engine validate the real P12/profile assets.
        // Do not reject unrelated apps based on a second Swift App ID check.
        if let entitlements = _options.appEntitlementsFile {
            _ = try XSignAppMetadata.readInfo(at: entitlements)
        }
        let success = Zsign.sign(
            appPath: _appUrl.relativePath,
            provisionPath: credentials.provisionPath,
            p12Path: credentials.certificatePath,
            p12Password: credentials.password,
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
