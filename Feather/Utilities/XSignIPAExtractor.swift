import Foundation
import ZIPFoundation

// Bounded extraction into a fresh private directory. Never restore archive symlinks or special files.
enum XSignIPAExtractor {
    struct Limits {
        var entries = 100_000
        var expandedBytes: UInt64 = 16 * 1024 * 1024 * 1024
        var fileBytes: UInt64 = 8 * 1024 * 1024 * 1024
        var diskReserve: UInt64 = 256 * 1024 * 1024
    }
    enum InvalidArchive: LocalizedError {
        case unsafePath, unsupportedLink, tooLarge, insufficientDisk, corrupt, missingPayload
        var errorDescription: String? {
            switch self {
            case .unsafePath: return "يحتوي IPA على مسار غير آمن أو ملفات متعارضة."
            case .unsupportedLink: return "يحتوي IPA على رابط رمزي غير مدعوم؛ تم إيقاف الاستيراد لحماية الملفات."
            case .tooLarge: return "يتجاوز IPA حدود حجم أو عدد الملفات الآمنة."
            case .insufficientDisk: return "لا توجد مساحة كافية لفك IPA بأمان."
            case .corrupt: return "محتوى IPA تالف أو لا يطابق حجمه وبصمته."
            case .missingPayload: return "يجب أن يحتوي IPA على تطبيق رئيسي واحد داخل Payload."
            }
        }
    }

    private static func components(_ path: String, directory: Bool) throws -> [String] {
        let clean = directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = clean.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !clean.isEmpty, clean.utf8.count <= 1024, !clean.contains("\\"), !clean.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") && $0.utf8.count <= 255 }) else {
            throw InvalidArchive.unsafePath
        }
        return parts
    }

    static func extract(_ source: URL, to destination: URL, limits: Limits = Limits(),
                        progress: (Double) -> Void = { _ in }) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path),
              (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw InvalidArchive.unsafePath
        }
        let archive = try Archive(url: source, accessMode: .read)
        var items: [(Entry, [String])] = []
        var names: [String: Bool] = [:]
        var roots = Set<String>()
        var total: UInt64 = 0
        for entry in archive {
            guard entry.type != .symlink else { throw InvalidArchive.unsupportedLink }
            let parts = try components(entry.path, directory: entry.type == .directory)
            let key = parts.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
            guard names[key] == nil else { throw InvalidArchive.unsafePath }
            names[key] = entry.type == .directory
            guard items.count < limits.entries, entry.uncompressedSize <= limits.fileBytes,
                  entry.uncompressedSize <= limits.expandedBytes - total else { throw InvalidArchive.tooLarge }
            total += entry.uncompressedSize
            items.append((entry, parts))
            if parts.first == "Payload", parts.count >= 2, parts[1].hasSuffix(".app") { roots.insert(parts[1]) }
            if entry.uncompressedSize > 1_073_741_824, entry.compressedSize < entry.uncompressedSize / 1000 {
                throw InvalidArchive.tooLarge
            }
        }
        guard roots.count == 1 else { throw InvalidArchive.missingPayload }
        for (_, parts) in items where parts.count > 1 {
            for count in 1..<parts.count {
                let parent = parts.prefix(count).joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
                if names[parent] == false { throw InvalidArchive.unsafePath }
            }
        }
        let parent = destination.deletingLastPathComponent()
        let available = (try fm.attributesOfFileSystem(forPath: parent.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        guard available > limits.diskReserve, total <= available - limits.diskReserve else { throw InvalidArchive.insufficientDisk }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var done: UInt64 = 0
        do {
            for (entry, parts) in items {
                let target = parts.reduce(destination) { $0.appendingPathComponent($1) }
                if entry.type == .directory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    continue
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                guard !fm.fileExists(atPath: target.path), fm.createFile(atPath: target.path, contents: nil,
                                                                       attributes: [.posixPermissions: 0o600]) else {
                    throw InvalidArchive.unsafePath
                }
                let output = try FileHandle(forWritingTo: target)
                do {
                    var written: UInt64 = 0
                    let crc = try archive.extract(entry, bufferSize: 1_048_576, skipCRC32: false) { chunk in
                        guard UInt64(chunk.count) <= entry.uncompressedSize - written,
                              UInt64(chunk.count) <= limits.expandedBytes - done else { throw InvalidArchive.tooLarge }
                        try output.write(contentsOf: chunk)
                        written += UInt64(chunk.count)
                        done += UInt64(chunk.count)
                        progress(Double(done) / Double(max(1, total)))
                    }
                    try output.close()
                    guard written == entry.uncompressedSize, crc == entry.checksum else { throw InvalidArchive.corrupt }
                } catch { try? output.close(); throw error }
                let sourceMode = (entry.fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
                try fm.setAttributes([.posixPermissions: sourceMode & 0o111 == 0 ? 0o644 : 0o755], ofItemAtPath: target.path)
                #if os(iOS) || targetEnvironment(macCatalyst)
                try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
                #endif
            }
            progress(1)
        } catch { try? fm.removeItem(at: destination); throw error }
    }

    // Recheck previously imported bundles before native code follows any of their paths.
    static func validateTree(_ root: URL) throws {
        let fm = FileManager.default
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw InvalidArchive.unsupportedLink
        }
        var traversalError: Error?
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
            errorHandler: { _, error in traversalError = error; return false }) else { throw InvalidArchive.corrupt }
        var count = 0
        for case let item as URL in iterator {
            count += 1
            guard count <= 100_000 else { throw InvalidArchive.tooLarge }
            guard try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw InvalidArchive.unsupportedLink
            }
        }
        if let traversalError { throw traversalError }
    }
}
