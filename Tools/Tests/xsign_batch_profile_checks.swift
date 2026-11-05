import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct TestFailure: Error, CustomStringConvertible { let description: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) throws {
    if !condition() { throw TestFailure(description:"Line \(line): " + message) }
}
private func reject(_ message: String, _ operation: () throws -> Void) throws {
    var rejected = false
    do { try operation() } catch { rejected = true }
    try check(rejected, message)
}

@main struct BatchProfileChecks {
    @MainActor static func main() async {
        setbuf(stdout,nil); setbuf(stderr,nil)
        do { try profileChecks(); try await queueChecks() }
        catch { fputs("TEST FAILURE: \(error)\n",stderr); exit(EXIT_FAILURE) }
    }
    static func profileChecks() throws {
        let now = Date()
        func profile(_ id: String, prefix: String = "TEAM", binary: Bool = false, expires: Date? = nil) throws -> XSignProvisioningProfile {
            let data = try PropertyListSerialization.data(fromPropertyList:[
                "ApplicationIdentifierPrefix":[prefix], "TeamIdentifier":["OTHERTEAM"],
                "ExpirationDate":expires ?? now.addingTimeInterval(3600), "Entitlements":["application-identifier":id]
            ],format:binary ? .binary : .xml,options:0)
            return try XSignProvisioningProfile.decode(binary ? data : Data([0x30,0x82,0x00])+data+Data([1,2,3,4]))
        }
        let exact = try profile("TEAM.com.example.personal")
        try check(exact.bundlePattern == "com.example.personal", "Incorrect App ID prefix removal")
        let matched = try exact.identifier(for:"org.original.app",matchExactID:true,now:now)
        try check(matched == "com.example.personal", "Explicit profile did not supply its own bundle")
        try reject("Mismatched explicit profile was accepted") { _ = try exact.identifier(for:"org.other.app",matchExactID:false,now:now) }
        let wildcard = try profile("TEAM.com.example.*", binary:true)
        let unchanged = try wildcard.identifier(for:"com.example.app",matchExactID:true,now:now)
        try check(unchanged == "com.example.app", "Wildcard changed a valid bundle")
        try reject("Wildcard accepted a different prefix") { _ = try wildcard.identifier(for:"com.examples.app",matchExactID:true,now:now) }
        try reject("Wildcard accepted an empty suffix") { _ = try wildcard.identifier(for:"com.example.",matchExactID:true,now:now) }
        let all = try profile("TEAM.*")
        let retained = try all.identifier(for:"org.example.app",matchExactID:true,now:now)
        try check(retained == "org.example.app", "Global wildcard changed the bundle")
        let legacy = try profile("OLDPREFIX.com.example.legacy",prefix:"OLDPREFIX")
        try check(legacy.bundlePattern == "com.example.legacy", "Legacy App ID prefix was confused with Team ID")
        let expired = try profile("TEAM.com.example.app", expires:now.addingTimeInterval(-1))
        try reject("Expired profile was accepted") { _ = try expired.identifier(for:"com.example.app",matchExactID:true,now:now) }
        try reject("Malformed App ID wildcard accepted") { _ = try profile("TEAM.com.*.app") }
        try reject("Wrong App ID prefix accepted") { _ = try profile("EVIL.com.example.app") }
        for bad in [Data(),Data("not XML".utf8),Data("<?xml version=\"1.0\"?><plist>".utf8)] {
            try reject("Malformed profile was accepted") { _ = try XSignProvisioningProfile.decode(bad) }
        }
        print("PASS: real profile parsing from CMS-wrapped XML/binary plist, legacy prefixes, exact/wildcard matching, expiration and malformed input")
    }

    @MainActor static func idle<T>(_ queue: XSignBatchQueue<T>) async throws {
        for _ in 0..<2000 {
            if !queue.isRunning { return }
            try await Task.sleep(nanoseconds:1_000_000)
        }
        throw TestFailure(description:"Batch did not finish")
    }
    @MainActor static func queueChecks() async throws {
        let queue = XSignBatchQueue(items:[1,2,3])
        var order:[Int] = []; var active = 0; var peak = 0; var publications = 0
        queue.onChange = { publications += 1 }
        queue.start { number in
            active += 1; peak = max(peak,active); defer { active -= 1 }
            order.append(number)
            try await Task.sleep(nanoseconds:1_000_000)
            if number == 2 { throw TestFailure(description:"Expected test failure") }
            return "signed-\(number)"
        }
        queue.start { _ in throw TestFailure(description:"Duplicate start was allowed") }
        queue.prepareRetry() // A running batch must remain immutable.
        try await idle(queue)
        try check(order == [1,2,3] && peak == 1 && active == 0, "Jobs overlapped or duplicate start modified the queue")
        try check(queue.entries[0].state == .succeeded("signed-1"), "First signed UUID was lost")
        try check(queue.entries[1].state.isRetryable && queue.entries[2].state == .succeeded("signed-3"), "Failure stopped later apps")
        queue.prepareRetry()
        queue.start { number in order.append(number); return "retried-\(number)" }
        try await idle(queue)
        try check(order == [1,2,3,2], "Retry re-signed successful apps")
        try check(queue.entries[1].state == .succeeded("retried-2") && publications > 0, "Retry result/publication missing")

        let cancellable = XSignBatchQueue(items:[1,2,3])
        var resume: CheckedContinuation<Void,Never>?
        var cancelOrder:[Int] = []
        cancellable.start { number in
            cancelOrder.append(number)
            if number == 1 { await withCheckedContinuation { resume = $0 } }
            return "signed-\(number)"
        }
        for _ in 0..<2000 where resume == nil { try await Task.sleep(nanoseconds:1_000_000) }
        guard let continuation = resume else { throw TestFailure(description:"First batch operation did not start") }
        cancellable.stopAfterCurrent()
        try check(cancellable.isRunning, "Stop interrupted the operation owning temporary files")
        continuation.resume()
        try await idle(cancellable)
        try check(cancelOrder == [1] && cancellable.entries[0].state == .succeeded("signed-1"), "Stop lost the completed result or started another job")
        try check(cancellable.entries.dropFirst().allSatisfy { $0.state == .cancelled }, "Pending jobs were not cancelled")
        cancellable.prepareRetry()
        cancellable.start { number in cancelOrder.append(number); return "signed-\(number)" }
        try await idle(cancellable)
        try check(cancelOrder == [1,2,3], "Resuming pending jobs repeated completed work")
        let empty = XSignBatchQueue<Int>(items:[])
        empty.start { _ in "unused" }
        try check(!empty.isRunning, "Empty queue remained busy")
        print("PASS: actual batch queue signs serially, continues after an error, retries failed/pending apps only, keeps exact result UUIDs and stops safely after the current app")
    }
}
