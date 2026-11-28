//
// ZsignHandler.swift
// Feather
//
// Created by samara on 17.04.2025.
// Optimized to run native Zsign operations on detached high-priority background tasks.
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
		let files = _options.disInjectionFiles

		let removed = await Task.detached(priority: .userInitiated) {
			Zsign.removeDylibs(appExecutable: execPath, using: files)
		}.value

		if !removed {
			throw SigningFileHandlerError.disinjectFailed
		}
	}

	func sign(with credentials: Credentials) async throws {
		if let entitlements = _options.appEntitlementsFile {
			_ = try XSignAppMetadata.readInfo(at: entitlements)
		}

		let appURL = _appUrl
		let entitlementsPath = _options.appEntitlementsFile?.path ?? ""
		let removeProvision = _options.removeProvisioning

		let success = try await Task.detached(priority: .userInitiated) {
            let metadata = try XSignOTABundleMetadata.read(from: appURL)
            guard let profile = try? XSignSelfUpdateProfile.read(URL(fileURLWithPath: credentials.provisionPath)) else {
                throw XSignProvisioningProfile.ProfileError.malformed
            }
            guard profile.expiration > Date() else { throw XSignProvisioningProfile.ProfileError.expired }
            guard profile.supports(metadata.identifier) else { throw XSignProvisioningProfile.ProfileError.mismatch }

            let signed = Zsign.sign(
				appPath: appURL.path,
				provisionPath: credentials.provisionPath,
				p12Path: credentials.certificatePath,
				p12Password: credentials.password,
				entitlementsPath: entitlementsPath,
				removeProvision: removeProvision,
				completion: { _ in }
			)
            guard signed else { return false }
            guard let executable = Bundle(url: appURL)?.executableURL,
                  let data = LCGetMachOEntitlements(executable.path),
                  let entitlements = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  entitlements["application-identifier"] as? String == profile.prefix + "." + metadata.identifier,
                  entitlements["com.apple.developer.team-identifier"] as? String == profile.team else {
                throw SigningFileHandlerError.invalidSignedIdentity
            }
            return true
		}.value

		guard success else {
			hadError = SigningFileHandlerError.signFailed
			throw SigningFileHandlerError.signFailed
		}
	}

	func adhocSign() async throws {
		let appPath = _appUrl.relativePath
		let entitlementsPath = _options.appEntitlementsFile?.path ?? ""
		let removeProvision = _options.removeProvisioning

		let success = await Task.detached(priority: .userInitiated) {
			Zsign.sign(
				appPath: appPath,
				entitlementsPath: entitlementsPath,
				adhoc: true,
				removeProvision: removeProvision,
				completion: { _ in }
			)
		}.value

		guard success else {
			hadError = SigningFileHandlerError.signFailed
			throw SigningFileHandlerError.signFailed
		}
	}
}
