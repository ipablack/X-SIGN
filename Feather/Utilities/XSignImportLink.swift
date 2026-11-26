import Foundation

struct XSignImportLink: Equatable, Sendable {
    let package: URL
    var title: String?
    var version: String?

    enum Input: Equatable {
        case package(URL)
        case manifest(URL)
    }

    enum ValidationError: LocalizedError {
        case link, manifest
        var errorDescription: String? {
            switch self {
            case .link: return "ألصق رابط IPA أو رابط تثبيت صالحًا عبر HTTPS."
            case .manifest: return "ملف التثبيت لا يحدد تطبيقًا واحدًا صالحًا للتنزيل."
            }
        }
    }

    static let manifestLimit = 128 * 1024

    static func parse(_ input: String) throws -> Input {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8_192 else { throw ValidationError.link }
        if let url = https(value) {
            return url.pathExtension.lowercased() == "plist" ? .manifest(url) : .package(url)
        }
        guard let link = URLComponents(string: value), link.scheme?.lowercased() == "itms-services",
              link.host?.isEmpty != false, link.user == nil, link.password == nil, link.port == nil,
              link.path.isEmpty || link.path == "/", link.fragment == nil,
              let parameters = link.queryItems,
              parameters.filter({ $0.name == "action" }).map(\.value) == ["download-manifest"],
              parameters.filter({ $0.name == "url" }).count == 1,
              let address = parameters.first(where: { $0.name == "url" })?.value, let url = https(address) else {
            throw ValidationError.link
        }
        return .manifest(url)
    }

    static func parseManifest(_ data: Data) throws -> Self {
        guard data.count <= manifestLimit,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = root["items"] as? [[String: Any]], items.count == 1,
              let assets = items[0]["assets"] as? [[String: Any]] else { throw ValidationError.manifest }
        let packages = assets.filter { $0["kind"] as? String == "software-package" }
        guard packages.count == 1, let address = packages[0]["url"] as? String,
              let url = https(address) else { throw ValidationError.manifest }
        let metadata = items[0]["metadata"] as? [String: Any]
        return Self(package: url, title: previewText(metadata?["title"]), version: previewText(metadata?["bundle-version"]))
    }

    private static func https(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil else { return nil }
        return url
    }

    private static func previewText(_ input: Any?) -> String? {
        guard let text = input as? String else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(160))
    }
}
