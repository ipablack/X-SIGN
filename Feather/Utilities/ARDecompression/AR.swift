// SwiftAR — originally created by nekohaxx on 8/18/24.

import Foundation

final class AR {
    private let url: URL
    private static let magic = Data("!<arch>\n".utf8)
    private static let maximumBytes = 256 * 1024 * 1024

    init(with url: URL) {
        self.url = url
    }

    func member(named candidates: Set<String>) throws -> (name: String, data: Data) {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let fileSize = attributes.fileSize, fileSize <= Self.maximumBytes else {
            throw ARError.invalidArchive
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        func read(_ count: Int) throws -> Data {
            guard let data = try file.read(upToCount: count), data.count == count else {
                throw ARError.invalidArchive
            }
            return data
        }

        guard fileSize >= Self.magic.count, try read(Self.magic.count) == Self.magic else {
            throw ARError.invalidArchive
        }
        var offset = Self.magic.count
        var contents: (name: String, data: Data)?
        var entries = 0
        while offset < fileSize {
            try Task.checkCancellation()
            entries += 1
            guard entries <= 512, fileSize - offset >= 60 else { throw ARError.invalidArchive }
            let header = try read(60)
            guard header[58] == 0x60, header[59] == 0x0a,
                  let rawName = String(data: header.prefix(16), encoding: .ascii),
                  let sizeField = String(data: header[48..<58], encoding: .ascii),
                  let size = Int(sizeField.trimmingCharacters(in: .whitespaces)),
                  size >= 0, size <= fileSize - offset - 60 else { throw ARError.invalidArchive }

            var name = rawName.trimmingCharacters(in: .whitespaces)
            if name.hasSuffix("/") { name.removeLast() }
            offset += 60 + size
            guard offset + size % 2 <= fileSize else { throw ARError.invalidArchive }
            if candidates.contains(name) {
                guard contents == nil, size > 0 else { throw ARError.invalidArchive }
                contents = (name, try read(size))
            }
            offset += size % 2
            try file.seek(toOffset: UInt64(offset))
        }
        guard let contents else { throw ARError.missingPayload }
        return contents
    }

}

enum ARError: LocalizedError {
    case invalidArchive, missingPayload

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "ملف DEB غير صالح أو حجمه أكبر من الحد المدعوم."
        case .missingPayload: return "ملف DEB يفتقد حزمة البيانات المدعومة."
        }
    }
}
