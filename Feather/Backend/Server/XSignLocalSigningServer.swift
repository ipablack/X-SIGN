import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor

// HTTP only submits a previously registered in-process job. Keys, IPA bytes and results never enter HTTP.
actor XSignLocalSigningServer {
    static let shared = XSignLocalSigningServer()
    private let jobs: XSignLocalSigningJobs
    private let makeAuthentication: @Sendable () -> XSignLocalRequestAuthentication
    private var authentication: XSignLocalRequestAuthentication?
    private var application: Application?
    private var eventLoops: MultiThreadedEventLoopGroup?
    private var port: Int?
    private var activeCalls = 0
    private var idleShutdown: Task<Void, Never>?
    private let idleSeconds: UInt64
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    init(idleSeconds: UInt64 = 30, jobs: XSignLocalSigningJobs = XSignLocalSigningJobs(),
         makeAuthentication: @escaping @Sendable () -> XSignLocalRequestAuthentication = { XSignLocalRequestAuthentication() }) {
        self.idleSeconds = idleSeconds
        self.jobs = jobs
        self.makeAuthentication = makeAuthentication
    }

    func perform(_ operation: @escaping XSignLocalSigningJobs.Work) async throws -> String {
        try Task.checkCancellation()
        idleShutdown?.cancel()
        activeCalls += 1
        defer { activeCalls -= 1; scheduleIdleShutdown() }
        let endpoint = try startIfNeeded()
        guard let authentication else { throw Self.failure("تعذّر إعداد السيرفر الداخلي.") }
        let id = try await jobs.insert(operation)
        let path = "/v1/sign/\(id.uuidString)"
        let host = "127.0.0.1:\(endpoint.port!)"
        var request = URLRequest(url: endpoint.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue("XSign-HMAC " + authentication.signature(path: path, host: host), forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.httpBody = Data()
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 202, data.isEmpty else {
                throw Self.failure("رفض السيرفر الداخلي طلب التوقيع.")
            }
        } catch {
            // Recover an accepted task even if its short HTTP acknowledgement was lost. Never resend it.
            guard await jobs.wasAccepted(id) else {
                await jobs.removeUnsubmitted(id)
                throw error
            }
        }
        return try await withTaskCancellationHandler(operation: {
            try await jobs.result(for: id)
        }, onCancel: {
            Task { await self.jobs.cancelPending(id) }
        })
    }

    func startIfNeeded() throws -> URL {
        if let port { return URL(string: "http://127.0.0.1:\(port)")! }
        var lastError: Error?
        for _ in 0..<8 {
            let selectedPort = Int.random(in: 49152...65535)
            let loops = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let app = Application(.production, .shared(loops))
            app.logger.logLevel = .critical
            app.threadPool = .init(numberOfThreads: 1)
            app.http.server.configuration.address = .hostname("127.0.0.1", port: selectedPort)
            app.http.server.configuration.reuseAddress = false
            app.http.server.configuration.tcpNoDelay = true
            app.http.server.configuration.requestDecompression = .disabled
            app.http.server.configuration.responseCompression = .disabled
            app.http.server.configuration.supportPipelining = false
            app.http.server.configuration.supportVersions = [.one]
            app.http.server.configuration.backlog = 16
            app.http.server.configuration.shutdownTimeout = .seconds(1)
            app.routes.defaultMaxBodySize = 0
            let expectedHost = "127.0.0.1:\(selectedPort)"
            let auth = makeAuthentication()
            let registry = jobs
            app.post("v1", "sign", ":jobID") { request async throws -> Response in
                guard request.headers["Authorization"].count == 1,
                      request.headers["Host"] == [expectedHost],
                      request.headers["Origin"].isEmpty,
                      request.headers["Transfer-Encoding"].isEmpty,
                      request.headers["Content-Encoding"].isEmpty,
                      request.headers["Upgrade"].isEmpty,
                      request.body.data?.readableBytes ?? 0 == 0,
                      request.url.query == nil,
                      let authorization = request.headers.first(name: .authorization),
                      auth.accepts(authorization, path: request.url.path, host: expectedHost) else {
                    throw Abort(.forbidden)
                }
                guard let value = request.parameters.get("jobID"), let id = UUID(uuidString: value),
                      await registry.submit(id) else { throw Abort(.conflict) }
                return Response(status: .accepted, headers: [
                    "Cache-Control": "no-store", "Connection": "close", "X-Content-Type-Options": "nosniff"
                ])
            }
            do {
                try app.server.start()
                application = app
                eventLoops = loops
                port = selectedPort
                authentication = auth
                scheduleIdleShutdown()
                return URL(string: "http://127.0.0.1:\(selectedPort)")!
            } catch {
                lastError = error
                app.shutdown()
                try? loops.syncShutdownGracefully()
            }
        }
        throw lastError ?? Self.failure("تعذّر فتح منفذ السيرفر الداخلي.")
    }

    @discardableResult
    func shutdown() -> Bool {
        guard activeCalls == 0 else { return false }
        idleShutdown?.cancel()
        idleShutdown = nil
        application?.server.shutdown()
        application?.shutdown()
        try? eventLoops?.syncShutdownGracefully()
        eventLoops = nil
        application = nil
        authentication = nil
        port = nil
        return true
    }

    private func scheduleIdleShutdown() {
        guard activeCalls == 0, let expectedPort = port else { return }
        idleShutdown?.cancel()
        let delay = idleSeconds
        idleShutdown = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            await self?.stopIfUnchanged(expectedPort)
        }
    }

    private func stopIfUnchanged(_ expectedPort: Int) {
        guard port == expectedPort else { return }
        shutdown()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "XSign.LocalServer", code: 500, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
