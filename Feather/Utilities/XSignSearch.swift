import Foundation

struct XSignSearchAliasIndex: Sendable {
    private struct Term: Sendable { let text: String; let isShort: Bool; let mayActivate: Bool }
    private let groups: [[Term]]
    init(groups: [[String]]) {
        let ambiguous: Set<String> = ["plus", "bh", "dl", "rocket"]
        self.groups = groups.map { group in group.map { Term(text: $0, isShort: $0.count <= 2, mayActivate: !ambiguous.contains($0)) } }
    }
    func matching(name: String, bundle: String) -> [String] {
        let original = name + " " + bundle
        let words = Set(original.split(separator: " ").map(String.init))
        return Array(Set(groups.filter { group in
            group.contains { term in term.mayActivate && (term.isShort ? words.contains(term.text) : original.contains(term.text)) }
        }.flatMap { $0.map(\.text) })).sorted()
    }
}

// Immutable search fields are prepared with the catalog, never while rendering rows.
struct XSignSearchDocument: Sendable {
    let name: String
    let compactName: String
    let nameWords: [String]
    let bundle: String
    let aliases: [String]

    private static let foldingLocale = Locale(identifier: "en_US_POSIX")
    nonisolated static func normalize(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 128 }) {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.utf8.count)
            var space = true
            for byte in text.utf8 {
                let lower = (65...90).contains(byte) ? byte + 32 : byte
                if (97...122).contains(lower) || (48...57).contains(lower) {
                    bytes.append(lower); space = false
                } else if !space { bytes.append(32); space = true }
            }
            if bytes.last == 32 { bytes.removeLast() }
            return String(decoding: bytes, as: UTF8.self)
        }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: foldingLocale).lowercased()
        var output = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            // Arabic marks are also alphanumeric on Foundation: remove them FIRST.
            if CharacterSet.nonBaseCharacters.contains(scalar) || [0x0640, 0x200B, 0x200C, 0x200D, 0xFEFF].contains(scalar.value) { continue }
            var value = scalar.value
            switch value {
            case 0x0622, 0x0623, 0x0625: value = 0x0627
            case 0x0629: value = 0x0647
            case 0x0649, 0x0626: value = 0x064A
            case 0x0624: value = 0x0648
            default: break
            }
            let normalized = UnicodeScalar(value) ?? scalar
            if CharacterSet.alphanumerics.contains(normalized) { output.append(normalized); lastWasSpace = false }
            else if !lastWasSpace { output.append(" "); lastWasSpace = true }
        }
        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(name: String, bundleID: String, aliasGroups: [[String]] = []) {
        self.init(name: name, bundleID: bundleID, aliasIndex: XSignSearchAliasIndex(groups: aliasGroups))
    }
    init(name: String, bundleID: String, aliasIndex: XSignSearchAliasIndex) {
        self.name = Self.normalize(name)
        self.compactName = self.name.replacingOccurrences(of: " ", with: "")
        self.nameWords = self.name.split(separator: " ").map(String.init)
        self.bundle = Self.normalize(bundleID)
        self.aliases = aliasIndex.matching(name: self.name, bundle: self.bundle)
    }

    nonisolated func score(for normalizedQuery: String) -> Int? {
        guard !normalizedQuery.isEmpty else { return nil }
        let compact = normalizedQuery.replacingOccurrences(of: " ", with: "")
        if name == normalizedQuery || compactName == compact { return 0 }
        if name.hasPrefix(normalizedQuery) || compactName.hasPrefix(compact) { return 1 }
        let terms = normalizedQuery.split(separator: " ").map(String.init)
        if terms.allSatisfy({ term in nameWords.contains { $0.hasPrefix(term) } }) { return 2 }
        if name.contains(normalizedQuery) || compactName.contains(compact) { return 3 }
        if terms.allSatisfy({ name.contains($0) }) { return 4 }
        // One letter searches the actual name; it must not match a whole synonym group.
        if compact.count >= 2, aliases.contains(where: { $0.hasPrefix(normalizedQuery) }) { return 5 }
        if compact.count >= 3, bundle.contains(normalizedQuery) { return 6 }
        return nil
    }
}

struct XSignAppStoreReference: Equatable, Sendable {
    let id: String
    let country: String?
    let url: URL

    nonisolated static func parse(_ text: String) -> Self? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              ["apps.apple.com", "itunes.apple.com"].contains(parts.host?.lowercased() ?? "") else { return nil }
        let segments = url.path.split(separator: "/").map(String.init)
        let pathID = segments.first { $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy(\.isNumber) && $0.count > 2 }.map { String($0.dropFirst(2)) }
        let queryID = parts.queryItems?.first(where: { $0.name == "id" })?.value
        guard let id = pathID ?? queryID, !id.isEmpty, id.count <= 18,
              id.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else { return nil }
        let country = segments.first.flatMap { value -> String? in
            value.count == 2 && value.unicodeScalars.allSatisfy({ (65...90).contains($0.value) || (97...122).contains($0.value) }) ? value.lowercased() : nil
        }
        return Self(id: id, country: country, url: url)
    }
}
