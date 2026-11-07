import Foundation

struct XSignManagedSource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let url: String
    var enabled: Bool? = true
    var format: String? = "auto"
    var icon_url: String? = nil
    var root_path: String? = nil
    var fields: [String: String]? = nil

    var safeURL: URL? { Self.httpsURL(url) }
    static func httpsURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
}

struct XSignStoreSection: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let page: String
    let kind: String
    var enabled: Bool? = true
    var limit: Int? = 12
    var source_url: String? = nil
    var category_id: String? = nil
    var app_ids: [String]? = nil
    var sort: String? = nil
    var boundedLimit: Int { min(120, max(1, limit ?? 12)) }
}

struct XSignOwnerUpdate: Codable, Equatable, Sendable {
    let enabled: Bool?
    let latest_version: String?
    let ipa_url: String?
    let sha256: String?
    let notes: String?
    let html: String?
    let manifest_url: String?
    let build_version: String?
    var verifiedURL: URL? {
        guard enabled == true, let sha256, sha256.count == 64,
              sha256.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }),
              let version = latest_version, XSignVersion.valid(version) else { return nil }
        return XSignManagedSource.httpsURL(ipa_url)
    }
}

struct XSignDashboardConfig: Codable, Equatable, Sendable {
    var catalog_profile: String? = nil
    let schema_version: Int?
    let sources: [XSignManagedSource]?
    let sections: [XSignStoreSection]?
    let tab_order: [String]?
    let allow_user_sources: Bool?
    let signing_enabled: Bool?
    let update: XSignOwnerUpdate?

    func sections(for page: String) -> [XSignStoreSection] {
        var seen = Set<String>()
        var layout = sections ?? Self.defaultSections
        if catalog_profile == nil, layout.contains(where: { $0.id == "apps-sources" && $0.kind == "sources" }) {
            layout = layout.flatMap { item -> [XSignStoreSection] in
                if item.id == "apps-sources" { return [.init(id:"apps-featured",title:"مختارات التطبيقات",page:"apps",kind:"featured")] }
                if item.id == "games-list" { return [.init(id:"games-featured",title:"مختارات الألعاب",page:"games",kind:"featured"), item] }
                return [item]
            }
        }
        return layout.filter {
            $0.page == page && $0.enabled != false && !$0.id.isEmpty && seen.insert($0.id).inserted &&
            ["news", "featured", "apps", "sources", "categories"].contains($0.kind)
        }.prefix(40).map { $0 }
    }
    static let defaultSections: [XSignStoreSection] = [
        .init(id:"today-news", title:"آخر الأخبار", page:"today", kind:"news"),
        .init(id:"today-featured", title:"مختارات IPA BLACK", page:"today", kind:"featured"),
        .init(id:"today-apps", title:"جديد المتجر", page:"today", kind:"apps"),
        .init(id:"apps-categories", title:"الأقسام", page:"apps", kind:"categories"),
        .init(id:"apps-featured", title:"مختارات التطبيقات", page:"apps", kind:"featured"),
        .init(id:"apps-list", title:"جميع التطبيقات", page:"apps", kind:"apps", limit:60),
        .init(id:"games-categories", title:"أقسام الألعاب", page:"games", kind:"categories"),
        .init(id:"games-featured", title:"مختارات الألعاب", page:"games", kind:"featured"),
        .init(id:"games-list", title:"الألعاب", page:"games", kind:"apps", limit:60)
    ]
}

enum XSignVersion {
    static func valid(_ text:String)->Bool { XSignReleaseVersion.valid(text) }
    static func older(_ current:String,than target:String)->Bool { XSignReleaseVersion.compare(current,target) == -1 }

}

