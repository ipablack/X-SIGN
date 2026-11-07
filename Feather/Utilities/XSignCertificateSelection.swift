import Foundation

// Local eligibility only; the signing engine still validates the key and profile.
enum XSignCertificateSelection {
    struct Candidate: Sendable {
        let expiration: Date?
        let revoked: Bool
        let hasFiles: Bool
    }

    static func index(in candidates: [Candidate], preferred: Int, bundleMatches: [Bool], now: Date = Date()) -> Int? {
        let usable = candidates.indices.filter { index(in: [candidates[$0]], preferred: 0, now: now) != nil }
        if usable.contains(preferred), bundleMatches.indices.contains(preferred), bundleMatches[preferred] { return preferred }
        if let compatible = usable.first(where: { bundleMatches.indices.contains($0) && bundleMatches[$0] }) { return compatible }
        // App ID metadata is a hint, not a replacement for native Zsign checks.
        // A missing/legacy/mismatched hint must not reject a usable signing key.
        return usable.contains(preferred) ? preferred : usable.first
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
