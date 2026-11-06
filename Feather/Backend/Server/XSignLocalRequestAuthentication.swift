import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
// Crypto 3.x predates Sendable annotations; this server generation never mutates its key.
@preconcurrency import Crypto
#endif

struct XSignLocalRequestAuthentication: Sendable {
    private let key = SymmetricKey(size: .bits256)

    func signature(path: String, host: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: message(path: path, host: host), using: key)).base64EncodedString()
    }

    func accepts(_ authorization: String, path: String, host: String) -> Bool {
        let prefix = "XSign-HMAC "
        guard authorization.hasPrefix(prefix), authorization.utf8.count == prefix.utf8.count + 44,
              let bytes = Data(base64Encoded: String(authorization.dropFirst(prefix.count))) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: message(path: path, host: host), using: key)
    }

    private func message(path: String, host: String) -> Data { Data("POST\n\(host)\n\(path)".utf8) }
}
