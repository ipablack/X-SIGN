import Foundation

/// Reads bounded Mach-O headers only. This detects encryption; it never removes it.
enum XSignMachOEncryption {
    enum InspectionError: LocalizedError {
        case invalidExecutable, encryptedExecutable, missingExecutable
        var errorDescription: String? {
            switch self {
            case .invalidExecutable: return "ملف التنفيذ تالف أو ليس بصيغة Mach-O مدعومة."
            case .encryptedExecutable: return "ملف IPA ما زال يحتوي على تنفيذ مشفّر. التوقيع المحلي لا يفك تشفير FairPlay."
            case .missingExecutable: return "لا يحتوي IPA على حزمة تطبيق وتنفيذ صالحين."
            }
        }
    }

    private static func number(_ data: Data, _ offset: Int, _ count: Int, little: Bool) throws -> UInt64 {
        guard offset >= 0, count > 0, offset <= data.count, count <= data.count - offset else {
            throw InspectionError.invalidExecutable
        }
        var value: UInt64 = 0
        for i in 0..<count {
            let byte = UInt64(data[offset + i])
            if little { value |= byte << (i * 8) }
            else { value = (value << 8) | byte }
        }
        return value
    }

    static func isEncrypted(executable: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: executable)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= size, UInt64(count) <= size - offset else { throw InspectionError.invalidExecutable }
            if count == 0 { return Data() }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else {
                throw InspectionError.invalidExecutable
            }
            return data
        }
        func inspect(_ start: UInt64, _ length: UInt64, _ depth: Int) throws -> Bool {
            guard depth <= 2, length >= 4, start <= size, length <= size - start else {
                throw InspectionError.invalidExecutable
            }
            let magic = try number(read(start, 4), 0, 4, little: false)
            if [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) {
                let little = magic == 0xbebafeca || magic == 0xbfbafeca
                let wide = magic == 0xcafebabf || magic == 0xbfbafeca
                guard length >= 8 else { throw InspectionError.invalidExecutable }
                let header = try read(start, 8)
                let count = Int(try number(header, 4, 4, little: little))
                let stride = wide ? 32 : 20
                guard count > 0, count <= 64, UInt64(8 + count * stride) <= length else {
                    throw InspectionError.invalidExecutable
                }
                let table = try read(start + 8, count * stride)
                var encrypted = false
                for i in 0..<count {
                    let offset = try number(table, i * stride + 8, wide ? 8 : 4, little: little)
                    let sliceSize = try number(table, i * stride + (wide ? 16 : 12), wide ? 8 : 4, little: little)
                    guard offset >= UInt64(8 + count * stride), offset <= length, sliceSize <= length - offset else {
                        throw InspectionError.invalidExecutable
                    }
                    if try inspect(start + offset, sliceSize, depth + 1) { encrypted = true }
                }
                return encrypted
            }
            let little = magic == 0xcefaedfe || magic == 0xcffaedfe
            let wide = magic == 0xfeedfacf || magic == 0xcffaedfe
            guard [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe].contains(magic) else {
                throw InspectionError.invalidExecutable
            }
            let headerSize = wide ? 32 : 28
            guard length >= UInt64(headerSize) else { throw InspectionError.invalidExecutable }
            let header = try read(start, headerSize)
            let count = Int(try number(header, 16, 4, little: little))
            let commandsSize = Int(try number(header, 20, 4, little: little))
            guard count <= 65_536, commandsSize <= 16_777_216,
                  UInt64(commandsSize) <= length - UInt64(headerSize), count <= commandsSize / 8 else {
                throw InspectionError.invalidExecutable
            }
            let commands = try read(start + UInt64(headerSize), commandsSize)
            var offset = 0
            var encrypted = false
            for _ in 0..<count {
                let command = try number(commands, offset, 4, little: little)
                let commandSize = Int(try number(commands, offset + 4, 4, little: little))
                guard commandSize >= 8, offset <= commandsSize, commandSize <= commandsSize - offset else {
                    throw InspectionError.invalidExecutable
                }
                if command == 0x21 || command == 0x2c {
                    guard commandSize >= (command == 0x2c ? 24 : 20) else { throw InspectionError.invalidExecutable }
                    if try number(commands, offset + 16, 4, little: little) != 0 { encrypted = true }
                }
                offset += commandSize
            }
            guard offset == commandsSize else { throw InspectionError.invalidExecutable }
            return encrypted
        }
        return try inspect(0, size, 0)
    }

    static func verifyPayload(at payload: URL) throws {
        let fm = FileManager.default
        let apps = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "app" }
        guard apps.count == 1, let app = apps.first else { throw InspectionError.missingExecutable }
        var executables = Set<URL>()
        func addBundle(_ bundle: URL, required: Bool) throws {
            let infoURL = bundle.appendingPathComponent("Info.plist")
            guard let data = try? Data(contentsOf: infoURL),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let name = info["CFBundleExecutable"] as? String, !name.isEmpty,
                  name != ".", name != "..", !name.contains("/") else {
                if required { throw InspectionError.missingExecutable }
                return
            }
            executables.insert(bundle.appendingPathComponent(name).standardizedFileURL)
        }
        try addBundle(app, required: true)
        if let iterator = fm.enumerator(at: app, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let item as URL in iterator {
                switch item.pathExtension.lowercased() {
                case "app", "appex": try addBundle(item, required: true)
                case "framework": try addBundle(item, required: false)
                case "dylib": executables.insert(item.standardizedFileURL)
                default: break
                }
            }
        }
        for executable in executables {
            if try isEncrypted(executable: executable) { throw InspectionError.encryptedExecutable }
        }
    }
}
