import Foundation

private final class XSignManifestFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: XSignOTADescriptor?
    private var replaceTitle = false
    static let url = URL(string: "https://x-sign.web.app/native/manifest.plist?ticket=fixture")!

    func setReplaceTitle(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        replaceTitle = enabled
    }

    func response(for request: URLRequest) throws -> (Data, String) {
        lock.lock()
        defer { lock.unlock() }
        if request.url?.path == "/native/prepare" {
            guard request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Content-Type") == "application/json" else { throw URLError(.badURL) }
            let body: Data
            if let data = request.httpBody {
                body = data
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 8192)
                let length = stream.read(&buffer, maxLength: 8192)
                guard length > 0 else { throw URLError(.badServerResponse) }
                body = Data(buffer.prefix(length))
            } else { throw URLError(.badServerResponse) }
            descriptor = try JSONDecoder().decode(XSignOTADescriptor.self, from: body)
            return (try JSONSerialization.data(withJSONObject: ["manifestURL": Self.url.absoluteString]), "application/json")
        }

        guard request.url == Self.url, request.httpMethod == "GET", let descriptor else { throw URLError(.badURL) }
        let asset = ["kind": "software-package", "url": descriptor.payloadURL.absoluteString]
        let metadata = ["bundle-identifier": descriptor.bundleIdentifier, "bundle-version": descriptor.bundleVersion,
                        "kind": "software", "title": replaceTitle ? "Different name" : descriptor.title]
        let plist: [String: Any] = ["items": [["assets": [asset], "metadata": metadata]]]
        return (try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), "application/xml")
    }
}

private final class XSignManifestFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = XSignManifestFixture()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "x-sign.web.app" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (body, contentType) = try Self.state.response(for: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
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
        let name = "تطبيق + & اختبار"
        let token = String(repeating: "a", count: 64)
        let payload = URL(string: "https://localhost.backloop.dev:52345/ota/\(token)/payload.ipa")!
        let descriptor = XSignOTADescriptor(payloadURL: payload, bundleIdentifier: "com.xsign.fixture",
            bundleVersion: "2.1", title: name, expiresAt: Int(Date().timeIntervalSince1970) + 600)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [XSignManifestFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let link = try await XSignManifestBridge.prepare(descriptor, session: session)
        precondition(link.scheme == "itms-services")
        let nested = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
        precondition(nested == XSignManifestFixture.url.absoluteString)

        XSignManifestFixtureProtocol.state.setReplaceTitle(true)
        defer { XSignManifestFixtureProtocol.state.setReplaceTitle(false) }
        do {
            _ = try await XSignManifestBridge.prepare(descriptor, session: session)
            fatalError("Manifest substituted the app name")
        } catch XSignOTAError.invalidManifest {}
        print("PASS: XSign HTTPS manifest handoff preserves the signed app name and rejects a substituted title")
    }
}
