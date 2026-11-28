import Foundation
import CryptoKit

struct XSignManagedSource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let url: String
    var enabled: Bool? = true
    var format: String? = "auto"
    var icon_url: String? = nil
    var root_path: String? = nil
    var fields: [String: String]? = nil
    var numeric_types: Bool? = nil

    var safeURL: URL? {
        id == XSignCatalogueEndpoint.ownerID ? XSignCatalogueEndpoint.ownerURL : Self.httpsURL(url)
    }
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
    var continuous: Bool? = nil
    var continuesTodayFeed: Bool {
        page == "today" && isGeneralList && enabled != false &&
            (continuous ?? (id == "today-apps"))
    }
    var boundedLimit: Int { min(120, max(1, limit ?? 12)) }
    var previewLimit: Int {
        kind == "featured" && page != "today" ? min(18, boundedLimit) : boundedLimit
    }
    var isGeneralList: Bool {
        kind == "apps" && source_url == nil && category_id == nil && app_ids?.isEmpty != false
    }
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
    // nil keeps the minimum-version rule used by previously published policies.
    var required: Bool? = nil
    var required_policy: String? = nil
    var bundle_identifier: String? = nil
    var app_name: String? = nil
    var build_request_id: String? = nil
    var manifestURL: URL? {
        guard enabled == true, let latest_version, XSignVersion.valid(latest_version),
              required != true || XSignVersion.valid(build_version ?? "") else { return nil }
        return XSignManagedSource.httpsURL(manifest_url)
    }
    var verifiedURL: URL? {
        guard enabled == true, let sha256, sha256.count == 64,
              sha256.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }),
              let version = latest_version, XSignVersion.valid(version) else { return nil }
        return XSignManagedSource.httpsURL(ipa_url)
    }
    func targets(_ installedBundle: String) -> Bool {
        guard let bundle = bundle_identifier, !bundle.isEmpty else { return true }
        return bundle.caseInsensitiveCompare(installedBundle) == .orderedSame
    }
    var installable: Bool {
        if required == true, required_policy != nil, !XSignVersion.valid(build_version ?? "") { return false }
        if let build_request_id, !build_request_id.isEmpty, targetBuildRequest == nil { return false }
        guard build_version == nil || build_version == "" || XSignVersion.valid(build_version ?? "") else { return false }
        if !(manifest_url ?? "").isEmpty { return manifestURL != nil }
        return verifiedURL != nil
    }
    var targetBuild: String? { build_version.flatMap { $0.isEmpty ? nil : $0 } }
    var targetBuildRequest: String? {
        guard let build_request_id,
              build_request_id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { return nil }
        return build_request_id
    }
    var releaseOrigin: String? {
        guard let link = XSignManagedSource.httpsURL((manifest_url ?? "").isEmpty ? ipa_url : manifest_url) else { return nil }
        let value = link.absoluteString
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func needsUpdate(version: String, build: String, origin: String?, request: String?) -> Bool {
        guard enabled == true, let latest_version, XSignReleaseVersion.valid(latest_version) else { return false }
        if required == true && ["approved", "approved_origin"].contains(required_policy ?? ""), let targetBuild {
            return !XSignReleaseVersion.isApproved(currentVersion: version, currentBuild: build,
                installedOrigin: origin, targetVersion: latest_version, targetBuild: targetBuild,
                targetOrigin: releaseOrigin ?? "", requireOrigin: required_policy == "approved_origin",
                installedRequest: request, targetRequest: targetBuildRequest, allowUnstampedIPA: manifestURL == nil)
        }
        if required_policy == "minimum" {
            return !XSignReleaseVersion.valid(version) || !XSignReleaseVersion.valid(build) ||
                XSignReleaseVersion.isNewer(currentVersion: version, currentBuild: build,
                    targetVersion: latest_version, targetBuild: targetBuild)
        }
        return XSignReleaseVersion.requiresUpdate(currentVersion: version, currentBuild: build,
            installedOrigin: origin, targetVersion: latest_version, targetBuild: targetBuild,
            targetOrigin: releaseOrigin ?? "", installedRequest: request, targetRequest: targetBuildRequest)
    }
    var installIdentity: [String?] { [latest_version, targetBuild, releaseOrigin, sha256?.lowercased(), bundle_identifier?.lowercased(), targetBuildRequest] }
    var promptIdentity: String? {
        guard installable else { return nil }
        return installIdentity.map { $0 ?? "" }.joined(separator: "|")
    }
}

