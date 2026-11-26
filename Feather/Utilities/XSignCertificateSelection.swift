import Foundation

// Local eligibility only; the signing engine still validates the key and profile.
enum XSignCertificateSelection {
    struct Candidate: Sendable {
        let expiration: Date?
        let revoked: Bool
        let hasFiles: Bool

        func isUsable(at date: Date) -> Bool {
            !revoked && hasFiles && (expiration.map { $0 > date } ?? false)
        }
    }

    static func index(in candidates: [Candidate], preferred: Int, bundleMatches: [Bool], now: Date = Date()) -> Int? {
        index(in: candidates, preferred: preferred, now: now) {
            bundleMatches.indices.contains($0) && bundleMatches[$0]
        }
    }

    static func index(in candidates: [Candidate], preferred: Int, now: Date = Date(),
                      matches: (Int) -> Bool) -> Int? {
        let usable = candidates.indices.filter { candidates[$0].isUsable(at: now) }
        if usable.contains(preferred), matches(preferred) { return preferred }
        if let compatible = usable.first(where: { $0 != preferred && matches($0) }) { return compatible }
        return usable.contains(preferred) ? preferred : usable.first
    }

    static func index(in candidates: [Candidate], preferred: Int, now: Date = Date()) -> Int? {
        func usable(_ index: Int) -> Bool {
            guard candidates.indices.contains(index) else { return false }
            return candidates[index].isUsable(at: now)
        }
        if usable(preferred) { return preferred }
        return candidates.indices.first(where: usable)
    }
}
