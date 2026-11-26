import Foundation
import ZIPFoundation
#if canImport(Zsign)
import Zsign
#endif

// Bounded extraction into a fresh private directory. Never restore archive symlinks or special files.
enum XSignIPAExtractor {
    enum Engine: String, CaseIterable {
        case zipFoundation, minizip
        static let preference = "xsign.archiveEngine"
        static var choices: [Self] {
            #if canImport(Zsign)
            return allCases
            #else
            return [.zipFoundation]
            #endif
        }
        static var selected: Self {
            let value = UserDefaults.standard.string(forKey: preference).flatMap(Self.init(rawValue:))
            return choices.contains(value ?? .zipFoundation) ? (value ?? .zipFoundation) : .zipFoundation
        }
        var label: String { self == .zipFoundation ? "ZIPFoundation" : "MiniZip" }
    }
    static let maximumArchiveBytes: Int64 = 8 * 1024 * 1024 * 1024
    struct Limits {
        var entries = 100_000
        var expandedBytes: UInt64 = 16 * 1024 * 1024 * 1024
        var fileBytes: UInt64 = 8 * 1024 * 1024 * 1024
        var diskReserve: UInt64 = 256 * 1024 * 1024
    }
    enum InvalidArchive: LocalizedError {
        case unsafePath, unsupportedLink, tooLarge, insufficientDisk, corrupt, missingPayload, invalidApp
        var errorDescription: String? {
            switch self {
            case .unsafePath: return "يحتوي IPA على مسار غير آمن أو ملفات متعارضة."
            case .unsupportedLink: return "يحتوي IPA على رابط رمزي غير مدعوم؛ تم إيقاف الاستيراد لحماية الملفات."
            case .tooLarge: return "يتجاوز IPA حدود حجم أو عدد الملفات الآمنة."
            case .insufficientDisk: return "لا توجد مساحة كافية لفك IPA بأمان."
            case .corrupt: return "محتوى IPA تالف أو لا يطابق حجمه وبصمته."
            case .missingPayload: return "يجب أن يحتوي IPA على تطبيق رئيسي واحد داخل Payload."
            case .invalidApp: return "حزمة التطبيق لا تحتوي على ملف معلومات أو ملف تنفيذي صالح."
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

    struct UpdateMetadata: Sendable {
        let info: Data
        let provision: Data?
    }

    static func readUpdateMetadata(_ source: URL) throws -> UpdateMetadata {
        let archive = try Archive(url: source, accessMode: .read)
        var bundles = Set<String>()
        var files: [String: Entry] = [:]
        for (index, entry) in archive.enumerated() {
            guard index < 100_000 else { throw InvalidArchive.tooLarge }
            guard entry.type != .symlink else { throw InvalidArchive.unsupportedLink }
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            let parts = try components(entry.path, directory: entry.type == .directory)
            guard parts.count >= 2, parts[0] == "Payload", parts[1].hasSuffix(".app") else { continue }
            bundles.insert(parts[1])
            let relative = parts.dropFirst(2).joined(separator: "/")
            if let name = ["Info.plist", "embedded.mobileprovision", "_CodeSignature/CodeResources"]
                .first(where: { $0.caseInsensitiveCompare(relative) == .orderedSame }) {
                guard relative == name, entry.type == .file, files.updateValue(entry, forKey: name) == nil else {
                    throw InvalidArchive.unsafePath
                }
            }
        }
        guard bundles.count == 1, let infoEntry = files["Info.plist"] else { throw InvalidArchive.missingPayload }
        func read(_ entry: Entry, limit: UInt64) throws -> Data {
            guard entry.uncompressedSize > 0, entry.uncompressedSize <= limit else { throw InvalidArchive.tooLarge }
            var data = Data()
            let crc = try archive.extract(entry, bufferSize: 65_536, skipCRC32: false) { bytes in
                try Task.checkCancellation()
                guard UInt64(bytes.count) <= limit - UInt64(data.count) else { throw InvalidArchive.tooLarge }
                data.append(bytes)
            }
            guard UInt64(data.count) == entry.uncompressedSize, crc == entry.checksum else { throw InvalidArchive.corrupt }
            return data
        }
        let info = try read(infoEntry, limit: 1_048_576)
        let provision: Data?
        if files["_CodeSignature/CodeResources"] != nil, let entry = files["embedded.mobileprovision"] {
            provision = try read(entry, limit: 8_388_608)
        } else {
            provision = nil
        }
        return UpdateMetadata(info: info, provision: provision)
    }

    static func extract(_ source: URL, to destination: URL, limits: Limits = Limits(),
                        engine: Engine = .zipFoundation, progress: (Double) -> Void = { _ in }) throws {
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
            try Task.checkCancellation()
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
        var verifiedParents = Set<String>()
        for (_, parts) in items where parts.count > 1 {
            try Task.checkCancellation()
            for count in stride(from: parts.count - 1, through: 1, by: -1) {
                let parent = parts.prefix(count).joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
                // Once a directory is known, all of its ancestors were checked as well.
                guard verifiedParents.insert(parent).inserted else { break }
                if names[parent] == false { throw InvalidArchive.unsafePath }
            }
        }
        let parent = destination.deletingLastPathComponent()
        let available = (try fm.attributesOfFileSystem(forPath: parent.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        guard available > limits.diskReserve, total <= available - limits.diskReserve else { throw InvalidArchive.insufficientDisk }
        #if canImport(Zsign)
        let native = try engine == .minizip ? MiniZipReader(source, count: items.count) : nil
        #else
        let native: MiniZipReader? = nil
        #endif
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var done: UInt64 = 0
        do {
            for (entry, parts) in items {
                try Task.checkCancellation()
                try native?.advance(entry)
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
                    func write(_ chunk: Data) throws {
                        try Task.checkCancellation()
                        guard UInt64(chunk.count) <= entry.uncompressedSize - written,
                              UInt64(chunk.count) <= limits.expandedBytes - done else { throw InvalidArchive.tooLarge }
                        try output.write(contentsOf: chunk)
                        written += UInt64(chunk.count)
                        done += UInt64(chunk.count)
                        progress(Double(done) / Double(max(1, total)))
                    }
                    let crc: UInt32
                    if let native {
                        try native.read(consumer: write)
                        crc = entry.checksum
                    } else {
                        crc = try archive.extract(entry, bufferSize: 1_048_576, skipCRC32: false) { chunk in
                            try write(chunk)
                        }
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

    private final class MiniZipReader {
        #if canImport(Zsign)
        private let reader: ZsignZipReader
        init(_ url: URL, count: Int) throws {
            guard let reader = ZsignZipReader(url: url, count: UInt64(count)) else {
                throw InvalidArchive.corrupt
            }
            self.reader = reader
        }

        func advance(_ entry: Entry) throws {
            guard reader.advance(path: entry.path, size: entry.uncompressedSize,
                                 crc: entry.checksum, directory: entry.type == .directory) else {
                throw InvalidArchive.corrupt
            }
        }

        func read(consumer: (Data) throws -> Void) throws {
            var buffer = Data(count: 262_144)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { reader.read(into: $0) }
                guard count >= 0 else { throw InvalidArchive.corrupt }
                if count == 0 { break }
                try consumer(buffer.prefix(Int(count)))
            }
            guard reader.finishEntry() else { throw InvalidArchive.corrupt }
        }
        #else
        func advance(_ entry: Entry) throws { throw InvalidArchive.corrupt }
        func read(consumer: (Data) throws -> Void) throws { throw InvalidArchive.corrupt }
        #endif
    }

    // Recheck previously imported bundles before native code follows any of their paths.
    static func validateTree(_ root: URL, visit: (URL) -> Void = { _ in }) throws {
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
            try Task.checkCancellation()
            count += 1
            guard count <= 100_000 else { throw InvalidArchive.tooLarge }
            guard try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw InvalidArchive.unsupportedLink
            }
            visit(item)
        }
        if let traversalError { throw traversalError }
    }
}
