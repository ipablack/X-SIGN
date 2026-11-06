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
        if config?.format == "altstore" { return data }
        if config?.fields?.isEmpty != false, config?.root_path?.isEmpty != false,
           let apps=dictionary?["apps"] as? [[String:Any]],
           apps.allSatisfy({ $0["name"] is String && ($0["downloadURL"] is String || $0["versions"] is [[String:Any]]) }) {
            return data
        }
        var selected: Any? = input
        if let path=config?.root_path, !path.isEmpty { selected=value(input,path:path) }
        if config?.root_path?.isEmpty != false, !(selected is [[String:Any]]) {
            for path in ["apps","data","items","results","list","data.apps","data.items","data.list","data.results"] {
                if let found=value(input,path:path) as? [[String:Any]] { selected=found;break }
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
            "category":["category","category_id","genre"], "size":["size","file_size","size_bytes"]
        ]
        let mapped=rows.map { row -> [String:Any] in
            var result=row
            for (field,choices) in aliases {
                let paths: [String]
                if let mappedPath=config?.fields?[field] { paths=[mappedPath] } else { paths=choices }
                for path in paths {
                    if let found=value(row,path:path), !(found is NSNull) { result[field]=found;break }
                }
            }
            return result
        }
        let normalized=try XSignRESTSource.normalize(mapped)
        guard var root=(try JSONSerialization.jsonObject(with:normalized)) as? [String:Any] else { throw XSignCatalogError.invalidJSON }
        root["name"]=config?.name ?? dictionary?["name"] as? String ?? url.host ?? "المصدر"
        root["identifier"]=config?.id ?? dictionary?["identifier"] as? String ?? url.absoluteString
        root["iconURL"]=config?.icon_url ?? dictionary?["iconURL"] as? String ?? dictionary?["icon"] as? String
        if let subtitle=dictionary?["subtitle"] { root["subtitle"]=subtitle }
        if let categories=dictionary?["categories"] as? [[String:Any]] { root["categories"]=categories }
        return try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys])
    }
    private static func value(_ input: Any, path: String) -> Any? {
        guard path.utf8.count <= 300 else { return nil }
        return path.split(separator:".").reduce(Optional(input)) { result,key in (result as? [String:Any])?[String(key)] }
    }
}
