import Foundation
import NIOSSL
import Vapor
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Transport identity is public Backloop TLS material, never the user's app-signing identity.
struct XSignOTATLS {
    let hostname: String
    let configuration: TLSConfiguration
    private struct Pack: Decodable {
        struct Info: Decodable { struct Domains: Decodable { let commonName: String }; let domains: Domains }
        let cert: String
        let key1: String
        let key2: String
        let info: Info
    }
    private static var cacheURL: URL { XSignPrivateFiles.root.appendingPathComponent("transport-tls-v1.json") }
    private static func cached(maxAge: TimeInterval) -> Data? {
        guard let values = try? cacheURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size <= 131_072, let date = values.contentModificationDate,
              Date().timeIntervalSince(date) >= 0, Date().timeIntervalSince(date) < maxAge else { return nil }
        return try? Data(contentsOf: cacheURL)
    }
    static func load(session: URLSession, forceRefresh: Bool = false) async throws -> Self {
        if !forceRefresh, let data = cached(maxAge: 21_600), let identity = try? decode(data) { return identity }
        do {
            var request = URLRequest(url: URL(string: "https://backloop.dev/pack.json")!)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await XSignBoundedHTTP.fetch(request, using: session, limit: 131_072)
            guard response.statusCode == 200, response.url?.scheme == "https", response.url?.host == "backloop.dev" else {
                throw XSignOTAError.sslUnavailable
            }
            let identity = try decode(data)
            try? data.write(to: cacheURL, options: .atomic)
            try? XSignPrivateFiles.protect(cacheURL)
            return identity
        } catch {
            if !forceRefresh, let data = cached(maxAge: 604_800), let identity = try? decode(data) { return identity }
            throw XSignOTAError.sslUnavailable
        }
    }
    private static func decode(_ data: Data) throws -> Self {
        guard let pack = try? JSONDecoder().decode(Pack.self, from: data) else { throw XSignOTAError.sslUnavailable }
        let host = pack.info.domains.commonName.lowercased()
        guard host.hasSuffix(".backloop.dev"), !host.contains("*"), host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) }) else {
            throw XSignOTAError.sslUnavailable
        }
        try requireLoopback(host)
        do {
            let certificates = try NIOSSLCertificate.fromPEMBytes(Array(pack.cert.utf8))
            guard !certificates.isEmpty else { throw XSignOTAError.sslUnavailable }
            let key = try NIOSSLPrivateKey(bytes: Array((pack.key1 + "\n" + pack.key2).utf8), format: .pem)
            var tls = TLSConfiguration.makeServerConfiguration(certificateChain: certificates.map { .certificate($0) }, privateKey: .privateKey(key))
            tls.minimumTLSVersion = .tlsv12
            _ = try NIOSSLContext(configuration: tls)
            return Self(hostname: host, configuration: tls)
        } catch { throw XSignOTAError.sslUnavailable }
    }

    static func requireLoopback(_ host: String) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0, let head = first else { throw XSignOTAError.unsafeAddress }
        defer { freeaddrinfo(head) }
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let item = cursor {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else {
                throw XSignOTAError.unsafeAddress
            }
            let literal = String(cString: name)
            guard literal == "::1" || literal.hasPrefix("127.") || literal.hasPrefix("::ffff:127.") else { throw XSignOTAError.unsafeAddress }
            cursor = item.pointee.ai_next
        }
    }
}
