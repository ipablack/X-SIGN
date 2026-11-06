import Foundation

// Local eligibility only; the signing engine still validates the key and profile.
enum XSignCertificateSelection {
    struct Candidate {
        let expiration: Date?
        let revoked: Bool
        let hasFiles: Bool
    }

    static func index(in candidates: [Candidate], preferred: Int, now: Date = Date()) -> Int? {
        func usable(_ index: Int) -> Bool {
            guard candidates.indices.contains(index) else { return false }
            let item = candidates[index]
            return !item.revoked && item.hasFiles && (item.expiration.map { $0 > now } ?? false)
        }
        if usable(preferred) { return preferred }
        return candidates.indices.first(where: usable)
    }
}
