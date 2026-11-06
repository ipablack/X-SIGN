import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor Counter {
    var value = 0
    func next() -> Int { value += 1; return value }
}
private actor Latch {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiting.append($0) } } }
    func release() { open = true; waiting.forEach { $0.resume() }; waiting = [] }
}

@main struct LocalSigningServerChecks {
    static func main() async throws {
        let auth = XSignLocalRequestAuthentication()
        let path = "/v1/sign/\(UUID().uuidString)"
        let host = "127.0.0.1:55555"
        let signature = "XSign-HMAC " + auth.signature(path: path, host: host)
        precondition(auth.accepts(signature, path: path, host: host))
        precondition(!auth.accepts(signature, path: path + "changed", host: host))
        precondition(!auth.accepts(signature, path: path, host: "router.local"))
        precondition(!XSignLocalRequestAuthentication().accepts(signature, path: path, host: host))
        precondition(!auth.accepts("Bearer stale-token", path: path, host: host))

        // Capacity must include native work already running, not just unsubmitted jobs.
        let registry = XSignLocalSigningJobs(capacity: 2)
        let latch = Latch()
        let count = Counter()
        let first = try await registry.insert { await latch.wait(); return "job-\(await count.next())" }
        let second = try await registry.insert { "job-\(await count.next())" }
        let initialAccepted = await registry.submit(first)
        precondition(initialAccepted)
        let firstAccepted = await registry.submit(first)
        precondition(!firstAccepted)
        _ = await registry.submit(second)
        do { _ = try await registry.insert { "overflow" }; fatalError("Running job escaped capacity limit") }
        catch { precondition((error as NSError).code == 429) }
        await registry.cancelPending(second)
        do { _ = try await registry.result(for: second); fatalError("Queued cancellation was ignored") }
        catch is CancellationError {}
        await latch.release()
        let firstResult = try await registry.result(for: first)
        precondition(firstResult == "job-1")
        let executed = await count.value
        precondition(executed == 1)
        let late = try await registry.insert { "completed-before-wait" }
        _ = await registry.submit(late)
        let lateResult = try await registry.result(for: late)
        precondition(lateResult == "completed-before-wait")
        let expired = XSignLocalSigningJobs(registrationTTL: 0)
        let expiredID = try await expired.insert { "must-not-run" }
        let expiredAccepted = await expired.submit(expiredID)
        precondition(!expiredAccepted)

        let httpRegistry = XSignLocalSigningJobs()
        let service = XSignLocalSigningServer(jobs: httpRegistry, makeAuthentication: { auth })
        do {
            let endpoint = try await service.startIfNeeded()
            precondition(endpoint.host == "127.0.0.1")
            let expectedHost = "127.0.0.1:\(endpoint.port!)"
            func call(_ id: UUID, authenticated: Bool = true, headers: [String: String] = [:], body: Data = Data()) async throws -> (Data, Int) {
                let path = "/v1/sign/\(id.uuidString)"
                var request = URLRequest(url: endpoint.appendingPathComponent(String(path.dropFirst())))
                request.httpMethod = "POST"
                if authenticated { request.setValue("XSign-HMAC " + auth.signature(path: path, host: expectedHost), forHTTPHeaderField: "Authorization") }
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                request.httpBody = body
                let (data, response) = try await URLSession.shared.data(for: request)
                return (data, (response as! HTTPURLResponse).statusCode)
            }
            let (_, denied) = try await call(UUID(), authenticated: false)
            precondition(denied == 403)
            let (_, originDenied) = try await call(UUID(), headers: ["Origin": "https://example.invalid"])
            precondition(originDenied == 403)
            let (_, compressedDenied) = try await call(UUID(), headers: ["Content-Encoding": "gzip"])
            precondition(compressedDenied == 403)
            let (_, bodyDenied) = try await call(UUID(), body: Data([1]))
            precondition(bodyDenied == 403 || bodyDenied == 413)
            let (_, unknownJob) = try await call(UUID())
            precondition(unknownJob == 409)
            let once = try await httpRegistry.insert { "private-signed-result" }
            let (ack, accepted) = try await call(once)
            precondition(accepted == 202 && ack.isEmpty)
            let (_, replayed) = try await call(once)
            precondition(replayed == 409)
            let result = try await httpRegistry.result(for: once)
            precondition(result == "private-signed-result")
            let (notFile, fileResponse) = try await URLSession.shared.data(from: endpoint.appendingPathComponent("Payload.ipa"))
            precondition((fileResponse as? HTTPURLResponse)?.statusCode == 404 && !notFile.isEmpty)

            let counter = Counter()
            let results = try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<6 { group.addTask { try await service.perform { "signed-\(await counter.next())" } } }
                var values: [String] = []
                for try await result in group { values.append(result) }
                return values
            }
            precondition(Set(results).count == 6)
            do {
                _ = try await service.perform { throw NSError(domain: "Fixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "fixture-signing-error"]) }
                fatalError("Signing failure was lost")
            } catch { precondition(error.localizedDescription == "fixture-signing-error") }
            let afterFailure = try await service.perform { "recovered" }
            precondition(afterFailure == "recovered")
            let stopped = await service.shutdown()
            precondition(stopped)
        } catch { await service.shutdown(); throw error }
        try IPAExtractionChecks.run()
        try await OTAChecks.run()
        try await FeatherManifestChecks.run()
        print("PASS: real loopback HTTP, HMAC, replay/body/origin rejection, bounded serial jobs, cancellation and private results")
    }

}
