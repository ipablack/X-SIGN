import Foundation

@main
struct LocalTransferChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.ipa")
        let chunk = Data(repeating: 0x5a, count: 65_536)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let output = try FileHandle(forWritingTo: file)
        for _ in 0..<128 { try output.write(contentsOf: chunk) }
        try output.write(contentsOf: Data(repeating: 0x17, count: 17))
        try output.close()
        let size = 128 * chunk.count + 17
        var written = 0
        var peak = 0
        var lastProgress = 0.0
        try await IDeviceFileTransfer.stream(from: file, checkCancellation: {}, write: { data in
            peak = max(peak, data.count)
            for byte in data {
                precondition(byte == (written < size - 17 ? 0x5a : 0x17))
                written += 1
            }
        }, progress: { value in
            precondition(value >= lastProgress && value <= 1)
            lastProgress = value
        })
        precondition(written == size && peak <= IDeviceFileTransfer.chunkSize && lastProgress == 1)

        var writes = 0
        do {
            try await IDeviceFileTransfer.stream(from: file, checkCancellation: {
                if writes == 1 { throw CancellationError() }
            }, write: { _ in writes += 1 }, progress: { _ in })
            fatalError("Cancellation was ignored")
        } catch is CancellationError { precondition(writes == 1) }

        writes = 0
        do {
            try await IDeviceFileTransfer.stream(from: file, checkCancellation: {}, write: { _ in
                writes += 1
                throw CocoaError(.fileWriteUnknown)
            }, progress: { _ in fatalError("Failed write reported progress") })
            fatalError("Write failure was ignored")
        } catch { precondition(writes == 1) }

        let empty = root.appendingPathComponent("empty.ipa")
        try Data().write(to: empty)
        do {
            try await IDeviceFileTransfer.stream(from: empty, checkCancellation: {}, write: { _ in
                fatalError("Empty file reached the writer")
            }, progress: { _ in })
            fatalError("Empty file was accepted")
        } catch {}

        writes = 0
        do {
            try await IDeviceFileTransfer.stream(from: file, checkCancellation: {}, write: { _ in
                writes += 1
                let truncated = try FileHandle(forWritingTo: file)
                try truncated.truncate(atOffset: 0)
                try truncated.close()
            }, progress: { _ in })
            fatalError("Truncated input was accepted")
        } catch { precondition(writes == 1) }
        print("PASS: bounded transfer, exact bytes, progress, cancellation, failure and truncation")
    }
}