struct XSignSigningLibrary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let url: String
    let sha256: String
    let bundles: [String]
    let enabled: Bool

    nonisolated var downloadURL: URL? {
        guard id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let link = XSignManagedSource.httpsURL(url), link.port == nil || link.port == 443,
              link.query == nil, link.lastPathComponent.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,100}\.dylib$"#,
                  options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return link
    }

    nonisolated func matches(_ bundle: String) -> Bool {
        enabled && downloadURL != nil && !bundle.isEmpty && (1...30).contains(bundles.count) &&
            bundles.contains { $0.caseInsensitiveCompare(bundle) == .orderedSame }
    }
}

struct XSignDashboardConfig: Codable, Equatable, Sendable {
    var experience_version: Int? = nil
    var catalog_profile: String? = nil
    let schema_version: Int?
    let sources: [XSignManagedSource]?
    let sections: [XSignStoreSection]?
    let tab_order: [String]?
    let allow_user_sources: Bool?
    let signing_enabled: Bool?
    let update: XSignOwnerUpdate?
    var bundle_updates: [String: XSignOwnerUpdate]? = nil
    var today_source_ids: [String]? = nil
    var today_show_date: Bool? = nil
    var today_show_account: Bool? = nil
    var today_show_download_buttons: Bool? = nil
    var signing_libraries: [XSignSigningLibrary]? = nil

    static let originalBundleIdentifier = "com.ipablack.xsign"
    static let primaryBundleIdentifier = "xsign"

    func update(for bundleIdentifier: String?) -> XSignOwnerUpdate? {
        guard let bundle = bundleIdentifier?.lowercased() else { return nil }
        let scoped = bundle_updates?[bundle] ?? bundle_updates?.first {
            $0.key.caseInsensitiveCompare(bundle) == .orderedSame
        }?.value
        let release = scoped ?? update.flatMap {
            bundle == Self.originalBundleIdentifier ||
                (bundle == Self.primaryBundleIdentifier && ($0.bundle_identifier ?? "").isEmpty) ||
                $0.bundle_identifier?.lowercased() == bundle ? $0 : nil
        }
        guard release?.targets(bundle) == true else { return nil }
        return release
    }

    var userSourcesEnabled: Bool {
        (experience_version ?? 0) < 2 || allow_user_sources != false
    }

    func sections(for page: String) -> [XSignStoreSection] {
        var seen = Set<String>()
        var seenCategories = false
        var layout = sections ?? Self.defaultSections
        if let index = layout.firstIndex(where: { $0.page == "apps" && $0.kind == "apps" }),
           !layout.contains(where: { $0.page == "apps" && $0.kind == "featured" }),
           let featured = Self.defaultSections.first(where: { $0.id == "apps-featured" }) {
            layout.insert(featured, at: index)
        }
        if (experience_version ?? 0) < 3,
           layout.contains(where: { $0.page == "today" }),
           !layout.contains(where: { $0.page == "today" && ["apps", "featured"].contains($0.kind) }) {
            layout += Self.defaultSections.filter { $0.page == "today" && $0.kind != "news" }
        }
        return layout.filter {
            guard $0.page == page, $0.enabled != false, !$0.id.isEmpty, seen.insert($0.id).inserted,
                  ["news", "featured", "apps", "categories"].contains($0.kind) else { return false }
            if $0.kind == "categories" {
                guard !seenCategories else { return false }
                seenCategories = true
            }
            return true
        }.prefix(40).map { $0 }
    }
    static let defaultSections: [XSignStoreSection] = [
        .init(id:"today-news", title:"آخر الأخبار", page:"today", kind:"news"),
        .init(id:"today-featured", title:"مختارات اليوم", page:"today", kind:"featured", limit:2),
        .init(id:"today-apps", title:"جديد المتجر", page:"today", kind:"apps"),
        .init(id:"apps-categories", title:"الأقسام", page:"apps", kind:"categories"),
        .init(id:"apps-featured", title:"مختارات التطبيقات", page:"apps", kind:"featured"),
        .init(id:"apps-list", title:"جميع التطبيقات", page:"apps", kind:"apps", limit:60),
        .init(id:"games-categories", title:"أقسام الألعاب", page:"games", kind:"categories"),
        .init(id:"games-featured", title:"مختارات الألعاب", page:"games", kind:"featured"),
        .init(id:"games-list", title:"الألعاب", page:"games", kind:"apps", limit:60)
    ]
}

