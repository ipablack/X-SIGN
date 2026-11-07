import Foundation

@main struct CertificateSelectionChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 100)
        typealias Candidate = XSignCertificateSelection.Candidate
        let valid = Candidate(expiration: now.addingTimeInterval(60), revoked: false, hasFiles: true)
        let expired = Candidate(expiration: now, revoked: false, hasFiles: true)
        let revoked = Candidate(expiration: now.addingTimeInterval(60), revoked: true, hasFiles: true)
        let missing = Candidate(expiration: now.addingTimeInterval(60), revoked: false, hasFiles: false)
        let unknown = Candidate(expiration: nil, revoked: false, hasFiles: true)
        func choose(_ entries: [Candidate], _ preferred: Int) -> Int? {
            XSignCertificateSelection.index(in: entries, preferred: preferred, now: now)
        }
        precondition(choose([], 0) == nil)
        precondition(choose([expired, revoked, missing, unknown], 0) == nil)
        precondition(choose([valid, valid], 1) == 1)
        precondition(choose([expired, valid], 0) == 1)
        precondition(choose([revoked, valid], 0) == 1)
        precondition(choose([missing, valid], 0) == 1)
        precondition(choose([valid], -1) == 0)
        precondition(choose([valid], 9) == 0)
        precondition(XSignCertificateSelection.index(in: [valid, valid], preferred: 0, bundleMatches: [false, true], now: now) == 1)
        precondition(XSignCertificateSelection.index(in: [valid, valid], preferred: 1, bundleMatches: [true, true], now: now) == 1)
        precondition(XSignCertificateSelection.index(in: [valid, valid], preferred: 1, bundleMatches: [false, false], now: now) == 1)
        precondition(XSignCertificateSelection.index(in: [valid], preferred: 0, bundleMatches: [], now: now) == 0)
        precondition(XSignCertificateSelection.index(in: [expired, valid], preferred: 0, bundleMatches: [true, false], now: now) == 1)
        precondition(XSignCertificateSelection.index(in: [revoked], preferred: 0, bundleMatches: [true], now: now) == nil)
        print("Certificate selection checks passed")
    }
}
