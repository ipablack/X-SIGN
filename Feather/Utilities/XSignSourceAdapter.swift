import Foundation

// Data-only conversion. HTML, scripts and protected responses are never executed or treated as catalogs.
enum XSignSourceAdapter {
    static func normalize(_ data: Data, from url: URL, configuration supplied: XSignManagedSource? = nil) throws -> Data {
        guard data.count <= 33_554_432 else { throw XSignCatalogError.tooLarge }
        let input: Any
        do { input = try JSONSerialization.jsonObject(with:data) }
        catch { throw XSignCatalogError.invalidJSON }
        let config = supplied ?? XSignDashboardSources.configuration(for:url)
        let dictionary = input as? [String:Any]
        if XSignCatalogueEndpoint.iosBoomFeeds.contains(url),
           config?.fields?.isEmpty != false, config?.root_path?.isEmpty != false,
           let dictionary, let rows = dictionary["apps"] as? [Any] {
            return try publicCatalog(dictionary, rows: rows, isIPAOMTK: url == XSignCatalogueEndpoint.iosBoomFeeds[1])
        }
        let knownNumericTypes = XSignRESTSource.usesNumericTypes(config)
        if config?.format == "altstore" { return try sanitizedCatalogue(dictionary, fallback: data, numericTypes: knownNumericTypes, icon: config?.icon_url) }
        if config?.fields?.isEmpty != false, config?.root_path?.isEmpty != false,
           let apps=dictionary?["apps"] as? [[String:Any]],
           apps.allSatisfy({ $0["name"] is String && ($0["downloadURL"] is String ||
               $0["versions"] is [[String:Any]] || $0["bundleIdentifier"] is String) }) {
            return try sanitizedCatalogue(dictionary, fallback: data, numericTypes: knownNumericTypes, icon: config?.icon_url)
        }
        var selected: Any? = input
        var selectedGames = false
        var separateGames: [[String: Any]] = []
        if let path=config?.root_path, !path.isEmpty {
            selected=value(input,path:path)
            selectedGames = path.split(separator: ".").last == "games"
        }
        if config?.root_path?.isEmpty != false, !(selected is [[String:Any]]) {
            for path in ["apps","data","items","results","list","data.apps","data.items","data.list","data.results","response","response.apps","response.items","response.data","response.data.items","games","data.games"] {
                if let found=value(input,path:path) as? [[String:Any]] {
                    selected=found
                    selectedGames = path.split(separator: ".").last == "games"
                    if path == "apps" || path == "data.apps" {
                        let gamesPath = path == "apps" ? "games" : "data.games"
                        separateGames = value(input, path: gamesPath) as? [[String: Any]] ?? []
                    }
                    break
                }
            }
        }
        guard let rows=selected as? [[String:Any]] else { throw XSignCatalogError.invalidJSON }
        let aliases: [String:[String]] = [
            "name":["name_ar","name","app_name","title"],
            "bundleIdentifier":["bundleIdentifier","bundle_id","bundleId","bundleid","bundle","package_name"],
            "downloadURL":["downloadURL","download_url","ipa_url","ipa","download","link","url"],
            "iconURL":["iconURL","icon_url","icon","image_url","image","logo"],
            "version":["version","app_version","version_number"],
            "developerName":["developerName","developer","developer_name","author"],
            "localizedDescription":["description_ar","localizedDescription","description","desc","details"],
            "category":["category","categoryId","category_id","category_name","genre","genreId","primaryGenreId"],
            "artworkURL":["artworkURL","bannerURL","headerURL","banner_url","header_url"],
            "size":["size","file_size","size_bytes"]
        ]
        let records = separateGames.map { ($0, true) } + rows.map { ($0, selectedGames) }
        let mapped=records.map { row, isGame -> [String:Any] in
            var result=row
            for (field,choices) in aliases {
                let paths: [String]
                if let mappedPath=config?.fields?[field] { paths=[mappedPath] } else { paths=choices }
                for path in paths {
                    if let found=value(row,path:path), !(found is NSNull) { result[field]=found;break }
                }
            }
            if knownNumericTypes { XSignRESTSource.applyNumericType(to: &result) }
            if isGame {
                result["isGame"] = true
                result.removeValue(forKey: "is_game")
            }
            return result
        }
        let normalized=try XSignRESTSource.normalize(mapped)
        guard var root=(try JSONSerialization.jsonObject(with:normalized)) as? [String:Any] else { throw XSignCatalogError.invalidJSON }
        root["name"]=config?.name ?? dictionary?["name"] as? String ?? url.host ?? "المصدر"
        root["identifier"]=config?.id ?? dictionary?["identifier"] as? String ?? url.absoluteString
        root["iconURL"]=config?.icon_url ?? dictionary?["iconURL"] as? String ?? dictionary?["icon"] as? String
        for key in ["subtitle", "categories", "gameCategories", "news", "featuredApps"] {
            if let metadata = dictionary?[key] ?? value(input, path: "data." + key), !(metadata is NSNull) {
                if key == "categories", let generated = root[key] as? [[String: Any]], !generated.isEmpty {
                    root[key] = mergedCategories(metadata, generated: generated)
                } else {
                    root[key] = metadata
                }
            }
        }
        return try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys])
    }

    private static func publicCatalog(_ root: [String: Any], rows: [Any], isIPAOMTK: Bool) throws -> Data {
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormat.dateFormat = "yyyy-MM-dd"
        var validDates: [String: Bool] = [:]
        func publicLink(_ value: Any?) -> URL? {
            guard let raw = value as? String, let url = XSignManagedSource.httpsURL(raw),
                  url.query == nil, url.pathExtension.lowercased() == "ipa" else { return nil }
            return url
        }
        let apps = rows.compactMap { value -> [String: Any]? in
            guard let row = value as? [String: Any],
                  let name = XSignRESTSource.text(row, ["name"]),
                  row["purchase_required"] as? Bool != true, row["is_hidden"] as? Bool != true,
                  row["hide_in_library"] as? Bool != true, row["requiresPayment"] as? Bool != true,
                  row["allow_ipa_download"] as? Bool != false,
                  XSignRESTSource.text(row, ["marketplaceID"]) == nil else { return nil }
            let versions = (row["versions"] as? [[String: Any]] ?? []).compactMap { version -> [String: Any]? in
                guard let number = XSignRESTSource.text(version, ["version"]),
                      let url = publicLink(version["downloadURL"]) else { return nil }
                var clean: [String: Any] = ["version": number, "downloadURL": url.absoluteString]
                for field in ["date", "buildVersion", "size"] { clean[field] = XSignRESTSource.text(version, [field]) }
                return clean
            }
            guard let url = publicLink(row["downloadURL"])?.absoluteString ??
                (versions.first?["downloadURL"] as? String) else { return nil }
            var app: [String: Any] = ["name": name, "downloadURL": url]
            for field in ["bundleIdentifier", "developerName", "subtitle", "localizedDescription", "version", "size",
                          "category", "categoryId", "category_id", "primaryGenreName", "type"] {
                app[field] = XSignRESTSource.text(row, [field])
            }
            if let date = XSignRESTSource.text(row, ["versionDate"]), date.count >= 10 {
                let stamp = String(date.prefix(10))
                let valid = validDates[stamp] ?? (dateFormat.date(from: stamp) != nil)
                validDates[stamp] = valid
                if valid { app["versionDate"] = stamp }
            }
            app["iconURL"] = XSignManagedSource.httpsURL(row["iconURL"] as? String)?.absoluteString
            app["artworkURL"] = XSignManagedSource.httpsURL(XSignRESTSource.text(row, ["artworkURL", "bannerURL"]))?.absoluteString
            if let shots = row["screenshotURLs"] as? [String] {
                app["screenshotURLs"] = shots.prefix(12).compactMap { XSignManagedSource.httpsURL($0)?.absoluteString }
            }
            if !versions.isEmpty { app["versions"] = versions }
            let category = (app["category"] as? String)?.lowercased()
            if let isGame = XSignRESTSource.gameFlag(row) { app["isGame"] = isGame }
            else if ["game", "games", "gaming"].contains(category ?? "") { app["isGame"] = true }
            else if app["category"] == nil && (app["type"] as? String) == "2" {
                app["category"] = "games"
                app["isGame"] = true
            } else if app["category"] == nil && isIPAOMTK {
                switch app["type"] as? String {
                case "3": app["category"] = "photo-video"; app["isGame"] = false
                case "4": app["category"] = "utilities"; app["isGame"] = false
                default: break
                }
            }
            app.removeValue(forKey: "type")
            return app
        }
        guard !apps.isEmpty else { throw XSignCatalogError.invalidJSON }
        var catalog: [String: Any] = ["apps": apps]
        catalog["name"] = root["name"] as? String
        catalog["identifier"] = root["identifier"] as? String
        catalog["subtitle"] = root["subtitle"] as? String
        catalog["iconURL"] = XSignManagedSource.httpsURL(root["iconURL"] as? String)?.absoluteString
        catalog["categories"] = root["categories"]
        return try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
    }
    // A catalogue can publish metadata without an IPA. Preserve its app/version
    // records, but never turn an empty, relative or non-HTTPS URL into a download.
    private static func sanitizedCatalogue(_ input: [String: Any]?, fallback: Data, numericTypes: Bool,
                                           icon: String?) throws -> Data {
        guard var root = input, let apps = root["apps"] as? [[String: Any]] else { return fallback }
        var changed = false
        if let icon, XSignManagedSource.httpsURL(icon) != nil {
            root["iconURL"] = icon
            changed = true
        }
        func cleanDownload(_ input: [String: Any]) -> [String: Any] {
            var row = input
            if let value = row["downloadURL"],
               (value as? String).flatMap({ XSignManagedSource.httpsURL($0) }) == nil {
                row.removeValue(forKey: "downloadURL")
                changed = true
            }
            return row
        }
        func cleanApp(_ app: [String: Any]) -> [String: Any] {
            var item = cleanDownload(app)
            if numericTypes, XSignRESTSource.applyNumericType(to: &item) { changed = true }
            if let versions = item["versions"] as? [[String: Any]] { item["versions"] = versions.map(cleanDownload) }
            return item
        }
        var catalogue = apps.map(cleanApp)
        if let games = root["games"] as? [[String: Any]], !games.isEmpty {
            catalogue += games.map {
                var game = cleanApp($0)
                game["isGame"] = true
                return game
            }
            root.removeValue(forKey: "games")
            changed = true
        }
        root["apps"] = catalogue
        return changed ? try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) : fallback
    }

    private static func mergedCategories(_ metadata: Any, generated: [[String: Any]]) -> [Any] {
        let declared: [Any]
        if let list = metadata as? [Any] { declared = list }
        else if let labels = metadata as? [String: String] {
            declared = labels.keys.sorted().compactMap { id in labels[id].map { ["id": id, "name": $0] } }
        } else { return generated }
        let keys = Set(declared.compactMap { row -> String? in
            let value = (row as? [String: Any]).flatMap {
                XSignRESTSource.text($0, ["id", "value", "categoryId", "category_id", "slug", "name", "label", "title"])
            } ?? (row as? String) ?? (row as? Int).map(String.init)
            return XSignCatalogKindPolicy.categoryKey(value)
        })
        return declared + generated.filter { row in
            guard let key = XSignCatalogKindPolicy.categoryKey(row["id"] as? String) else { return false }
            return !keys.contains(key)
        }
    }
    private static func value(_ input: Any, path: String) -> Any? {
        guard path.utf8.count <= 300 else { return nil }
        return path.split(separator:".").reduce(Optional(input)) { result,key in (result as? [String:Any])?[String(key)] }
    }
}
