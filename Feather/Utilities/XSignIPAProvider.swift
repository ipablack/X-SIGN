import Foundation

/// Public request contract observed in the user-supplied reference IPA.
/// This client requests a file URL; it does not decrypt an Apple executable.
enum XSignIPAProviderError: LocalizedError {
    case permissionDenied, invalidResponse, unavailable(String), http(Int)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "رفض مزود IPA الطلب (403). تحتاج الخدمة إلى صلاحية من مالكها؛ لا يمكن للسيرفر الداخلي إنشاء ملف مفكوك التشفير بدلًا منها."
        case .invalidResponse: return "رد مزود IPA غير صالح أو لا يحتوي على رابط HTTPS مباشر."
        case .unavailable(let message): return message
        case .http(let status): return "تعذّر طلب IPA من المزود (HTTP \(status))."
        }
    }
}

actor XSignIPAProvider {
    static let shared = XSignIPAProvider()
    static let providerName = "vip.appiraq.com"
    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL = URL(string: "https://vip.appiraq.com/api/appstore/get-ipa.php")!, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = false
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    nonisolated static func requestURL(endpoint: URL, bundleID: String, name: String, appStoreID: String) throws -> URL {
        guard !bundleID.isEmpty, !name.isEmpty, !appStoreID.isEmpty,
              appStoreID.utf8.allSatisfy({ (48...57).contains($0) }),
              var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw XSignIPAProviderError.invalidResponse
        }
        parts.queryItems = [URLQueryItem(name: "bundleId", value: bundleID),
                            URLQueryItem(name: "name", value: name),
                            URLQueryItem(name: "id", value: appStoreID)]
        // Read first, then assign: Swift forbids overlapping access to URLComponents.
        let encoded = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        parts.percentEncodedQuery = encoded
        guard let url = parts.url else { throw XSignIPAProviderError.invalidResponse }
        return url
    }

    nonisolated static func decode(_ data: Data, status: Int) throws -> URL {
        if status == 401 || status == 403 { throw XSignIPAProviderError.permissionDenied }
        guard (200..<300).contains(status) else { throw XSignIPAProviderError.http(status) }
        guard data.count <= 1_048_576 else { throw XSignIPAProviderError.invalidResponse }
        struct Response: Decodable {
            let success: Bool
            let download_url: String?
            let message: String?
            let error: String?
        }
        guard let value = try? JSONDecoder().decode(Response.self, from: data) else {
            throw XSignIPAProviderError.invalidResponse
        }
        guard value.success else {
            let text = value.error ?? value.message ?? "لا يتوفر ملف IPA لهذا التطبيق لدى المزود."
            throw XSignIPAProviderError.unavailable(String(text.prefix(500)))
        }
        guard let text = value.download_url, let url = URL(string: text),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { throw XSignIPAProviderError.invalidResponse }
        return url
    }

    func resolve(bundleID: String, name: String, appStoreID: String) async throws -> URL {
        let url = try Self.requestURL(endpoint: endpoint, bundleID: bundleID, name: name, appStoreID: appStoreID)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw XSignIPAProviderError.invalidResponse }
        return try Self.decode(data, status: response.statusCode)
    }
}
