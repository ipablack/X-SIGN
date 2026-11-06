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
                  let profile=try? XSignSelfUpdateProfile.read(provision),profile.canReplace(installed,bundleID:bundleID),
                  let file=storage.getFile(.certificate,from:certificate),
                  let values=try? file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey]),
                  values.isRegularFile == true,values.isSymbolicLink != true,(values.fileSize ?? Int.max)<=8_388_608,
                  let data=try? Data(contentsOf:file),let password=try? storage.signingPassword(for:certificate) else { continue }
            let permitted=await Task.detached(priority:.userInitiated) {
                XSignSelfUpdateKey.matches(data,password:password,allowed:profile.developerCertificates)
            }.value
            if Task.isCancelled { return nil }
            if permitted { return certificate }
        }
        return nil
    }
}