enum XSignDashboardSources {
    static let profile = "zsign-public-v1"
    static let profileKey = "xsign.catalogProfile.v1"
    static let priorPlusURL = "https://supapi.trystore.net/rest/v1/plus_library_apps"
    static let key = "xsign.dashboardSources.v2"
    static let historyKey = "xsign.managedSourceHistory.v2"
    static let userKey = "xsign.explicitUserSources.v2"
    static var configured: [XSignManagedSource]? {
        UserDefaults.standard.data(forKey:key).flatMap { try? JSONDecoder().decode([XSignManagedSource].self,from:$0) }
            .map { migrated($0, profile: UserDefaults.standard.string(forKey:profileKey)) }.map(ordered)
    }
    static func migrated(_ sources: [XSignManagedSource], profile: String?) -> [XSignManagedSource] {
        // Upgrade the previous built-in provider only. Explicit deletions and
        // unrelated custom configuration survive. No empty-list reset.
        guard profile != Self.profile else { return sources }
        return sources.flatMap { item -> [XSignManagedSource] in
            guard item.id == "xsign.core.primary", item.url == priorPlusURL else { return [item] }
            return [
                .init(id:"xsign.core.primary",name:"ipasoon",url:ProtectedSourcesVault.primaryURLString,enabled:item.enabled),
                .init(id:"xsign.core.zsign",name:"متجر Zsign الرسمي",url:ProtectedSourcesVault.secondaryURLString,enabled:item.enabled)
            ]
        }
    }
    static func ordered(_ sources:[XSignManagedSource])->[XSignManagedSource] {
        func priority(_ source:XSignManagedSource)->Int {
            guard let url=source.safeURL else { return 3 }
            let value=XSignCatalogIO.canonicalURL(url).absoluteString
            if value==ProtectedSourcesVault.defaultOwnedURLString { return 0 }
            if value==ProtectedSourcesVault.primaryURLString { return 1 }
            if value==ProtectedSourcesVault.secondaryURLString { return 2 }
            return 3
        }
        return sources.enumerated().sorted {
            let lhs=priority($0.element),rhs=priority($1.element)
            return lhs==rhs ? $0.offset<$1.offset : lhs<rhs
        }.map(\.element)
    }
    static func configuration(for url: URL) -> XSignManagedSource? {
        configured?.first { item in
            guard let safe=item.safeURL else { return false }
            return XSignCatalogIO.canonicalURL(safe)==XSignCatalogIO.canonicalURL(url)
        }
    }
    static func registerUser(_ url: URL) {
        var urls=Set(UserDefaults.standard.stringArray(forKey:userKey) ?? [])
        urls.insert(XSignCatalogIO.canonicalURL(url).absoluteString)
        UserDefaults.standard.set(Array(urls),forKey:userKey)
    }
    static func isUserSource(_ url: URL) -> Bool {
        let value=XSignCatalogIO.canonicalURL(url).absoluteString
        let history=Set(UserDefaults.standard.stringArray(forKey:historyKey) ?? ProtectedSourcesVault.coreURLs)
        let explicit=Set(UserDefaults.standard.stringArray(forKey:userKey) ?? [])
        return explicit.contains(value) || !history.contains(value)
    }
    @discardableResult static func apply(_ config: XSignDashboardConfig?) -> Bool {
        guard config?.schema_version == 2, let sources=config?.sources else { return false }
        var seen=Set<String>(), seenURLs=Set<String>()
        let valid=ordered(migrated(sources, profile: config?.catalog_profile).prefix(50).compactMap { item -> XSignManagedSource? in
            guard !item.id.isEmpty, !item.name.isEmpty, item.enabled != false, let url=item.safeURL,
                  seen.insert(item.id).inserted, seenURLs.insert(XSignCatalogIO.canonicalURL(url).absoluteString).inserted else { return nil }
            var value=item
            value = XSignManagedSource(id:item.id,name:item.name,url:XSignCatalogIO.canonicalURL(url).absoluteString,
                enabled:true,format:item.format,icon_url:item.icon_url,root_path:item.root_path,fields:item.fields)
            return value
        })
        let changed=configured != valid
        var history=Set(UserDefaults.standard.stringArray(forKey:historyKey) ?? ProtectedSourcesVault.coreURLs)
        configured?.forEach { history.insert($0.url) };valid.forEach { history.insert($0.url) }
        UserDefaults.standard.set(Array(history),forKey:historyKey)
        if let data=try? JSONEncoder().encode(valid) { UserDefaults.standard.set(data,forKey:key) }
        UserDefaults.standard.set(profile,forKey:profileKey)
        return changed
    }
}
