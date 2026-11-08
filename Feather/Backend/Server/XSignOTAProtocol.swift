import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum XSignOTAError: LocalizedError {
    case invalidPackage, localServerUnavailable, domainNotReady, invalidManifest, timedOut
    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "ملف التثبيت أو معلومات التطبيق غير صالحة."
        case .localServerUnavailable: return "تعذّر تشغيل خادم التثبيت على هذا الجهاز. أعد المحاولة من قسم التوقيع."
        case .domainNotReady: return "تعذّر تجهيز ملف وصف التثبيت. تحقّق من الاتصال أو اختر طريقة أخرى من الإعدادات."
        case .invalidManifest: return "ملف وصف التثبيت غير صالح."
        case .timedOut: return "انتهت مهلة طلب التثبيت. النسخة الموقعة باقية في المكتبة."
        }
    }
}

enum XSignOTAInstallMode: String, CaseIterable, Sendable {
    case palera, semiLocal

    static let storageKey = "XSign.installationMode"
    static var selected: Self {
        resolve(UserDefaults.standard.string(forKey: storageKey))
    }

    static func resolve(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .palera
    }

    var title: String {
        switch self {
        case .palera: return "محلي (افتراضي)"
        case .semiLocal: return "محلي جزئي (Zsign)"
        }
    }
}

struct XSignOTABundleMetadata: Sendable {
    let identifier: String
    let version: String
    let title: String
    let shortVersion: String
    init(info: [String: Any]) throws {
        guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let version = info["CFBundleVersion"] as? String, !version.isEmpty else {
            throw XSignOTAError.invalidPackage
        }
        self.identifier = identifier
        self.version = version
        self.shortVersion = (info["CFBundleShortVersionString"] as? String) ?? version
        self.title = [info["CFBundleDisplayName"], info["CFBundleName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? identifier
    }
    static func read(from app: URL) throws -> Self {
        let file = app.appendingPathComponent("Info.plist")
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count <= 1_048_576,
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else {
            throw XSignOTAError.invalidPackage
        }
        return try Self(info: info)
    }
}

struct XSignOTADescriptor: Codable, Sendable {
    let payloadURL: URL
    let bundleIdentifier: String
    let bundleVersion: String
    let title: String
    let expiresAt: Int

    func validate(now: Date = Date()) throws {
        guard let port = payloadURL.port, (49152...65535).contains(port),
              XSignOTACapability.pathToken(payloadURL.path) != nil,
              payloadURL.absoluteString == "http://127.0.0.1:\(port)\(payloadURL.path)",
              !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 255,
              bundleIdentifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.").contains($0) }),
              !bundleVersion.isEmpty, bundleVersion.utf8.count <= 64,
              !title.isEmpty, title.utf8.count <= 512,
              [bundleVersion, title].allSatisfy({ value in value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value == 9 || scalar.value == 10 || scalar.value == 13 ||
                  (scalar.value >= 32 && scalar.value != 0xfffe && scalar.value != 0xffff)
              }) }),
              expiresAt > Int(now.timeIntervalSince1970), expiresAt <= Int(now.timeIntervalSince1970) + 3600 else {
            throw XSignOTAError.invalidPackage
        }
    }
}

enum XSignOTACapability {
    static func token() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased() }
    static func pathToken(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "ota", parts[3] == "payload.ipa",
              parts[2].count == 64, parts[2].allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return String(parts[2])
    }
}

struct XSignOTARange: Equatable, Sendable {
    let lower: Int64
    let upper: Int64
    static func parse(_ value: String?, size: Int64) throws -> Self {
        guard size > 0 else { throw XSignOTAError.invalidPackage }
        guard let value else { return Self(lower: 0, upper: size - 1) }
        guard value.utf8.count <= 128, value.hasPrefix("bytes="), !value.contains(",") else { throw XSignOTAError.invalidPackage }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw XSignOTAError.invalidPackage }
        if parts[0].isEmpty {
            guard let count = Int64(parts[1]), count > 0 else { throw XSignOTAError.invalidPackage }
            return Self(lower: max(0, size - count), upper: size - 1)
        }
        guard let lower = Int64(parts[0]), lower >= 0, lower < size else { throw XSignOTAError.invalidPackage }
        let upper: Int64
        if parts[1].isEmpty { upper = size - 1 }
        else {
            guard let end = Int64(parts[1]), end >= lower else { throw XSignOTAError.invalidPackage }
            upper = min(end, size - 1)
        }
        return Self(lower: lower, upper: upper)
    }
}

