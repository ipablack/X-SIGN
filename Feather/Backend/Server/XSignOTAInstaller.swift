import Foundation
import Vapor
import NIOSSL

// A short-lived, loopback-only installation lease consumed by iOS installation. No export UI/API exists.
actor XSignOTAInstaller {
    enum Stage: Sendable { case preparingTLS, preparingDomain, waitingForSystem, delivering, delivered }
    typealias Update = @MainActor @Sendable (Stage) -> Void
    private var application: Application?
    private var loops: MultiThreadedEventLoopGroup?

    func install(package: URL, bundleIdentifier: String, version: String, title: String,
                 update: @escaping Update, open: @escaping @MainActor @Sendable (URL) async -> Bool) async throws {
        let session = XSignBoundedHTTP.session()
        defer { stopLocalServer(); session.invalidateAndCancel() }
        let properties = try package.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let count = properties.fileSize, count > 0 else { throw XSignOTAError.invalidPackage }
        let token=XSignOTACapability.token()
        let tracking=XSignOTATransfers(size:Int64(count))
        let deadline=ProcessInfo.processInfo.systemUptime+2700
        // Feather Semi Local: loopback HTTP payload + their public HTTPS manifest.
        // No pairing, public LAN listener, custom Firebase deployment or SSL pack needed.
        let payloadURL=try startLocalServer(package:package,bytes:count,identity:nil,token:token,
            deadline:deadline,tracking:tracking,update:update)
        var health=URLComponents(url:payloadURL,resolvingAgainstBaseURL:false)!
        health.path="/ota/\(token)/health"
        let (probe,response)=try await XSignBoundedHTTP.fetch(URLRequest(url:health.url!),using:session,limit:128)
        guard response.statusCode==200,probe==Data("XSign OTA".utf8) else { throw XSignOTAError.interrupted }
        await update(.preparingDomain)
        let descriptor = XSignOTADescriptor(payloadURL: payloadURL, bundleIdentifier: bundleIdentifier,
            bundleVersion: version, title: title, expiresAt: Int(Date().timeIntervalSince1970) + 1800)
        let link = try await XSignManifestBridge.prepare(descriptor, session: session)
        try Task.checkCancellation()
        await update(.waitingForSystem)
        guard await open(link) else { throw XSignOTAError.invalidManifest }
        while !(await tracking.isDownloaded) {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw XSignOTAError.timedOut }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        await update(.delivered)
        // Keep a brief retry window. Full transfer is not proof that iOS installed the app successfully.
        try await Task.sleep(nanoseconds: 120_000_000_000)
        await tracking.stop()
    }

    func startLocalServer(package: URL, bytes: Int, identity: XSignOTATLS?, token: String, deadline: TimeInterval,
                       tracking: XSignOTATransfers, update: @escaping Update) throws -> URL {
        for attempt in 0..<8 {
            let port = Int.random(in: 49152...65535)
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let app = Application(.production, .shared(group))
            app.logger.logLevel = .critical
            app.threadPool = .init(numberOfThreads: 1)
            app.http.server.configuration.address = .hostname("127.0.0.1", port: port)
            app.http.server.configuration.reuseAddress = false
            app.http.server.configuration.tcpNoDelay = true
            app.http.server.configuration.backlog = 16
            if let identity { app.http.server.configuration.tlsConfiguration = identity.configuration }
            app.http.server.configuration.supportVersions = [.one]
            app.http.server.configuration.supportPipelining = false
            app.http.server.configuration.requestDecompression = .disabled
            app.http.server.configuration.responseCompression = .disabled
            app.http.server.configuration.shutdownTimeout = .seconds(1)
            app.routes.defaultMaxBodySize = 0
            let host = "\(identity?.hostname ?? "127.0.0.1"):\(port)"
            let scheme=identity.map { _ in "https" } ?? "http"
            let basePath = "/ota/\(token)"
            let allowed: @Sendable (Request, String) -> Bool = { request, suffix in
                ProcessInfo.processInfo.systemUptime < deadline && request.headers["Host"] == [host] &&
                request.headers["Origin"].isEmpty && request.headers["Content-Encoding"].isEmpty &&
                request.headers["Transfer-Encoding"].isEmpty && request.url.query == nil &&
                request.headers["Upgrade"].isEmpty &&
                request.url.path == basePath + suffix && (request.body.data?.readableBytes ?? 0) == 0
            }
            app.get("ota", ":token", "health") { request -> Response in
                guard allowed(request, "/health") else { throw Abort(.notFound) }
                return Response(status: .ok, headers: ["Cache-Control": "no-store"], body: .init(string: "XSign OTA"))
            }
            app.on(.HEAD, "ota", ":token", "payload.ipa") { request -> Response in
                guard allowed(request, "/payload.ipa") else { throw Abort(.notFound) }
                return Response(status: .ok, headers: ["Content-Length": "\(bytes)", "Accept-Ranges": "bytes",
                    "Content-Type": "application/octet-stream", "Cache-Control": "no-store"])
            }
            app.get("ota", ":token", "payload.ipa") { request async throws -> Response in
                guard allowed(request, "/payload.ipa") else { throw Abort(.notFound) }
                let range: XSignOTARange
                do { range = try XSignOTARange.parse(request.headers.first(name: "Range"), size: Int64(bytes)) }
                catch { throw Abort(HTTPResponseStatus(statusCode: 416)) }
                guard await tracking.begin() else { throw Abort(.tooManyRequests) }
                await update(.delivering)
                request.headers.remove(name: "If-None-Match")
                request.headers.remove(name: "If-Modified-Since")
                request.headers.remove(name: "If-Range")
                if request.headers.contains(name: "Range") {
                    request.headers.replaceOrAdd(name: "Range", value: "bytes=\(range.lower)-\(range.upper)")
                }
                let response = request.fileio.streamFile(at: package.path) { result in
                    Task {
                        switch result {
                        case .success: await tracking.finish(range, success: true)
                        case .failure: await tracking.finish(range, success: false)
                        }
                    }
                }
                guard response.status == .ok || response.status == .partialContent else {
                    await tracking.finish(range, success: false)
                    throw Abort(.internalServerError)
                }
                response.headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
                response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
                response.headers.replaceOrAdd(name: "Content-Type", value: "application/octet-stream")
                return response
            }
            do {
                try app.server.start()
                application = app
                loops = group
                return URL(string: "\(scheme)://\(host)\(basePath)/payload.ipa")!
            } catch {
                app.shutdown()
                try? group.syncShutdownGracefully()
                if attempt == 7 { throw XSignOTAError.sslUnavailable }
            }
        }
        throw XSignOTAError.sslUnavailable
    }

    func stopLocalServer() {
        application?.server.shutdown()
        application?.shutdown()
        try? loops?.syncShutdownGracefully()
        application = nil
        loops = nil
    }
}
