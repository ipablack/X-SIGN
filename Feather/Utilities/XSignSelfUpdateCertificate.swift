import Foundation

@MainActor enum XSignSelfUpdateCertificate {
    struct Requirement: Sendable {
        let installed: XSignSelfUpdateProfile
        let bundleID: String

        func validationError(provision: URL, key: URL, password: String) -> String? {
            guard let profile = try? XSignSelfUpdateProfile.read(provision) else {
                return "تعذّرت قراءة ملف MobileProvision."
            }
            guard profile.canReplace(installed, bundleID: bundleID) else {
                return "اختر MobileProvision سارياً يغطي هذا الجهاز والبندل، ومن نفس فريق التوقيع ومعرّف التطبيق للنسخة المثبّتة."
            }
            guard let values = try? key.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 8_388_608,
                  let data = try? Data(contentsOf: key),
                  XSignSelfUpdateKey.matches(data, password: password, allowed: profile.developerCertificates) else {
                return "ملف P12 أو كلمة المرور غير صالحين لهذا البروفايل. اختر الشهادة المدرجة فيه."
            }
            return nil
        }
    }

    static func select(requirement: Requirement) async -> CertificatePair? {
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
                !Task.isCancelled && requirement.validationError(provision: provision, key: file, password: password) == nil
            }
            let permitted = await withTaskCancellationHandler(operation: { await check.value }, onCancel: { check.cancel() })
            if Task.isCancelled { return nil }
            if permitted, !certificate.isDeleted, !certificate.revoked { return certificate }
        }
        return nil
    }
}
