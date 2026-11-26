import Foundation

@MainActor enum XSignSelfUpdateCertificate {
    static func select(installed:XSignSelfUpdateProfile,bundleID:String) async -> CertificatePair? {
        let storage=Storage.shared
        var certificates=storage.getAllCertificates()
        if let active=storage.activeSigningCertificate(),let index=certificates.firstIndex(where:{ $0.uuid==active.uuid }) {
            certificates.remove(at:index);certificates.insert(active,at:0)
        }
        for certificate in certificates {
            guard !certificate.revoked,certificate.expiration.map({ $0>Date() }) == true,
                  let provision=storage.getFile(.provision,from:certificate),
                  let file = storage.getFile(.certificate, from: certificate),
                  let password = try? storage.signingPassword(for: certificate) else { continue }
            let check = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled,
                      let profile = try? XSignSelfUpdateProfile.read(provision),
                      profile.canReplace(installed, bundleID: bundleID),
                      let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 0, size <= 8_388_608,
                      let data = try? Data(contentsOf: file), !Task.isCancelled else { return false }
                return XSignSelfUpdateKey.matches(data, password: password, allowed: profile.developerCertificates)
            }
            let permitted = await withTaskCancellationHandler(operation: { await check.value }, onCancel: { check.cancel() })
            if Task.isCancelled { return nil }
            if permitted, !certificate.isDeleted, !certificate.revoked { return certificate }
        }
        return nil
    }
}
