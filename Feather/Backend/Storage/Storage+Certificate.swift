//
//  Storage+Certificate.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator
import Zsign

// MARK: - Class extension: certificate
extension Storage {
	func addCertificate(
		uuid: String,
		password: String? = nil,
		nickname: String? = nil,
		ppq: Bool = false,
		expiration: Date,
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		let generator = UIImpactFeedbackGenerator(style: .light)
		
		let new = CertificatePair(context: context)
		new.uuid = uuid
		new.date = Date()
		new.password = XSignCertificateSecrets.marker
		new.ppQCheck = ppq
		new.expiration = expiration
		new.nickname = nickname
		new.isDefault = isDefault
        do {
            try XSignCertificateSecrets.save(password ?? "", uuid: uuid)
            try saveContextNow()
            revokagedCertificate(for: new)
            generator.impactOccurred()
            completion(nil)
        } catch {
            XSignCertificateSecrets.delete(uuid: uuid)
            context.delete(new)
            completion(error)
        }
	}
	
	func deleteCertificate(for cert: CertificatePair) {
        if let uuid = cert.uuid { XSignCertificateSecrets.delete(uuid: uuid) }
		if let url = getUuidDirectory(for: cert) {
			try? FileManager.default.removeItem(at: url)
		}
		context.delete(cert)
		saveContext()
	}
	
	func getCertificate(for index: Int) -> CertificatePair? {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]

		guard
			let results = try? context.fetch(fetchRequest),
			index >= 0 && index < results.count
		else {
			return nil
		}
		
		return results[index]
	}
	
	func revokagedCertificate(for cert: CertificatePair) {
		guard !cert.revoked else { return }
		
        guard let password = try? signingPassword(for: cert) else { return }
		Zsign.checkRevokage(
			provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
			p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
			p12Password: password
		) { (status, _, _) in
			if status == 1 {
				DispatchQueue.main.async {
					cert.revoked = true
					self.saveContext()
				}
			}
		}
	}
	
	enum FileRequest: String {
		case certificate = "p12"
		case provision = "mobileprovision"
	}
	
	func getFile(_ type: FileRequest, from cert: CertificatePair) -> URL? {
		guard let url = getUuidDirectory(for: cert) else {
			return nil
		}
		
		return FileManager.default.getPath(in: url, for: type.rawValue)
	}
	
	func getProvisionFileDecoded(for cert: CertificatePair) -> Certificate? {
		guard let url = getFile(.provision, from: cert) else {
			return nil
		}
		
		let read = CertificateReader(url)
		return read.decoded
	}
	
	func getUuidDirectory(for cert: CertificatePair) -> URL? {
		guard let uuid = cert.uuid else {
			return nil
		}
		
		return FileManager.default.certificates(uuid)
	}
	
    func signingPassword(for certificate: CertificatePair) throws -> String {
        guard let uuid = certificate.uuid else { throw SigningFileHandlerError.missingCertifcate }
        if certificate.password != XSignCertificateSecrets.marker {
            try XSignCertificateSecrets.save(certificate.password ?? "", uuid: uuid)
            let legacy = certificate.password
            certificate.password = XSignCertificateSecrets.marker
            do { try saveContextNow() }
            catch { certificate.password = legacy; throw error }
        }
        return try XSignCertificateSecrets.read(uuid: uuid)
    }

    func migrateSigningPasswords() throws {
        for certificate in getAllCertificates() where certificate.password != XSignCertificateSecrets.marker {
            _ = try signingPassword(for: certificate)
        }
    }

    func activeSigningCertificate(preferredIndex: Int? = nil) -> CertificatePair? {
        let certificates = getAllCertificates()
        let candidates = certificates.map { certificate in
            XSignCertificateSelection.Candidate(
                expiration: certificate.expiration,
                revoked: certificate.revoked,
                hasFiles: [FileRequest.certificate, .provision].allSatisfy { type in
                    guard let file = getFile(type, from: certificate) else { return false }
                    return FileManager.default.isReadableFile(atPath: file.path)
                }
            )
        }
        guard let index = XSignCertificateSelection.index(
            in: candidates,
            preferred: preferredIndex ?? UserDefaults.standard.integer(forKey: "feather.selectedCert")
        ) else { return nil }
        return certificates[index]
    }

    @MainActor
    func signingCertificate(for bundleID: String, preferred: CertificatePair?) async -> CertificatePair? {
        let certificates = getAllCertificates()
        let preferredIndex = certificates.firstIndex { $0.uuid == preferred?.uuid }
            ?? UserDefaults.standard.integer(forKey: "feather.selectedCert")
        let candidates = certificates.map { certificate in
            XSignCertificateSelection.Candidate(expiration: certificate.expiration, revoked: certificate.revoked,
                hasFiles: [FileRequest.certificate, .provision].allSatisfy { type in
                    getFile(type, from: certificate).map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
                })
        }
        let profiles = certificates.map { getFile(.provision, from: $0) }
        let selected = await Task.detached(priority: .userInitiated) {
            let matches = profiles.map { url -> Bool in
                guard let url, let profile = try? XSignProvisioningProfile.read(at: url) else { return false }
                return (try? profile.identifier(for: bundleID, matchExactID: false)) != nil
            }
            return XSignCertificateSelection.index(in: candidates, preferred: preferredIndex, bundleMatches: matches)
        }.value
        guard let selected, certificates.indices.contains(selected), !certificates[selected].isDeleted else { return nil }
        return certificates[selected]
    }

	func getAllCertificates() -> [CertificatePair] {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
		return (try? context.fetch(fetchRequest)) ?? []
	}
}