enum XSignCatalogKindPolicy {
    private static let keyLocale = Locale(identifier: "en_US_POSIX")

    static func categoryKey(_ value: String?) -> String? {
        let folded = value?.folding(options: [.caseInsensitive, .diacriticInsensitive],
            locale: keyLocale).replacingOccurrences(of: "[أإآٱ]", with: "ا", options: .regularExpression) ?? ""
        let parts = folded.split { !$0.isLetter && !$0.isNumber }
        return parts.isEmpty ? nil : parts.joined(separator: "-")
    }

    static func categoryKind(_ value: String?) -> Bool? {
        guard let category = categoryKey(value) else { return nil }
        if let genre = Int(category) {
            if genre == 6014 || (7001...7019).contains(genre) { return true }
            if (6000...6027).contains(genre) { return false }
        }
        if category.hasPrefix("games-") || category.hasSuffix("-games") ||
           category.hasPrefix("العاب-") || category.hasPrefix("الالعاب-") { return true }
        switch category {
        case "game", "games", "gaming", "6014", "العاب", "الالعاب", "لعبة", "بلياردو", "pluardo",
             "action", "adventure", "arcade", "puzzle", "strategy", "simulation", "racing", "role-playing",
             "تسالي", "محاكاة", "استراتيجية", "الغاز", "اكشن", "مغامرات":
            return true
        case "app", "apps", "applications", "تطبيقات", "التطبيقات", "social", "social-networking",
             "media", "tools", "developer", "utilities", "productivity", "business", "education", "news", "music",
             "entertainment", "photo-video", "health-fitness", "finance", "sports", "books", "shopping",
             "travel", "navigation", "lifestyle", "التواصل-الاجتماعي", "ادوات", "انتاجية", "صور-وفيديو",
             "الصور-والفيديو", "ترفيه", "الترفيه", "موسيقى":
            return false
        default: return nil
        }
    }

    static func showsInPage(_ page: String, isGame: Bool) -> Bool {
        switch page {
        case "apps": return !isGame
        case "games": return isGame
        default: return true
        }
    }

    struct TypeEvidence: Sendable {
        let game: Bool
        let priority: Int
    }

    static func preferred(_ current: TypeEvidence?, _ candidate: TypeEvidence) -> TypeEvidence {
        guard let current, current.priority >= candidate.priority else { return candidate }
        return current
    }

    nonisolated static func knownGameBundle(_ bundleID: String?) -> Bool {
        guard let bundle = bundleKey(bundleID) else { return false }
        return gameIDs.contains { bundle == $0 || bundle.hasPrefix($0 + ".") }
    }

    private static let gameIDs = ["com.roblox.robloxmobile", "com.mojang.minecraftpe", "com.miniclip.eightballpool",
                       "com.supercell.clashofclans", "com.supercell.clashroyale", "com.supercell.brawlstars",
                       "com.tencent.ig", "com.ea.gp.fifamobile", "com.epicgames.fortnite", "com.kiloo.subwaysurfers",
                       "com.callofduty.mobile", "com.dts.freefireth", "com.riotgames.league.wildrift",
                       "com.activision.callofduty.shooter", "com.habby.archero", "com.ea.ios.pvz2inc"]

    nonisolated static func recognizesGame(name: String, bundleID: String?) -> Bool {
        if knownGameBundle(bundleID) { return true }
        let bundle = bundleKey(bundleID) ?? ""
        let gamePublishers = ["com.gameloft.", "com.supercell.", "com.miniclip.", "com.king.", "com.ea.games.",
                              "com.rovio.", "com.kiloo.", "com.playrix.", "com.nekki."]
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let title = words.joined(separator: " ")
        let auxiliary: Set<String> = ["guide", "companion", "tracker", "wallpaper", "launcher", "دليل", "خلفيات"]
        guard !words.contains(where: { auxiliary.contains(String($0)) }) else { return false }
        if gamePublishers.contains(where: { bundle.hasPrefix($0) }) { return true }
        let names = ["pubg mobile", "8 ball pool", "roblox", "minecraft", "call of duty", "free fire", "fortnite",
                     "brawl stars", "clash royale", "clash of clans", "efootball", "ea sports fc mobile", "fifa mobile",
                     "gangstar vegas", "grand theft auto", "truck simulator", "car parking multiplayer", "subway surfers", "rocket league sideswipe",
                     "candy crush", "royal match", "gardenscapes", "homescapes", "angry birds", "temple run", "sudoku",
                     "chess", "genshin impact", "honkai star rail", "shadow fight", "afk journey", "cats soup",
                     "adventure capitalist", "egg inc", "bloons td", "geometry dash", "stardew valley",
                     "pokemmo", "honkai impact", "zenless zone zero", "league of legends", "wild rift",
                     "hill climb racing", "asphalt legends", "ludo king", "ببجي", "روبلوكس", "ماين كرافت", "فري فاير",
                     "كلاش رويال", "براول ستارز", "محاكي الشاحنات"]
        return names.contains { title == $0 || title.hasPrefix($0 + " ") }
    }