// Handles HEAD/range probes and retries without falsely calling a partial range a completed download.
actor XSignOTATransfers {
    private let size: Int64
    private var intervals: [XSignOTARange] = []
    private var inFlight = 0
    private var attempts = 0
    private var downloaded = false
    private var stopped = false

    init(size: Int64) { self.size = size }
    func begin() -> Bool {
        guard !stopped, inFlight < 4, attempts < 64 else { return false }
        inFlight += 1; attempts += 1
        return true
    }
    func finish(_ range: XSignOTARange, success: Bool) {
        inFlight = max(0, inFlight - 1)
        guard success, !stopped else { return }
        intervals.append(range)
        intervals.sort { $0.lower < $1.lower }
        var merged: [XSignOTARange] = []
        for item in intervals {
            if let last = merged.last, item.lower <= last.upper + 1 {
                merged[merged.count - 1] = XSignOTARange(lower: last.lower, upper: max(last.upper, item.upper))
            } else { merged.append(item) }
        }
        intervals = merged
        downloaded = intervals.count == 1 && intervals[0].lower == 0 && intervals[0].upper >= size - 1
    }
    var isDownloaded: Bool { downloaded }
    func stop() { stopped = true }
}

// Only metadata and the short-lived loopback URL are sent to the manifest service.
struct XSignManifestBridge {
    private static let paleraURL = URL(string: "https://api.palera.in/genPlist")!
    private static let zsignURL = URL(string: "https://vip.appiraq.com/Zsign.php")!

    static func prepare(_ descriptor: XSignOTADescriptor, mode: XSignOTAInstallMode, session: URLSession) async throws -> URL {
        try descriptor.validate()
        let endpoint = mode == .palera ? paleraURL : zsignURL
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let title = descriptor.title.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let fields = [("bundleid", descriptor.bundleIdentifier), ("name", title),
                      ("version", descriptor.bundleVersion), ("fetchurl", descriptor.payloadURL.absoluteString)]
        components.percentEncodedQuery = fields.map { name, value in
            // Palera inserts parameter values into XML text. Zsign performs its own XML escaping.
            let field = mode == .palera ? escapedXMLText(value) : value
            return name + "=" + (field.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }.joined(separator: "&")
        guard let manifestURL = components.url else { throw XSignOTAError.invalidManifest }
        return try await verifiedLink(for: manifestURL, descriptor: descriptor,
                                      title: title, timeout: 16, session: session)
    }

    private static func escapedXMLText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: "&#13;")
    }

    private static func verifiedLink(for manifestURL: URL, descriptor: XSignOTADescriptor, title: String,
                                     timeout: TimeInterval, session: URLSession) async throws -> URL {
        var request = URLRequest(url: manifestURL, timeoutInterval: timeout)
        request.setValue("application/x-plist, application/xml, text/xml, application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("XSign/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (manifest, result) = try await XSignBoundedHTTP.fetch(request, using: session, limit: 32_768)
        guard result.statusCode == 200, result.url == manifestURL else { throw XSignOTAError.domainNotReady }
        try validate(manifest, expected: descriptor, title: title)
        var link = URLComponents()
        link.scheme = "itms-services"
        link.host = ""
        link.queryItems = [URLQueryItem(name: "action", value: "download-manifest"),
                           URLQueryItem(name: "url", value: manifestURL.absoluteString)]
        link.percentEncodedQuery = link.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let installURL = link.url else { throw XSignOTAError.invalidManifest }
        return installURL
    }

    private static func validate(_ data: Data, expected: XSignOTADescriptor, title: String) throws {
        guard data.count <= 32_768,
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let items = root["items"] as? [[String: Any]], items.count == 1,
              let metadata = items[0]["metadata"] as? [String: Any],
              metadata["bundle-identifier"] as? String == expected.bundleIdentifier,
              metadata["bundle-version"] as? String == expected.bundleVersion,
              metadata["title"] as? String == title,
              metadata["kind"] as? String == "software",
              let assets = items[0]["assets"] as? [[String: Any]], assets.count == 1,
              assets[0]["kind"] as? String == "software-package",
              assets[0]["url"] as? String == expected.payloadURL.absoluteString else { throw XSignOTAError.invalidManifest }
    }
}
