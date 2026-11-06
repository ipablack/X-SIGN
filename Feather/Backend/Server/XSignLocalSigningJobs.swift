import Foundation

// Capacity includes registered, queued, running and unclaimed completed jobs.
actor XSignLocalSigningJobs {
    typealias Work = @MainActor @Sendable () async throws -> String
    private enum Phase { case registered, queued, running, finished }
    private struct Entry {
        var work: Work?
        var phase: Phase = .registered
        let registeredAt: TimeInterval
        var result: Result<String, Error>?
        var waiter: CheckedContinuation<String, Error>?
    }
    private let capacity: Int
    private let registrationTTL: TimeInterval
    private var entries: [UUID: Entry] = [:]
    private var queue: [UUID] = []
    private var running = false

    init(capacity: Int = 8, registrationTTL: TimeInterval = 30) {
        self.capacity = capacity
        self.registrationTTL = registrationTTL
    }

    func insert(_ work: @escaping Work) throws -> UUID {
        let now = ProcessInfo.processInfo.systemUptime
        entries = entries.filter { $0.value.phase != .registered || now - $0.value.registeredAt < registrationTTL }
        guard entries.count < capacity else { throw Self.failure(429, "انتظر اكتمال طلبات التوقيع الحالية.") }
        let id = UUID()
        entries[id] = Entry(work: work, registeredAt: now)
        return id
    }

    func submit(_ id: UUID) -> Bool {
        guard var entry = entries[id], entry.phase == .registered,
              ProcessInfo.processInfo.systemUptime - entry.registeredAt < registrationTTL else { return false }
        entry.phase = .queued
        entries[id] = entry
        queue.append(id)
        startNext()
        return true
    }

    func wasAccepted(_ id: UUID) -> Bool {
        guard let entry = entries[id] else { return false }
        return entry.phase != .registered
    }

    func result(for id: UUID) async throws -> String {
        guard let entry = entries[id] else { throw Self.failure(404, "لم تعد مهمة التوقيع متاحة.") }
        guard entry.phase != .registered else { throw Self.failure(409, "لم يتم قبول مهمة التوقيع بعد.") }
        if let result = entry.result { entries.removeValue(forKey: id); return try result.get() }
        guard entry.waiter == nil else { throw Self.failure(409, "يوجد طلب ينتظر هذه المهمة بالفعل.") }
        return try await withCheckedThrowingContinuation { continuation in
            entries[id]?.waiter = continuation
        }
    }

    func removeUnsubmitted(_ id: UUID) {
        guard entries[id]?.phase == .registered else { return }
        let waiter = entries.removeValue(forKey: id)?.waiter
        waiter?.resume(throwing: CancellationError())
    }

    func cancelPending(_ id: UUID) {
        guard let entry = entries[id], entry.phase == .registered || entry.phase == .queued else { return }
        // Native signing already in progress must finish and clean up safely.
        complete(id, result: .failure(CancellationError()))
        queue.removeAll { $0 == id }
    }

    private func startNext() {
        guard !running else { return }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard var entry = entries[id], entry.phase == .queued, let work = entry.work else { continue }
            entry.phase = .running
            entry.work = nil
            entries[id] = entry
            running = true
            Task {
                let result: Result<String, Error>
                do { result = .success(try await work()) }
                catch { result = .failure(error) }
                complete(id, result: result)
                running = false
                startNext()
            }
            return
        }
    }

    private func complete(_ id: UUID, result: Result<String, Error>) {
        guard var entry = entries[id] else { return }
        if let waiter = entry.waiter {
            entries.removeValue(forKey: id)
            waiter.resume(with: result)
        } else {
            entry.phase = .finished
            entry.work = nil
            entry.result = result
            entries[id] = entry
        }
    }

    private static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "XSign.LocalServer", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