    nonisolated static func bundleKey(_ value: String?) -> String? {
        guard let key = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !key.isEmpty else { return nil }
        return key
    }
}

enum XSignTodaySourcePolicy {
    nonisolated static func allows(id: String?, url: URL?, selected: Set<String>? = nil) -> Bool {
        guard let url else { return false }
        if let selected { return id.map(selected.contains) ?? false }
        return url == XSignCatalogueEndpoint.ownerURL || id == XSignCatalogueEndpoint.primaryID
    }

    nonisolated static func interleave<Item>(_ groups: [[Item]]) -> [Item] {
        guard groups.count > 1 else { return groups.first ?? [] }
        let longest = groups.map(\.count).max() ?? 0
        var result: [Item] = []
        result.reserveCapacity(groups.reduce(0) { $0 + $1.count })
        for offset in 0..<longest {
            for group in groups where offset < group.count { result.append(group[offset]) }
        }
        return result
    }
}

enum XSignNetworkPolicy {
    static func hasEnabledProxy(in settings: [String: Any]) -> Bool {
        ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
            .contains { (settings[$0] as? NSNumber)?.boolValue == true }
    }

    static func isTunnelInterface(_ input: String) -> Bool {
        let name = input.lowercased()
        return ["utun", "tun", "tap", "ppp", "ipsec", "wg", "pptp", "l2tp"].contains { prefix in
            let suffix = name.dropFirst(prefix.count)
            return name.hasPrefix(prefix) && !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
    }

    static func isActiveTunnelInterface(_ name: String, activeInterfaces: Set<String>) -> Bool {
        activeInterfaces.contains(name) && isTunnelInterface(name)
    }

    static func hasUsableTunnelAddress(_ bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4:
            return bytes[0] != 0 && bytes[0] != 127 && bytes[0] < 224 &&
                !(bytes[0] == 169 && bytes[1] == 254)
        case 16:
            return bytes[0] != 0xff && !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) &&
                bytes.dropLast().contains { $0 != 0 }
        default:
            return false
        }
    }

    static func shouldBlock(enabled: Bool?, detected: Bool) -> Bool {
        enabled != false && detected
    }
}

enum XSignVersion {
    static func valid(_ text:String)->Bool { XSignReleaseVersion.valid(text) }
    static func older(_ current:String,than target:String)->Bool { XSignReleaseVersion.compare(current,target) == -1 }

}

enum XSignDashboardSources {
    static let profile = "iosboom-public-v1"
    static let key = "xsign.dashboardSources.v2"
    static let historyKey = "xsign.managedSourceHistory.v2"
    static let userKey = "xsign.explicitUserSources.v2"
    static let hiddenKey = "xsign.hiddenManagedSources.v1"
    private static let cachePolicyKey = "xsign.managedCachePolicy.v1"

    static var cachePolicyID: String {
        UserDefaults.standard.string(forKey: cachePolicyKey) ?? ""
    }

    nonisolated static let owned = XSignManagedSource(id: XSignCatalogueEndpoint.ownerID, name: "IPA BLACK",
        url: XSignCatalogueEndpoint.ownerURL.absoluteString)

