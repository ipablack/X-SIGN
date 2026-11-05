import Foundation

// Streams one bounded chunk at a time. C pointers must be consumed inside write().
enum IDeviceFileTransfer {
    static let chunkSize = 2 * 1024 * 1024

    static func stream(
        from url: URL,
        checkCancellation: () throws -> Void,
        write: (Data) throws -> Void,
        progress: (Double) async -> Void
    ) async throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let total = try input.seekToEnd()
        guard total > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try input.seek(toOffset: 0)
        var sent: UInt64 = 0
        var lastPercent = -1
        while sent < total {
            try checkCancellation()
            let count = Int(min(UInt64(chunkSize), total - sent))
            guard let chunk = try input.read(upToCount: count), !chunk.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try write(chunk)
            sent += UInt64(chunk.count)
            let percent = Int(sent * 100 / total)
            if percent != lastPercent {
                lastPercent = percent
                await progress(Double(sent) / Double(total))
            }
        }
    }
}
