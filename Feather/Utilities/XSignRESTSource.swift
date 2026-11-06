import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Converts a public JSON table into the same catalog model used by XSign.
/// No provider credentials, browser impersonation or hidden API keys are supplied.
enum XSignRESTSource {
    static let primaryURL = "https://supapi.trystore.net/rest/v1/plus_library_apps"
    static let identifier = "xsign.core.primary"
    static let pageSize = 250

    enum Failure: LocalizedError {
        case permissionDenied, schema, pagination, tooLarge, http(Int)
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "رفض خادم السورس الوصول (401/403). يلزم أن يسمح مالكه بالقراءة؛ تغيير الصيغة لا يزيل الحجب."
            case .schema: return "JSON لا يحتوي حقول اسم ورابط تنزيل معروفة. يلزم نموذج من بيانات السورس لضبط التحويل."
            case .pagination: return "لم يمكن التأكد من اكتمال صفحات السورس. حُفظت آخر نسخة سليمة بدل نشر قائمة ناقصة."
            case .tooLarge: return "السورس أكبر من حدود القراءة الآمنة. لم تُستبدل النسخة المحفوظة."
            case .http(let status): return "تعذّر جلب السورس (HTTP \(status))."
            }
        }
    }

    static func handles(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "supapi.trystore.net" &&
        url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "rest/v1/plus_library_apps"
    }

    static func rows(in data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data)
        if let rows = object as? [[String: Any]] { return rows }
        if let root = object as? [String: Any] {
            for key in ["data", "results", "apps"] {
                if let rows = root[key] as? [[String: Any]] { return rows }
            }
        }
        throw Failure.schema
    }

    static func text(_ row: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            let raw = row[key]
            let value = (raw as? String) ?? (raw as? NSNumber)?.stringValue
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return nil
    }

    private static func webURL(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url.absoluteString
    }

    static func normalize(_ rows: [[String: Any]], allowPublishedFreeLinks: Bool = false) throws -> Data {
        var apps: [[String: Any]] = []
        var categories: [[String: Any]] = []
        var categoryIndices: [String: Int] = [:]
        var seen = Set<String>()
        let links = ["downloadURL", "download_url", "ipa_url", "ipaUrl", "ipa_link", "download_link", "downloadLink", "down", "link", "url"]
        func excluded(_ row: [String: Any]) -> Bool {
            if row["is_hidden"] as? Bool == true || row["hide_in_library"] as? Bool == true ||
                row["purchase_required"] as? Bool == true { return true }
            // The public Plus response also sets this flag on free, published direct links.
            // Only the dedicated Plus importer can accept those links; a missing purchase
            // status, protected response or missing URL is never treated as permission.
            return row["allow_ipa_download"] as? Bool == false &&
                !(allowPublishedFreeLinks && row["purchase_required"] as? Bool == false)
        }
        for row in rows {
            if excluded(row) { continue }
            guard let name = text(row, ["name_ar", "name", "app_name", "title"]) else { continue }
            var versions: [[String: Any]] = []
            for version in row["versions"] as? [[String: Any]] ?? [] {
                guard let number = text(version, ["version", "version_number", "app_version"]),
                      let link = webURL(text(version, links)) else { continue }
                var item: [String: Any] = ["version": number, "downloadURL": link]
                if let date = text(version, ["date", "version_date", "released_at"]) { item["date"] = date }
                versions.append(item)
            }
            guard let link = versions.first?["downloadURL"] as? String ?? webURL(text(row, links)) else { continue }
            let bundle = text(row, ["bundleIdentifier", "bundle_id", "bundleId", "bundle_identifier", "package_name"])
            let key = text(row, ["id", "uuid", "app_id"]) ?? ((bundle ?? "") + "|" + name + "|" + (URL(string: link)?.path ?? link))
            guard seen.insert(key).inserted else { continue }
            var app: [String: Any] = ["name": name, "catalogID": "xsign.rest." + key, "downloadURL": link]
            if let bundle { app["bundleIdentifier"] = bundle }
            if !versions.isEmpty { app["versions"] = versions; app["version"] = versions[0]["version"] }
            else if let version = text(row, ["version", "app_version", "version_number"]) { app["version"] = version }
            app["localizedDescription"] = text(row, ["description_ar", "localizedDescription", "description", "app_description", "details"]) ?? ""
            app["iconURL"] = webURL(text(row, ["iconURL", "icon_url", "icon", "image_url", "image"]))
            app["developerName"] = text(row, ["developer_name", "developerName", "developer", "author"])
            app["subtitle"] = text(row, ["subtitle_ar", "subtitle", "short_description"])
            if let size = text(row, ["size", "file_size", "size_bytes"]), let bytes = Int64(size), bytes >= 0 { app["size"] = bytes }
            if let skipped = row["skipAppStoreLookup"] as? Bool { app["skipAppStoreLookup"] = skipped }
            else if bundle == nil { app["skipAppStoreLookup"] = true }
            if let category = text(row, ["category", "category_id", "category_name", "genre"]) {
                app["category"] = category
                let isGame = row["is_game"] as? Bool ?? row["isGame"] as? Bool ??
                    ["game", "games", "ألعاب", "العاب", "الألعاب"].contains(category.lowercased())
                if let i = categoryIndices[category] {
                    if isGame { categories[i]["isGame"] = true }
                } else {
                    categoryIndices[category] = categories.count
                    categories.append(["id": category, "name": text(row, ["category_name"]) ?? category, "isGame": isGame])
                }
            }
            if let shots = row["screenshots"] as? [String] ?? row["screenshot_urls"] as? [String] {
                app["screenshotURLs"] = shots.compactMap { webURL($0) }
            }
            apps.append(app)
        }
        let visibleRows = rows.filter { !excluded($0) }
        // A public catalogue can contain metadata-only entries. Keep it empty when
        // all free entries lack URLs; never manufacture links from storage/GitHub IDs.
        let hasPublishedLink = visibleRows.contains { row in
            webURL(text(row, links)) != nil || (row["versions"] as? [[String: Any]] ?? []).contains { webURL(text($0, links)) != nil }
        }
        guard visibleRows.isEmpty || !apps.isEmpty || (allowPublishedFreeLinks && !hasPublishedLink) else { throw Failure.schema }
        return try JSONSerialization.data(withJSONObject: ["name": "متجر بلس", "identifier": identifier,
            "subtitle": "مكتبة XSign", "apps": apps, "categories": categories], options: [.sortedKeys])
    }

    struct PageRange: Equatable {
        let start: Int
        let end: Int
        let total: Int?
        init?(_ header: String?) {
            guard let header else { return nil }
            let parts = header.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let span = parts[0].split(separator: "-", omittingEmptySubsequences: false)
            guard span.count == 2, let start = Int(span[0]), let end = Int(span[1]), start >= 0, end >= start else { return nil }
            let total = Int(parts[1])
            guard parts[1] == "*" || (total != nil && total! > end) else { return nil }
            self.start = start; self.end = end; self.total = total
        }
    }

    static func fetch(_ url: URL, session: URLSession, maximumBytes: Int) async throws -> Data {
        guard handles(url) else { throw Failure.schema }
        var rows: [[String: Any]] = []
        var offset = 0, bytes = 0
        let ordered = true // The live table has an id column; always page in stable id order.
        var expectedTotal: Int?
        var identities = Set<String>()
        for _ in 0..<500 {
            try Task.checkCancellation()
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var query = parts?.queryItems?.filter { !["limit", "offset"].contains($0.name) } ?? []
            if ordered && !query.contains(where: { $0.name == "order" }) { query.append(URLQueryItem(name: "order", value: "id.asc")) }
            query += [URLQueryItem(name: "limit", value: String(pageSize)), URLQueryItem(name: "offset", value: String(offset))]
            parts?.queryItems = query
            guard let next = parts?.url else { throw Failure.schema }
            var request = URLRequest(url: next)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("XSign/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("count=exact", forHTTPHeaderField: "Prefer")
            let (file, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let response = response as? HTTPURLResponse else { throw Failure.schema }
            if response.statusCode == 401 || response.statusCode == 403 { throw Failure.permissionDenied }
            if response.statusCode == 416, let range = response.value(forHTTPHeaderField: "Content-Range"),
               range == "*/\(offset)", expectedTotal == nil || expectedTotal == offset { return try normalize(rows, allowPublishedFreeLinks: true) }
            guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
            let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? maximumBytes + 1
            guard size <= maximumBytes - bytes else { throw Failure.tooLarge }
            bytes += size
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let page = try Self.rows(in: data)
            if page.isEmpty {
                guard expectedTotal == nil || expectedTotal == offset else { throw Failure.pagination }
                return try normalize(rows, allowPublishedFreeLinks: true)
            }
            guard let range = PageRange(response.value(forHTTPHeaderField: "Content-Range")),
                  range.start == offset, range.end - range.start + 1 == page.count else { throw Failure.pagination }
            if let total = range.total {
                if let expectedTotal, expectedTotal != total { throw Failure.pagination }
                expectedTotal = total
            }
            let hasMore = range.total.map { range.end + 1 < $0 } ?? true
            for row in page {
                if let id = text(row, ["id"]) {
                    guard identities.insert(id).inserted else { throw Failure.pagination }
                }
            }
            rows.append(contentsOf: page)
            guard rows.count <= 50_000 else { throw Failure.tooLarge }
            offset += page.count
            if !hasMore { return try normalize(rows, allowPublishedFreeLinks: true) }
        }
        throw Failure.pagination
    }
}
