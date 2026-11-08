import Foundation

struct OTAChecks {
    static func run() async throws {
        let metadata = try XSignOTABundleMetadata(info: ["CFBundleIdentifier": "com.xsign.fixture", "CFBundleVersion": "100",
            "CFBundleShortVersionString": "1.0", "CFBundleDisplayName": "XSign Test"])
        precondition(metadata.version == "100" && metadata.identifier == "com.xsign.fixture")
        do { _ = try XSignOTABundleMetadata(info: ["CFBundleIdentifier": "com.xsign.fixture"]); fatalError("Missing build version accepted") }
        catch XSignOTAError.invalidPackage {}
        let openRange = try XSignOTARange.parse("bytes=8-", size: 16)
        let suffixRange = try XSignOTARange.parse("bytes=-4", size: 16)
        precondition(openRange == XSignOTARange(lower: 8, upper: 15))
        precondition(suffixRange == XSignOTARange(lower: 12, upper: 15))
        do { _ = try XSignOTARange.parse("bytes=1-2,4-5", size: 16); fatalError("Multiple ranges were accepted") }
        catch XSignOTAError.invalidPackage {}
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        let bytes = Data((0..<65536).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let tracking = XSignOTATransfers(size: Int64(bytes.count))
        let installer = XSignOTAInstaller()
        let token = XSignOTACapability.token()
        let payload = try await installer.startLocalServer(package: file, bytes: bytes.count,
            token: token, deadline: ProcessInfo.processInfo.systemUptime + 60, tracking: tracking, update: { _ in })
        precondition(payload.scheme == "http" && payload.host == "127.0.0.1")
        let session = XSignBoundedHTTP.session()
        defer { session.invalidateAndCancel() }
        do {
            let head = try await request(session, payload, method: "HEAD")
            precondition(head.0.isEmpty && head.1.statusCode == 200)
            let afterHead = await tracking.isDownloaded
            precondition(!afterHead)
            let first = try await request(session, payload, range: "bytes=0-7")
            precondition(first.1.statusCode == 206 && first.0 == bytes.prefix(8))
            let partial = await tracking.isDownloaded
            precondition(!partial)
            let (_, denied) = try await request(session, payload, origin: "https://evil.invalid")
            precondition(denied.statusCode == 404)
            let wrong = URL(string: payload.absoluteString.replacingOccurrences(of: token, with: String(repeating: "b", count: 64)))!
            let (_, absent) = try await request(session, wrong)
            precondition(absent.statusCode == 404)
            let second = try await request(session, payload, range: "bytes=8-")
            precondition(second.1.statusCode == 206 && second.0 == bytes.dropFirst(8))
            for _ in 0..<100 {
                let downloaded = await tracking.isDownloaded
                if downloaded { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let complete = await tracking.isDownloaded
            precondition(complete)
            await installer.stopLocalServer()
        } catch { await installer.stopLocalServer(); throw error }
        print("PASS: loopback OTA, HEAD/ranges, private capability and Origin rejection")
    }
    private static func request(_ session: URLSession, _ url: URL, method: String = "GET", range: String? = nil,
                                origin: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let (data, response) = try await session.data(for: request)
        return (data, response as! HTTPURLResponse)
    }
}
