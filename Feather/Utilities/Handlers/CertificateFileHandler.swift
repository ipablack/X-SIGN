//
//  CertificateFileHandler.swift
//  Feather
//
//  Created by samara on 15.04.2025.
//

import Foundation
import OSLog

final class CertificateFileHandler: NSObject {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	
	private let _key: URL
	private let _provision: URL
	private let _keyPassword: String?
	private let _certNickname: String?
	private let _isDefault: Bool
	
	private var _certPair: Certificate?
	
	init(
		key: URL,
		provision: URL,
		password: String? = nil,
		nickname: String? = nil,
		isDefault: Bool = false
	) {
		self._key = key
		self._provision = provision
		self._keyPassword = password
		self._certNickname = nickname
		self._isDefault = isDefault
		
		_certPair = CertificateReader(provision).decoded
		
		super.init()
	}
	
	func copy() async throws {
		guard
			(_certPair != nil)
		else {
			throw CertificateFileHandlerError.certNotValid
		}
		
        for file in [_key, _provision] {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 8_388_608 else {
                throw CertificateFileHandlerError.certNotValid
            }
        }
		let destinationURL = try await _directory()

		try XSignPrivateFiles.createDirectory(destinationURL)
		try _fileManager.copyItem(at: _key, to: destinationURL.appendingPathComponent("identity.p12"))
		try _fileManager.copyItem(at: _provision, to: destinationURL.appendingPathComponent("identity.mobileprovision"))
        for file in try _fileManager.contentsOfDirectory(at: destinationURL, includingPropertiesForKeys: nil) {
            try _fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try XSignPrivateFiles.protect(file)
        }
	}
	
	@MainActor
	func addToDatabase() async throws {
		
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
		Storage.shared.addCertificate(
			uuid: _uuid,
			password: _keyPassword,
			nickname: _certNickname,
			ppq: _certPair?.PPQCheck ?? false,
			expiration: _certPair?.ExpirationDate ?? Date(),
			isDefault: _isDefault
        ) { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
        }
	}
	
    func cleanAfterFailure() async { try? _fileManager.removeItem(at: _fileManager.certificates(_uuid)) }

	private func _directory() async throws -> URL {
		// Documents/Feather/Certificates/\(UUID)
		_fileManager.certificates(_uuid)
	}
}

private enum CertificateFileHandlerError: Error {
	case certNotValid
}