    static var managed: [XSignManagedSource]? {
        UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([XSignManagedSource].self, from: $0) }
            .map(normalized)
    }

    static var configured: [XSignManagedSource]? {
        managed.map { $0.filter { $0.enabled != false && !isHidden($0.url) } }
    }

    static func resetManaged() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.set(UUID().uuidString, forKey: cachePolicyKey)
    }

    nonisolated static func sourceKey(_ url: URL) -> String {
        let canonical = XSignCatalogIO.canonicalURL(url)
        if canonical.absoluteString.lowercased() == XSignCatalogueEndpoint.publicCatalogue.absoluteString.lowercased() {
            return owned.url
        }
        if canonical.absoluteString.hasSuffix("/") {
            return String(canonical.absoluteString.dropLast())
        }
        return canonical.absoluteString
    }

    static func normalized(_ sources: [XSignManagedSource]) -> [XSignManagedSource] {
        var ids: Set<String> = [owned.id]
        var urls: Set<String> = [owned.url]
        let owner = sources.first { $0.id == owned.id }
        let others = sources.compactMap { source -> XSignManagedSource? in
            guard !source.id.isEmpty, !source.name.isEmpty, let input = source.safeURL else { return nil }
            let url = XSignCatalogIO.canonicalURL(input)
            let key = sourceKey(url)
            guard !ids.contains(source.id), !urls.contains(key) else { return nil }
            ids.insert(source.id)
            urls.insert(key)
            return .init(id: source.id, name: source.name, url: url.absoluteString,
                enabled: source.enabled != false, format: source.format, icon_url: source.icon_url,
                root_path: source.root_path, fields: source.fields, numeric_types: source.numeric_types)
        }
        let pinned = XSignManagedSource(id: owned.id, name: owned.name, url: owned.url, icon_url: owner?.icon_url)
        return [pinned] + Array(others.prefix(49))
    }

    static func configuration(for url: URL) -> XSignManagedSource? {
        let key = sourceKey(url)
        return configured?.first { $0.safeURL.map(sourceKey) == key }
    }

    nonisolated static func sectionSource(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value) else { return nil }
        return sourceKey(url) == owned.url ? owned.safeURL : XSignCatalogIO.canonicalURL(url)
    }

    static func isHidden(_ url: String) -> Bool {
        guard let value = URL(string: url), sourceKey(value) != owned.url else { return false }
        return (UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []).contains(sourceKey(value))
    }

    static func setHidden(_ hidden: Bool, url: String) {
        guard let value = URL(string: url), sourceKey(value) != owned.url else { return }
        var urls = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        if hidden { urls.insert(sourceKey(value)) } else { urls.remove(sourceKey(value)) }
        UserDefaults.standard.set(Array(urls), forKey: hiddenKey)
    }

    static func registerUser(_ url: URL) {
        var urls = Set(UserDefaults.standard.stringArray(forKey: userKey) ?? [])
        urls.insert(sourceKey(url))
        UserDefaults.standard.set(Array(urls), forKey: userKey)
    }

    static func unregisterUser(_ url: URL) {
        let urls = UserDefaults.standard.stringArray(forKey: userKey) ?? []
        UserDefaults.standard.set(urls.filter { URL(string: $0).map(sourceKey) != sourceKey(url) }, forKey: userKey)
    }

    static func isExplicitUserSource(_ url: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: userKey) ?? [])
            .contains { URL(string: $0).map(sourceKey) == sourceKey(url) }
    }

    static func isUserSource(_ url: URL) -> Bool {
        let value = sourceKey(url)
        let history = UserDefaults.standard.stringArray(forKey: historyKey) ?? ProtectedSourcesVault.coreURLs
        return value != owned.url && (isExplicitUserSource(url) ||
            !history.contains { URL(string: $0).map(sourceKey) == value })
    }

    @discardableResult static func apply(_ config: XSignDashboardConfig?, legacy: [XSignCoreSourceItem]? = nil) -> Bool {
        let sources = (config?.schema_version == 2 ? config?.sources : nil) ??
            legacy?.map { XSignManagedSource(id: $0.id, name: $0.name, url: $0.url) }
        guard let sources else { return false }
        let valid = normalized(sources)
        let previous = managed
        guard previous != valid, let data = try? JSONEncoder().encode(valid) else { return false }
        var history = Set(UserDefaults.standard.stringArray(forKey: historyKey) ?? ProtectedSourcesVault.coreURLs)
        previous?.forEach { history.insert($0.url) }
        valid.forEach { history.insert($0.url) }
        UserDefaults.standard.set(Array(history), forKey: historyKey)
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(UUID().uuidString, forKey: cachePolicyKey)
        return true
    }
}
