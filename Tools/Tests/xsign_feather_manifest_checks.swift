import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class XSignManifestFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var replaceTitle = false
    private var directStatus = 200
    private var foreignURL = false
    static let bundle = "com.xsign.fixture"
    static let version = "2.1"
    static let payload = "http://127.0.0.1:52345/ota/" + String(repeating: "a", count: 64) + "/payload.ipa"
    static let appName = "تطبيق & <نموذج> + مثال"

    func configure(replaceTitle: Bool = false, directStatus: Int = 200, foreignURL: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        self.replaceTitle = replaceTitle
        self.directStatus = directStatus
        self.foreignURL = foreignURL
    }

    func response(for request: URLRequest) throws -> (Data, String, Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = request.url, url.scheme == "https" else { throw URLError(.badURL) }
        if url.host == "x-sign.web.app", url.path == "/native/prepare" {
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Content-Type") == "application/json" else {
                throw URLError(.badURL)
            }
            let host = foreignURL ? "untrusted.example.test" : "x-sign.web.app"
            let data = try JSONSerialization.data(withJSONObject: ["manifestURL": "https://\(host)/native/manifest.plist?ticket=xyz"])
            return (data, "application/json", directStatus)
        }
        if url.host == "x-sign.web.app", url.path == "/native/manifest.plist" {
            guard url.query == "ticket=xyz", request.httpMethod == "GET" else { throw URLError(.badURL) }
            return (try plist(bundle: Self.bundle, version: Self.version, title: Self.appName, payload: Self.payload), "application/xml", 200)
        }
        guard request.httpMethod == "GET", url.host == "api.palera.in", url.path == "/genPlist",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              query.count == 4, let bundle = query.first(where: { $0.name == "bundleid" })?.value,
              let version = query.first(where: { $0.name == "version" })?.value,
              let payload = query.first(where: { $0.name == "fetchurl" })?.value,
              query.first(where: { $0.name == "name" })?.value == "تطبيق &amp; &lt;نموذج&gt; + مثال" else {
            throw URLError(.badURL)
        }
        return (try plist(bundle: bundle, version: version, title: Self.appName, payload: payload), "application/xml", 200)
    }

    private func plist(bundle: String, version: String, title: String, payload: String) throws -> Data {
        let asset = ["kind": "software-package", "url": payload]
        let metadata = ["bundle-identifier": bundle, "bundle-version": version,
                        "kind": "software", "title": replaceTitle ? "Different name" : title]
        let plist: [String: Any] = ["items": [["assets": [asset], "metadata": metadata]]]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

private final class XSignManifestFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = XSignManifestFixture()
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (body, contentType, status) = try Self.state.response(for: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

struct FeatherManifestChecks {
    static func run() async throws {
        let name = XSignManifestFixture.appName
        let payload = URL(string: XSignManifestFixture.payload)!
        let descriptor = XSignOTADescriptor(payloadURL: payload, bundleIdentifier: "com.xsign.fixture",
            bundleVersion: "2.1", title: name, expiresAt: Int(Date().timeIntervalSince1970) + 600)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [XSignManifestFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        precondition(XSignOTAInstallMode.resolve(nil) == .palera)
        precondition(XSignOTAInstallMode.resolve("automatic") == .palera)
        precondition(XSignOTAInstallMode.resolve("xsignDomain") == .xsignDirect)
        precondition(XSignOTAInstallMode.resolve("semiLocal") == .palera)

        for (mode, host, path) in [(XSignOTAInstallMode.palera, "api.palera.in", "/genPlist"),
                                  (.xsignDirect, "x-sign.web.app", "/native/manifest.plist")] {
            let link = try await XSignManifestBridge.prepare(descriptor, mode: mode, session: session)
            precondition(link.scheme == "itms-services")
            let nested = URLComponents(url: link, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value
            let manifest = nested.flatMap { URLComponents(string: $0) }
            precondition(manifest?.host == host && manifest?.path == path)
            if mode == .palera {
                precondition(manifest?.queryItems?.first { $0.name == "fetchurl" }?.value == payload.absoluteString)
            } else {
                precondition(manifest?.queryItems?.first { $0.name == "ticket" }?.value == "xyz")
            }
        }

        XSignManifestFixtureProtocol.state.configure(directStatus: 404)
        let fallback = try await XSignManifestBridge.prepare(descriptor, mode: .xsignDirect, session: session)
        precondition(fallback.absoluteString.contains("api.palera.in"))
        XSignManifestFixtureProtocol.state.configure(foreignURL: true)
        do {
            _ = try await XSignManifestBridge.prepare(descriptor, mode: .xsignDirect, session: session)
            fatalError("The direct manifest must stay on the XSign origin")
        } catch XSignOTAError.invalidManifest {}

        XSignManifestFixtureProtocol.state.configure(replaceTitle: true)
        defer { XSignManifestFixtureProtocol.state.configure(replaceTitle: false) }
        do {
            _ = try await XSignManifestBridge.prepare(descriptor, mode: .palera, session: session)
            fatalError("Manifest substituted the app name")
        } catch XSignOTAError.invalidManifest {}
        print("PASS: verified XSign and Palera manifests, safe fallback and retired preferences")
    }
}
