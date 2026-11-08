import Foundation

private final class XSignManifestFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var replaceTitle = false
    static let appName = "تطبيق & <نموذج> + مثال"

    func configure(replaceTitle: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.replaceTitle = replaceTitle
    }

    func response(for request: URLRequest) throws -> (Data, String, Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = request.url, url.scheme == "https", request.httpMethod == "GET",
              (url.host == "api.palera.in" && url.path == "/genPlist") ||
                (url.host == "vip.appiraq.com" && url.path == "/Zsign.php"),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              query.count == 4, let bundle = query.first(where: { $0.name == "bundleid" })?.value,
              let version = query.first(where: { $0.name == "version" })?.value,
              let payload = query.first(where: { $0.name == "fetchurl" })?.value,
              let name = query.first(where: { $0.name == "name" })?.value else { throw URLError(.badURL) }
        let expectedName = url.host == "api.palera.in" ? "تطبيق &amp; &lt;نموذج&gt; + مثال" : Self.appName
        guard name == expectedName else { throw URLError(.badURL) }
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
        let token = String(repeating: "a", count: 64)
        let payload = URL(string: "http://127.0.0.1:52345/ota/\(token)/payload.ipa")!
        let descriptor = XSignOTADescriptor(payloadURL: payload, bundleIdentifier: "com.xsign.fixture",
            bundleVersion: "2.1", title: name, expiresAt: Int(Date().timeIntervalSince1970) + 600)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [XSignManifestFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        precondition(XSignOTAInstallMode.resolve(nil) == .palera)
        precondition(XSignOTAInstallMode.resolve("automatic") == .palera)
        precondition(XSignOTAInstallMode.resolve("xsignDomain") == .palera)
        precondition(XSignOTAInstallMode.resolve("semiLocal") == .semiLocal)

        for (mode, host, path) in [(XSignOTAInstallMode.palera, "api.palera.in", "/genPlist"),
                                  (.semiLocal, "vip.appiraq.com", "/Zsign.php")] {
            let link = try await XSignManifestBridge.prepare(descriptor, mode: mode, session: session)
            precondition(link.scheme == "itms-services")
            let nested = URLComponents(url: link, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value
            let manifest = nested.flatMap { URLComponents(string: $0) }
            precondition(manifest?.host == host && manifest?.path == path)
            precondition(manifest?.queryItems?.first { $0.name == "fetchurl" }?.value == payload.absoluteString)
        }

        XSignManifestFixtureProtocol.state.configure(replaceTitle: true)
        defer { XSignManifestFixtureProtocol.state.configure(replaceTitle: false) }
        do {
            _ = try await XSignManifestBridge.prepare(descriptor, mode: .palera, session: session)
            fatalError("Manifest substituted the app name")
        } catch XSignOTAError.invalidManifest {}
        print("PASS: verified Palera and optional Zsign manifests and migrated legacy defaults")
    }
}
