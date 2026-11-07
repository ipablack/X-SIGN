import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum XSignOTAError: LocalizedError {
    case invalidPackage, sslUnavailable, unsafeAddress, domainNotReady, invalidManifest, timedOut, interrupted
    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "ملف التثبيت أو معلومات التطبيق غير صالحة."
        case .sslUnavailable: return "تعذّر تجهيز HTTPS المحلي. تحقق من الاتصال وإتاحة نطاق backloop.dev."
        case .unsafeAddress: return "دومين HTTPS المحلي لا يشير إلى الجهاز؛ أوقف التثبيت لحماية الملف."
        case .domainNotReady: return "تعذّر تجهيز ملف التثبيت من x-sign.web.app. تحقق من اتصالك وجاهزية الخدمة."
        case .invalidManifest: return "ملف التثبيت الذي أعاده الدومين غير صالح."
        case .timedOut: return "انتهت مهلة طلب التثبيت. النسخة الموقعة باقية في المكتبة."
        case .interrupted: return "توقف السيرفر المحلي قبل اكتمال نقل التطبيق."
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
        let localHTTP=payloadURL.scheme == "http" && payloadURL.host == "127.0.0.1"
        let localHTTPS=payloadURL.scheme == "https" && (payloadURL.host?.hasSuffix(".backloop.dev") ?? false)
        guard localHTTP || localHTTPS,let host=payloadURL.host,!host.contains("*"),
              host.utf8.count<=253,host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) }),
              payloadURL.user == nil, payloadURL.password == nil,
              payloadURL.query == nil, payloadURL.fragment == nil,
              let port = payloadURL.port, (49152...65535).contains(port),
              let range = XSignOTACapability.pathToken(payloadURL.path), !range.isEmpty,
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
    static let origin = URL(string: "https://x-sign.web.app")!
    private static let prepareURL = origin.appendingPathComponent("native").appendingPathComponent("prepare")
    private static let manifestPath = "/native/manifest.plist"
    private struct Prepared: Decodable { let manifestURL: URL }

    static func prepare(_ descriptor: XSignOTADescriptor, session: URLSession) async throws -> URL {
        try descriptor.validate()
        guard descriptor.payloadURL.scheme == "https" else { throw XSignOTAError.invalidPackage }

        var request = URLRequest(url: prepareURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(descriptor)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (body, response) = try await XSignBoundedHTTP.fetch(request, using: session, limit: 16_384)
        guard response.statusCode == 200, response.url == prepareURL,
              response.mimeType?.lowercased() == "application/json",
              let prepared = try? JSONDecoder().decode(Prepared.self, from: body),
              let url = URLComponents(url: prepared.manifestURL, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == origin.host, url.path == manifestPath,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let query = url.queryItems, query.count == 1, query[0].name == "ticket",
              let ticket = query[0].value, !ticket.isEmpty, ticket.utf8.count <= 8192,
              ticket.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw XSignOTAError.domainNotReady
        }

        let (manifest, result) = try await XSignBoundedHTTP.fetch(URLRequest(url: prepared.manifestURL), using: session, limit: 32_768)
        guard result.statusCode == 200, result.url == prepared.manifestURL else { throw XSignOTAError.domainNotReady }
        try validate(manifest, expected: descriptor)

        var link = URLComponents()
        link.scheme = "itms-services"
        link.host = ""
        link.queryItems = [URLQueryItem(name: "action", value: "download-manifest"),
                           URLQueryItem(name: "url", value: prepared.manifestURL.absoluteString)]
        guard let installURL = link.url else { throw XSignOTAError.invalidManifest }
        return installURL
    }

    static func validate(_ data: Data, expected: XSignOTADescriptor) throws {
        guard data.count <= 32_768,
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let items = root["items"] as? [[String: Any]], items.count == 1,
              let metadata = items[0]["metadata"] as? [String: Any],
              metadata["bundle-identifier"] as? String == expected.bundleIdentifier,
              metadata["bundle-version"] as? String == expected.bundleVersion,
              metadata["title"] as? String == expected.title,
              metadata["kind"] as? String == "software",
              let assets = items[0]["assets"] as? [[String: Any]], assets.count == 1,
              assets[0]["kind"] as? String == "software-package",
              assets[0]["url"] as? String == expected.payloadURL.absoluteString else { throw XSignOTAError.invalidManifest }
    }
}
