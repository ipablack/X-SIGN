import Foundation

@main
struct ApprovedSourceChecks {
    static func main() async throws {
        let manifestURL = URL(string: "https://example.test/setup.plist?key=a+b")!
        let payloadURL = URL(string: "https://example.test/package.ipa")!
        let wrapper = "itms-services://?action=download-manifest&url=https%3A%2F%2Fexample.test%2Fsetup.plist%3Fkey%3Da%2Bb"
        let input = try XSignImportLink.parse(wrapper)
        precondition(input == .manifest(manifestURL))
        let direct = try XSignImportLink.parse(payloadURL.absoluteString)
        precondition(direct == .package(payloadURL))
        for bad in [wrapper + "&url=https://example.test/second.plist",
                    "itms-services://?action=download-manifest&url=http://example.test/a.plist",
                    "https://user:secret@example.test/a.ipa"] {
            do { _ = try XSignImportLink.parse(bad); preconditionFailure("Invalid link accepted") }
            catch XSignImportLink.ValidationError.link {}
        }
        let asset = ["kind": "software-package", "url": payloadURL.absoluteString]
        let image = ["kind": "display-image", "url": "https://example.test/app.png"]
        func manifest(_ assets: [[String: String]]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["items": [
                ["metadata": ["title": "Example App", "bundle-version": "2.3"], "assets": assets]
            ]], format: .xml, options: 0)
        }
        let preview = try XSignImportLink.parseManifest(manifest([asset, image]))
        precondition(preview == .init(package: payloadURL, title: "Example App", version: "2.3"))
        do {
            _ = try XSignImportLink.parseManifest(manifest([asset, asset]))
            preconditionFailure("Multiple package assets accepted")
        } catch XSignImportLink.ValidationError.manifest {}

        let original = "com.example.demo"
        guard let copy = XSignAppMetadata.cloneIdentifier(from: original,
            nonce: UUID(uuidString: "8DB963AB-0098-49E6-82D2-A6FB27689A57")!) else {
            preconditionFailure("A valid app must have a clone identifier")
        }
        precondition(copy.hasPrefix(original + ".xsign-"))
        precondition(copy != XSignAppMetadata.cloneIdentifier(from: original))
        precondition(XSignAppMetadata.errorMessage(for: copy, field: .bundleIdentifier) == nil)
        precondition(XSignAppMetadata.cloneIdentifier(from: "") == nil)
        let info = NSMutableDictionary(dictionary: ["CFBundleIdentifier": original, "CFBundleName": "Original"])
        try XSignAppMetadata.apply(name: "Edited", bundleIdentifier: copy, version: "2.0", to: info)
        precondition(info["CFBundleDisplayName"] as? String == "Edited")
        precondition(info["CFBundleName"] as? String == "Edited")
        precondition(info["CFBundleIdentifier"] as? String == copy)
        precondition(info["CFBundleShortVersionString"] as? String == "2.0")
        let policyKeys=[XSignDashboardSources.key,XSignDashboardSources.historyKey,XSignDashboardSources.userKey,XSignDashboardSources.hiddenKey]
        let savedPolicy=policyKeys.map { UserDefaults.standard.object(forKey:$0) }
        policyKeys.forEach { UserDefaults.standard.removeObject(forKey:$0) }
        defer { for (key,value) in zip(policyKeys,savedPolicy) {
            if let value { UserDefaults.standard.set(value,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) }
        } }
        let owner = XSignCatalogueEndpoint.ownerURL
        let signingLibrary = XSignSigningLibrary(id: String(repeating: "a", count: 32), name: "Example",
            url: "https://example.test/Library.dylib", sha256: String(repeating: "b", count: 64),
            bundles: ["com.example.tools"], enabled: true)
        precondition(signingLibrary.matches("COM.Example.Tools"))
        precondition(!signingLibrary.matches("com.example.other"))
        precondition(!signingLibrary.matches(""))
        precondition(ProtectedSourcesVault.coreURLs == [owner.absoluteString])
        precondition(ProtectedSourcesVault.ownedURL == owner)
        precondition(!ProtectedSourcesVault.isRetiredSource(owner))
        precondition(ProtectedSourcesVault.isRetiredSource(URL(string: "http://sources.example.test")))
        precondition(SourceSelection.resolvedManagedSources(nil).map(\.url) ==
            [owner.absoluteString, XSignCatalogueEndpoint.soonSnapshot.absoluteString,
             XSignCatalogueEndpoint.iosBoomCatalogue.absoluteString])
        let catalogue = XSignCatalogueEndpoint.ownerRequest(settings: false)
        let config = XSignCatalogueEndpoint.ownerRequest(settings: true)
        precondition(catalogue.url?.absoluteString == "https://raw.githubusercontent.com/ipablack/repo/main/repo.json")
        precondition(config.url?.absoluteString == "https://raw.githubusercontent.com/ipablack/repo/main/xsign-config.json")
        precondition(XSignCatalogueEndpoint.soonSnapshot.absoluteString ==
            "https://raw.githubusercontent.com/ipablack/repo/main/public/sources/ipasoon.json")
        precondition(catalogue.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(config.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(XSignDashboardSources.sectionSource(catalogue.url?.absoluteString) == owner)
        precondition(XSignCatalogueEndpoint.isOriginalSoon(URL(string: "https://appiraq.com/source.php?action=getAll")!))
        let soon = URL(string: "https://appiraq.com/source.php?action=getAll")!
        precondition(XSignCatalogueEndpoint.archivedSoon(for: soon, sourceID: nil) == XSignCatalogueEndpoint.soonSnapshot)
        precondition(XSignCatalogueEndpoint.archivedSoon(for: soon, sourceID: XSignCatalogueEndpoint.primaryID) == XSignCatalogueEndpoint.soonSnapshot)
        precondition(XSignCatalogueEndpoint.archivedSoon(for: soon, sourceID: "unrelated") == nil)
        precondition(XSignCatalogueEndpoint.archivedSoon(for: XSignCatalogueEndpoint.soonSnapshot, sourceID: XSignCatalogueEndpoint.primaryID) == nil)
        let fallback = XSignCatalogueEndpoint.alternatePublicRequest(for: XSignCatalogueEndpoint.soonSnapshot)
        precondition(fallback?.url?.host == "api.github.com")
        precondition(fallback?.url?.path == "/repos/ipablack/repo/contents/public/sources/ipasoon.json")
        precondition(fallback?.url?.query == "ref=main")
        precondition(fallback?.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
        precondition(fallback?.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(XSignCatalogueEndpoint.alternatePublicRequest(for: soon) == nil)
        precondition(AppStore2026Category.importedTitle("Social") == "التواصل الاجتماعي")
        precondition(!XSignCatalogueEndpoint.isOriginalSoon(URL(string: "https://other.test/source.php?action=getAll")!))
        precondition(XSignCatalogueEndpoint.iosBoomFeeds.count == 3)
        precondition(XSignCatalogIO.canonicalURL(URL(string: "https://repository.apptesters.org")!) ==
            XSignCatalogueEndpoint.iosBoomFeeds[0])
        let publicFeed = Data(#"""
        {"name":"Public feed","apps":[
          {"name":"Game","bundleIdentifier":"com.example.game","type":2,"versionDate":"2026-11-23T01:05:00Z",
           "version":"1.0","downloadURL":"https://example.test/game.ipa","permissions":{"invalid":true}},
          {"name":"Tool","type":4,"versionDate":"unknown","versions":[
            {"version":"2.0","downloadURL":"https://example.test/tool.ipa"},
            {"version":"1.0","downloadURL":"http://example.test/old.ipa"}
          ]},
          {"name":"Paid","purchase_required":true,"downloadURL":"https://example.test/paid.ipa"},
          {"name":"Private","downloadURL":"https://example.test/file.ipa?token=example"}
        ]}
        """#.utf8)
        let publicData = try XSignSourceAdapter.normalize(publicFeed, from: XSignCatalogueEndpoint.iosBoomFeeds[1])
        let publicRepository = try JSONDecoder().decode(ASRepository.self, from: publicData)
        precondition(publicRepository.apps.count == 2)
        precondition(publicRepository.apps[0].isGame == true && publicRepository.apps[0].versionDate != nil)
        precondition(publicRepository.apps[1].category == "utilities" && publicRepository.apps[1].versions?.count == 1)

        let rows: [[String: Any]] = [
            ["id": "one", "name": "Name", "name_ar": "الاسم", "description_ar": "الوصف", "developer_name": "Developer", "bundle_id": "com.example.app", "download_url": "https://example.test/app.ipa", "version": "1.2"],
            ["id": "hidden", "name": "Hidden", "download_url": "https://example.test/hidden.ipa", "is_hidden": true],
            ["id": "restricted", "name": "Restricted", "download_url": "https://example.test/restricted.ipa", "allow_ipa_download": false],
            ["id": "purchase", "name": "Purchase", "download_url": "https://example.test/purchase.ipa", "purchase_required": true]
        ]
        let converted = try XSignRESTSource.normalize(rows)
        let root = try JSONSerialization.jsonObject(with: converted) as! [String: Any]
        let apps = root["apps"] as! [[String: Any]]
        precondition(apps.count == 1 && apps[0]["name"] as? String == "الاسم")
        precondition(apps[0]["developerName"] as? String == "Developer")
        precondition(apps[0]["bundleIdentifier"] as? String == "com.example.app")
        precondition(apps[0]["downloadURL"] as? String == "https://example.test/app.ipa")
        let publicRows: [[String: Any]] = [
            ["id":"public-plus", "name":"Public", "bundle_id":"com.example.public", "version":"1.0",
             "download_url":"https://example.test/public.ipa", "allow_ipa_download":false,
             "purchase_required":false, "category":"Games"],
            ["id":"metadata-only", "name":"Metadata", "download_url":NSNull(),
             "allow_ipa_download":false, "purchase_required":false],
            ["id":"paid-plus", "name":"Paid", "download_url":"https://example.test/paid.ipa",
             "allow_ipa_download":false, "purchase_required":true],
            ["id":"hidden-plus", "name":"Hidden", "download_url":"https://example.test/hidden.ipa",
             "allow_ipa_download":false, "purchase_required":false, "hide_in_library":true],
            ["id":"unknown-permission", "name":"Unknown", "download_url":"https://example.test/unknown.ipa",
             "allow_ipa_download":false]
        ]
        let plusData = try XSignRESTSource.normalize(publicRows, allowPublishedFreeLinks: true)
        let plusRoot = try JSONSerialization.jsonObject(with: plusData) as! [String: Any]
        let plusApps = plusRoot["apps"] as! [[String: Any]]
        precondition(plusApps.count == 1)
        precondition(plusApps[0]["bundleIdentifier"] as? String == "com.example.public")
        precondition(plusRoot["name"] as? String == "متجر بلس")
        precondition((plusRoot["categories"] as! [[String: Any]])[0]["isGame"] as? Bool == true)
        // A shared category does not erase explicit per-app types or invent a type for unlabelled rows.
        let mixedRows: [[String: Any]] = [
            ["name": "Tool", "id": "tool", "category": "Mixed", "is_game": false, "ipa_url": "https://example.test/tool.ipa"],
            ["name": "Game", "id": "game", "category": "Mixed", "isGame": true, "ipa_url": "https://example.test/game.ipa"],
            ["name": "Unknown type", "id": "other", "category": "Mixed", "ipa_url": "https://example.test/other.ipa"]
        ]
        let mixedData = try XSignRESTSource.normalize(mixedRows)
        let mixed = try JSONSerialization.jsonObject(with: mixedData) as! [String: Any]
        let mixedApps = mixed["apps"] as! [[String: Any]]
        precondition(mixedApps.count == 3)
        precondition(mixedApps[0]["isGame"] as? Bool == false && mixedApps[1]["isGame"] as? Bool == true)
        precondition(mixedApps[2]["isGame"] == nil)
        precondition((mixed["categories"] as! [[String: Any]])[0]["isGame"] == nil)
        precondition(XSignCatalogKindPolicy.categoryKind("6014") == true)
        precondition(XSignCatalogKindPolicy.categoryKind("Utilities") == false)
        precondition(XSignCatalogKindPolicy.categoryKind("General") == nil)
        precondition(XSignCatalogKindPolicy.bundleKey(" COM.EXAMPLE.GAME ") == "com.example.game")
        precondition(XSignCatalogKindPolicy.recognizesGame(name: "Truck Simulator USA", bundleID: nil))
        precondition(!XSignCatalogKindPolicy.recognizesGame(name: "Truck Route Tracker", bundleID: nil))
        precondition(!XSignCatalogKindPolicy.recognizesGame(name: "Roblox Companion", bundleID: "com.example.guide"))
        let split = Data(#"{"apps":[{"id":"app","name":"Utility","download_url":"https://example.test/app.ipa"}],"games":[{"id":"game","name":"Example Game","download_url":"https://example.test/game.ipa"}]}"#.utf8)
        let splitData = try XSignSourceAdapter.normalize(split, from: URL(string: "https://example.test/catalog.json")!)
        let splitRoot = try JSONSerialization.jsonObject(with: splitData) as! [String: Any]
        let splitApps = splitRoot["apps"] as! [[String: Any]]
        let gameRow = splitApps.first { $0["name"] as? String == "Example Game" }
        precondition(splitApps.count == 2)
        precondition(gameRow?["isGame"] as? Bool == true)
        let genericTaxonomy = Data(#"{"data":{"games":[{"name":"Sea Race","category_id":"race","ipa":"https://example.test/race.ipa"}],"gameCategories":{"race":"سباقات البحر"}}}"#.utf8)
        let raceData = try XSignSourceAdapter.normalize(genericTaxonomy, from: URL(string: "https://example.test/races.json")!)
        let races = try JSONDecoder().decode(ASRepository.self, from: raceData)
        precondition(races.categories?.first(where: { $0.id == "race" })?.name == "سباقات البحر")
        precondition(races.categories?.first(where: { $0.id == "race" })?.isGame == true && races.apps.first?.isGame == true)
        let numericREST = try XSignRESTSource.normalize([
            ["name": "Numeric game", "type": 2, "category_id": 7013, "download_url": "https://example.test/race.ipa"],
            ["name": "Numeric tool", "type": 2, "is_game": "0", "categoryId": 7013,
             "category_name": "سباقات", "download_url": "https://example.test/tool.ipa"],
            ["name": "Explicit tool", "type": 2, "contentType": "app", "category": "tools",
             "download_url": "https://example.test/explicit.ipa"]
        ], numericTypes: true)
        let numericRepo = try JSONDecoder().decode(ASRepository.self, from: numericREST)
        precondition(numericRepo.apps.map(\.isGame) == [true, false, false])
        precondition(numericRepo.apps[0].category == "7013" && numericRepo.categories?.first?.name == "سباقات")
        let combined = Data(#"{"data":{"apps":[{"name":"Tool","category_id":12,"ipa":"https://example.test/one.ipa"},{"name":"Art app","category_id":13,"ipa":"https://example.test/two.ipa"}],"categories":{"12":"أدوات المكتب"}}}"#.utf8)
        let combinedData = try XSignSourceAdapter.normalize(combined, from: URL(string: "https://example.test/catalogue")!)
        let combinedRepo = try JSONDecoder().decode(ASRepository.self, from: combinedData)
        precondition(combinedRepo.categories?.map(\.name) == ["أدوات المكتب", "13"])
        let metadataOnly = try XSignRESTSource.normalize([publicRows[1]], allowPublishedFreeLinks: true)
        let metadataRoot = try JSONSerialization.jsonObject(with: metadataOnly) as! [String: Any]
        precondition((metadataRoot["apps"] as! [[String: Any]]).isEmpty)
        do {
            _ = try XSignRESTSource.normalize([["name":"Broken generic schema"]])
            preconditionFailure("An unknown generic schema erased a source cache")
        } catch {}
        precondition(XSignRESTSource.PageRange("0-249/400")?.total == 400)
        precondition(XSignRESTSource.PageRange("0-249/100") == nil)
        let dashboard=try JSONDecoder().decode(XSignDashboardConfig.self,from:Data(#"{"schema_version":2,"catalog_profile":"iosboom-public-v1","sources":[{"id":"test","name":"Custom","url":"https://custom.example/repo.json"}],"sections":[]}"#.utf8))
        let releases = try JSONDecoder().decode(XSignDashboardConfig.self, from: Data(#"""
        {"update":{"enabled":true,"latest_version":"1.0"},"bundle_updates":{
          "com.owner.new":{"enabled":true,"latest_version":"2.0","bundle_identifier":"com.owner.new","app_name":"Owner XSign"},
          "com.owner.wrong":{"enabled":true,"latest_version":"9.0","bundle_identifier":"com.owner.new"}
        }}
        """#.utf8))
        precondition(releases.update(for: "com.ipablack.xsign")?.latest_version == "1.0")
        precondition(releases.update(for: "COM.Owner.New")?.app_name == "Owner XSign")
        precondition(releases.update(for: "com.owner.wrong") == nil)
        precondition(releases.update(for: "com.owner.other") == nil)
        let oldAppsLayout = try JSONDecoder().decode(XSignDashboardConfig.self, from: Data(#"""
        {"sections":[{"id":"apps-list","title":"التطبيقات","page":"apps","kind":"apps"},
                     {"id":"games-featured","title":"مختارات الألعاب","page":"games","kind":"featured"}]}
        """#.utf8))
        precondition(oldAppsLayout.sections(for: "apps").map(\.kind) == ["featured", "apps"])
        let hiddenHero = try JSONDecoder().decode(XSignDashboardConfig.self, from: Data(#"""
        {"sections":[{"id":"apps-featured","title":"مختارات التطبيقات","page":"apps","kind":"featured","enabled":false},
                     {"id":"apps-list","title":"التطبيقات","page":"apps","kind":"apps"}]}
        """#.utf8))
        precondition(hiddenHero.sections(for: "apps").map(\.kind) == ["apps"])
        let requiredJSON = #"{"update":{"enabled":true,"required":true,"required_policy":"approved","latest_version":"1.0","build_version":"34","ipa_url":"https://example.test/Xsign.ipa","sha256":""}}"#
        let required = try JSONDecoder().decode(XSignDashboardConfig.self, from: Data(requiredJSON.utf8))
        let primary = required.update(for: "Xsign")!
        precondition(!primary.installable)
        precondition(primary.needsUpdate(version: "1.0", build: "33", origin: nil, request: nil))
        precondition(!primary.needsUpdate(version: "1.0", build: "34", origin: nil, request: nil))
        precondition(required.update(for: "com.owner.other") == nil)
        let disabled = try JSONDecoder().decode(XSignOwnerUpdate.self, from: Data(
            #"{"enabled":false,"required":true,"required_policy":"approved","latest_version":"1.0","build_version":"34"}"#.utf8))
        precondition(!disabled.needsUpdate(version: "1.0", build: "33", origin: nil, request: nil))
        let projection = try JSONDecoder().decode(XSignDashboardConfig.self, from: Data(#"""
        {"update":{"enabled":true,"required":true,"required_policy":"approved","bundle_identifier":"xsign","latest_version":"1.0","build_version":"34"},
         "bundle_updates":{"xsign":{"enabled":true,"required":true,"required_policy":"approved","bundle_identifier":"xsign","latest_version":"1.0","build_version":"34"},
         "com.ipablack.xsign":{"enabled":false,"latest_version":"9.0"}}}
        """#.utf8))
        precondition(projection.update(for: "Xsign")!.needsUpdate(version: "1.0", build: "33", origin: nil, request: nil))
        precondition(!projection.update(for: "com.ipablack.xsign")!.needsUpdate(version: "1.0", build: "33", origin: nil, request: nil))
        precondition(XSignDashboardSources.apply(dashboard))
        precondition(SourceSelection.resolvedManagedSources(nil).count==2)
        let empty=try JSONDecoder().decode(XSignDashboardConfig.self,from:Data(#"{"schema_version":2,"sources":[]}"#.utf8))
        precondition(XSignDashboardSources.apply(empty))
        precondition(SourceSelection.resolvedManagedSources(nil).map(\.id) == ["xsign.core.owned"])
        let selected = URL(string: "https://sources.example.test/one")!
        let supplied = try JSONDecoder().decode(XSignDashboardConfig.self, from: JSONSerialization.data(withJSONObject: [
            "schema_version": 2, "sources": [
                ["id": XSignCatalogueEndpoint.primaryID, "name": "Primary", "url": selected.absoluteString],
                ["id": XSignCatalogueEndpoint.ownerID, "name": "Owner", "url": "https://private.example.test/repo.json"]
            ]
        ]))
        precondition(XSignDashboardSources.apply(supplied))
        precondition(SourceSelection.resolvedManagedSources(nil).map(\.url) == [owner.absoluteString, selected.absoluteString])
        precondition(!XSignDashboardSources.apply(supplied))
        precondition(XSignDashboardSources.apply(empty))
        precondition(SourceSelection.resolvedManagedSources(nil).map(\.id) == [XSignCatalogueEndpoint.ownerID])
        precondition(!XSignDashboardSources.isUserSource(owner))
        precondition(!XSignDashboardSources.isUserSource(selected))
        XSignDashboardSources.registerUser(selected)
        precondition(XSignDashboardSources.isUserSource(selected))
        precondition(XSignTodaySourcePolicy.allows(id: nil, url: owner))
        precondition(XSignTodaySourcePolicy.allows(id: XSignCatalogueEndpoint.primaryID, url: selected))
        precondition(!XSignTodaySourcePolicy.allows(id: nil, url: selected))
        let oldExperience = try JSONDecoder().decode(XSignDashboardConfig.self, from: Data(#"{"allow_user_sources":false}"#.utf8))
        let newExperience = try JSONDecoder().decode(XSignDashboardConfig.self, from: Data(#"{"experience_version":2,"allow_user_sources":false}"#.utf8))
        precondition(oldExperience.userSourcesEnabled && !newExperience.userSourcesEnabled)
        precondition(XSignVersion.older("1.9",than:"1.10"))
        precondition(!XSignVersion.valid("1.bad"))
        let legacyToday = Data(#"{"experience_version":2,"sections":[{"id":"news","title":"News","page":"today","kind":"news"}]}"#.utf8)
        let restored = try JSONDecoder().decode(XSignDashboardConfig.self, from: legacyToday)
        precondition(restored.sections(for: "today").map(\.id) == ["news", "today-featured", "today-apps"])
        let intentional = Data(#"{"experience_version":3,"sections":[{"id":"news","title":"News","page":"today","kind":"news"}]}"#.utf8)
        let hidden = try JSONDecoder().decode(XSignDashboardConfig.self, from: intentional)
        precondition(hidden.sections(for: "today").map(\.id) == ["news"])
        let repeated = try JSONDecoder().decode(XSignDashboardConfig.self, from: Data(#"{"sections":[{"id":"first","title":"Categories","page":"games","kind":"categories"},{"id":"second","title":"Categories again","page":"games","kind":"categories"}]}"#.utf8))
        precondition(repeated.sections(for: "games").map(\.id) == ["first"])
        let alias = URL(string: "https://github.com/Fixture/Repo/blob/main/catalog.json?raw=true")!
        precondition(XSignDashboardSources.sourceKey(alias) == "https://raw.githubusercontent.com/Fixture/Repo/main/catalog.json")
        XSignDashboardSources.setHidden(true, url: owner.absoluteString)
        precondition(!XSignDashboardSources.isHidden(owner.absoluteString))
        precondition(XSignDashboardSources.apply(dashboard))
        XSignDashboardSources.setHidden(true, url: "https://custom.example/repo.json")
        precondition(SourceSelection.resolvedManagedSources(nil).map(\.id) == ["xsign.core.owned", "test"])
        XSignDashboardSources.setHidden(false, url: "https://custom.example/repo.json")
        precondition(SourceSelection.resolvedManagedSources(nil).map(\.id) == ["xsign.core.owned", "test"])
        precondition(XSignNetworkPolicy.hasEnabledProxy(in: ["ProxyAutoDiscoveryEnable": 1]))
        precondition(!XSignNetworkPolicy.hasEnabledProxy(in: ["HTTPProxy": "saved.example", "HTTPEnable": 0]))
        precondition(XSignNetworkPolicy.isTunnelInterface("utun4"))
        precondition(!XSignNetworkPolicy.isTunnelInterface("lo0"))
        precondition(!XSignNetworkPolicy.isTunnelInterface("mytun4"))
        precondition(XSignNetworkPolicy.isActiveTunnelInterface("utun4", activeInterfaces: ["utun4", "en0"]))
        precondition(!XSignNetworkPolicy.isActiveTunnelInterface("utun4", activeInterfaces: ["en0"]))
        precondition(!XSignNetworkPolicy.isActiveTunnelInterface("en0", activeInterfaces: ["en0"]))
        precondition(XSignNetworkPolicy.hasUsableTunnelAddress([10, 8, 0, 2]))
        precondition(!XSignNetworkPolicy.hasUsableTunnelAddress([169, 254, 0, 1]))
        precondition(!XSignNetworkPolicy.hasUsableTunnelAddress([127, 0, 0, 1]))
        precondition(!XSignNetworkPolicy.hasUsableTunnelAddress([0, 0, 0, 0]))
        let ipv6Suffix = Array(repeating: UInt8(0), count: 13) + [2]
        precondition(XSignNetworkPolicy.hasUsableTunnelAddress([0xfd, 0] + ipv6Suffix))
        precondition(!XSignNetworkPolicy.hasUsableTunnelAddress([0xfe, 0x80] + ipv6Suffix))
        precondition(!XSignNetworkPolicy.hasUsableTunnelAddress(Array(repeating: 0, count: 15) + [1]))
        precondition(XSignNetworkPolicy.shouldBlock(enabled: true, detected: true))
        precondition(XSignNetworkPolicy.shouldBlock(enabled: nil, detected: true))
        precondition(!XSignNetworkPolicy.shouldBlock(enabled: false, detected: true))
        let generic=Data(#"{"data":{"items":[{"title":"Example","bundle_id":"com.example.app","ipa":"https://example.test/a.ipa","logo":"https://example.test/i.png"}]},"icon":"https://example.test/source.png"}"#.utf8)
        let genericData=try XSignSourceAdapter.normalize(generic,from:URL(string:"https://example.test/repo.json")!)
        let genericRoot=try JSONSerialization.jsonObject(with:genericData) as! [String:Any]
        precondition((genericRoot["apps"] as! [[String:Any]]).count==1)
        precondition(genericRoot["iconURL"] as? String=="https://example.test/source.png")
        do { _=try XSignSourceAdapter.normalize(Data("<html>no</html>".utf8),from:URL(string:"https://example.test/repo.json")!);preconditionFailure("HTML accepted") } catch {}
        let metadataCatalogue = Data(#"{"name":"Public catalogue","apps":[{"name":"Metadata only","bundleIdentifier":"com.example.metadata","downloadURL":"","versions":[{"version":"2.0","downloadURL":"","size":12}]},{"name":"Unsafe","downloadURL":"chrome-extension://file/app.ipa"},{"name":"Secure","downloadURL":"https://example.test/current.ipa","versions":[{"version":"1.0","downloadURL":"https://example.test/previous.ipa"}]}]}"#.utf8)
        let safeCatalogue = try XSignSourceAdapter.normalize(metadataCatalogue,from:URL(string:"https://example.test/catalogue")!)
        let safeRoot = try JSONSerialization.jsonObject(with:safeCatalogue) as! [String:Any]
        let safeApps = safeRoot["apps"] as! [[String:Any]]
        precondition(safeApps.count == 3 && safeApps[0]["downloadURL"] == nil && safeApps[1]["downloadURL"] == nil)
        precondition((safeApps[0]["versions"] as! [[String:Any]])[0]["downloadURL"] == nil)
        precondition((safeApps[0]["versions"] as! [[String:Any]])[0]["version"] as? String == "2.0")
        precondition(safeApps[2]["downloadURL"] as? String == "https://example.test/current.ipa")
        precondition((safeApps[2]["versions"] as! [[String:Any]])[0]["downloadURL"] as? String == "https://example.test/previous.ipa")
        let typedGame = Data(#"{"apps":[{"name":"Example","type":2,"downloadURL":"https://example.test/game.ipa"}]}"#.utf8)
        let typedURL = URL(string: "https://sources.example.test/typed")!
        let typedSource = XSignManagedSource(id: "typed", name: "Typed", url: typedURL.absoluteString, numeric_types: true)
        let gameData = try XSignSourceAdapter.normalize(typedGame, from: typedURL, configuration: typedSource)
        let gameRoot = try JSONSerialization.jsonObject(with:gameData) as! [String:Any]
        precondition((gameRoot["apps"] as! [[String:Any]])[0]["category"] as? String == "games")
        let typedCatalogue = Data(#"{"apps":[{"name":"Game","type":2,"category":7013,"downloadURL":"https://example.test/game.ipa"},{"name":"Tool","type":2,"is_game":"false","downloadURL":"https://example.test/tool.ipa"}]}"#.utf8)
        let typedData = try XSignSourceAdapter.normalize(typedCatalogue, from: typedURL, configuration: typedSource)
        let typed = try JSONDecoder().decode(ASRepository.self, from: typedData)
        precondition(typed.apps[0].category == "7013" && typed.apps[0].isGame == true && typed.apps[1].isGame == false)
        try checkCatalogueCategories()
        try await checkManagedCatalogueCache()
        let existingLayout = try JSONDecoder().decode(XSignDashboardConfig.self, from: Data(#"{"sections":[{"id":"apps-sources","title":"مصادري","page":"apps","kind":"sources"},{"id":"games-list","title":"الألعاب","page":"games","kind":"apps"}]}"#.utf8))
        precondition(existingLayout.sections(for: "apps").isEmpty)
        precondition(existingLayout.sections(for: "games").map(\.id) == ["games-list"])
        var pipeline = XSignBoundedPipeline<String, Int>()
        precondition(pipeline.enqueue(key: "first", job: "one") && pipeline.enqueue(key: "later", job: "two"))
        precondition(pipeline.takeDownload()?.key == "first")
        precondition(pipeline.completeDownload(key: "first", file: 1))
        precondition(pipeline.cancelWaiting(key: "first") == 1)
        precondition(pipeline.cancelWaiting(key: "later") == nil && pipeline.pendingCount == 0)
        precondition(pipeline.enqueue(key: "later", job: "retry"))
        precondition(pipeline.takeDownload()?.value == "retry")
        print("PASS: no-code catalogue transport, Studio sources, REST schema and cancelled download queue")
    }

    static func checkCatalogueCategories() throws {
        func decode(_ json: String) throws -> ASRepository {
            try JSONDecoder().decode(ASRepository.self, from: Data(json.utf8))
        }
        let owned = try decode(#"""
        {
          "name":"IPA BLACK",
          "categories":[{"id":"utility","name":"أدوات","isGame":false},{"id":"owner-racing","name":"سباقات","isGame":true,"aliases":["7013"]}],
          "apps":[
            {"name":"Utility","bundleIdentifier":"test.utility","category":"Utility"},
            {"name":"Owner racer","bundleIdentifier":"test.owner-racer","category":7013},
            {"name":"Unclassified","bundleIdentifier":"test.unclassified"},
            {"name":"Old variant","bundleIdentifier":"test.shared","version":"1.0","downloadURL":"https://example.test/old.ipa"},
            {"name":"New variant","bundleIdentifier":"TEST.SHARED","version":"2.0","downloadURL":"https://example.test/new.ipa"}
          ],
          "news":[
            {"identifier":"races","title":"سباقات","appID":"test.owner-racer","badge":"متوفر الآن","imageURL":"https://example.test/cover.png"},
            {"identifier":"new","title":"نسخة من IPA BLACK","appID":"test.shared||New variant"}
          ]
        }
        """#)
        let external = try decode(#"""
        {
          "name":"IPA SOON",
          "categories":[null,{},{"value":12,"label":"أدوات المكتب","is_game":"false"},{"slug":"mixed","title":"عام"}],
          "gameCategories":[{"value":"puzzle","label":"ألغاز"}],
          "apps":[
            {"name":"Number utility","bundleIdentifier":"test.number","categories":[{"id":12}, "secondary"]},
            {"name":"External puzzle","bundleIdentifier":"test.puzzle","category_id":"PUZZLE"},
            {"name":"External racer","bundleIdentifier":"test.racer","primaryGenreId":7013,"headerURL":"https://example.test/racer.jpg"},
            {"name":"New studio match","bundleIdentifier":"test.studio-match","category":"board-family"},
            {"name":"Shared game","bundleIdentifier":"test.shared","is_game":"1","versions":[
                {"version":"1.5","downloadURL":"https://example.test/other.ipa"},
                {"version":"1.0","downloadURL":"https://example.test/old.ipa"}]}
          ],
          "games":[{"name":"Flat game","bundleIdentifier":"test.flat","isGame":false}],
          "news":[
            null, {"caption":"Missing title"},
            {"identifier":"","title":"نسخة جديدة","appID":"test.shared||Shared game","date":"","url":"","imageURL":"https://example.test/news.png","badgeText":"متوفر الآن","showBadge":true},
            {"title":"أدوات المكتب","appID":"test.number.1||Number utility","imageURL":[],"badgeText":"مخفية","showBadge":false}
          ]
        }
        """#)
        let dictionary = try decode(#"{"apps":[],"categories":{"old":"موجود"},"gameCategories":{"race":"سباق"}}"#)
        precondition(dictionary.categories?.count == 2 && dictionary.categories?.last?.isGame == true)
        precondition(external.categories?.count == 3)
        precondition(external.apps[0].categoryReferences == ["12", "secondary"])
        precondition(external.apps[2].artworkURL?.path == "/racer.jpg")
        let studio = [
            ASRepository.CatalogCategory(id: "studio-board", name: "ألعاب الطاولة", isGame: true, aliases: ["Board Family"]),
            ASRepository.CatalogCategory(id: "owner-racing", name: "سباقات", isGame: true, aliases: ["7013"]),
            ASRepository.CatalogCategory(id: "utility", name: "أدوات المكتب", isGame: false, aliases: ["12"]),
            ASRepository.CatalogCategory(id: "empty", name: "تصنيف جديد", isGame: false)
        ]
        let sources: [(URL?, String?, ASRepository)] = [
            (XSignCatalogueEndpoint.ownerURL, "xsign.core.owned", owned),
            (URL(string: "https://sources.example.test/primary"), "xsign.core.primary", external)
        ]
        let manyApps: [[String: Any]] = (0..<72).map { index in
            ["name": "Fixture \(index)", "bundleIdentifier": "test.launch.\(index)", "isGame": index % 2 == 0]
        }
        let launchRepo = try JSONDecoder().decode(ASRepository.self,
            from: JSONSerialization.data(withJSONObject: ["apps": manyApps]))
        let launchSource = [(sources[0].0, sources[0].1, launchRepo)]
        let initial = XSignTestCatalogue.buildSnapshot(snapshot: launchSource, studioCategories: nil, launchPreview: true)!
        precondition(initial.allCombinedItems.count == 24)
        precondition(initial.pureAppsOnly.count == 12 && initial.pureGamesOnly.count == 12)
        let full = XSignTestCatalogue.buildSnapshot(snapshot: launchSource, studioCategories: nil)!
        precondition(full.allCombinedItems.count == 72)
        let state = XSignTestCatalogue.buildSnapshot(snapshot: sources, studioCategories: studio)!
        precondition(state.todayItems.prefix(4).map { $0.app.currentName } ==
            ["Utility", "Number utility", "Owner racer", "External puzzle"])
        let featured = state.pureAppsOnly.first { $0.app.id == "test.utility" } ?? state.pureAppsOnly[0]
        let selectedID = featured.sourceCatalogIDs.first!
        let layout = XSignStoreLayout.make(
            sections: [.init(id: "all", title: "Apps", page: "apps", kind: "apps"),
                       .init(id: "picks", title: "Picks", page: "apps", kind: "featured", app_ids: [selectedID])],
            page: "apps", items: state.pureAppsOnly, news: [], featuredIDs: [], todayFeatured: [:],
            showsDownload: true, hasCompleteList: true, hidesGeneralList: false)!
        let pickedIDs = Set(layout.shelves[1].entries.map(\.id))
        precondition(pickedIDs.contains(featured.id))
        precondition(pickedIDs.isDisjoint(with: layout.shelves[0].entries.map(\.id)))
        precondition(layout.shelves[0].completeItems?.count == state.pureAppsOnly.count)
        let paged = XSignStoreLayout.make(
            sections: [.init(id: "all", title: "Apps", page: "apps", kind: "apps", limit: 1)],
            page: "apps", items: state.pureAppsOnly, news: [], featuredIDs: [], todayFeatured: [:],
            showsDownload: true, hasCompleteList: true, hidesGeneralList: false)!
        precondition(!paged.remaining.isEmpty)
        precondition(paged.remaining.map(\.id) == state.pureAppsOnly.dropFirst().map(\.id))
        let hidden = XSignStoreLayout.make(sections: [], page: "apps", items: state.pureAppsOnly,
            news: [], featuredIDs: [], todayFeatured: [:], showsDownload: true,
            hasCompleteList: true, hidesGeneralList: true)!
        precondition(hidden.remaining.isEmpty)

        let third = (URL(string: "https://sources.example.test/other"), "third",
                     try decode(#"{"apps":[{"name":"Third source","bundleIdentifier":"test.third"}]}"#))
        let withThird = XSignTestCatalogue.buildSnapshot(snapshot: sources + [third], studioCategories: studio)!
        precondition(withThird.allCombinedItems.contains { $0.app.id == "test.third" })
        precondition(!withThird.todayItems.contains { $0.app.id == "test.third" })
        let selectedThird = XSignTestCatalogue.buildSnapshot(snapshot: sources + [third], studioCategories: studio,
            todaySourceIDs: ["third"])!
        precondition(selectedThird.todayItems.map { $0.app.id } == ["test.third"])
        precondition(selectedThird.todayNews.isEmpty)
        let explicitEmpty = XSignTestCatalogue.buildSnapshot(snapshot: sources + [third], studioCategories: studio,
            todaySourceIDs: [])!
        precondition(explicitEmpty.todayItems.isEmpty && explicitEmpty.todayNews.isEmpty)
        precondition(!explicitEmpty.ipablackEditorialNews.isEmpty)
        let removed = XSignTestCatalogue.buildSnapshot(snapshot: [sources[0], third], studioCategories: studio,
            todaySourceIDs: ["xsign.core.primary", "third"])!
        precondition(removed.todayItems.map { $0.app.id } == ["test.third"])

        let sameName = try decode(#"""
        {"categories":[{"id":"editors","name":"مختارات","icon_svg":"<svg/>"},{"id":"readers","name":"مختارات"}],
         "apps":[{"name":"Text editor","category":"editors"},{"name":"Book reader","category":"readers"},
                 {"name":"Other tools","category":"other-tools"}]}
        """#)
        let divided = XSignTestCatalogue.buildSnapshot(snapshot: [(XSignCatalogueEndpoint.ownerURL, "xsign.core.owned", sameName)],
            studioCategories: nil)!
        let groups = Dictionary(uniqueKeysWithValues: divided.appCategories.map { ($0.id, $0.items.map { $0.app.currentName }) })
        precondition(groups["category:editors"] == ["Text editor", "Book reader"])
        precondition(groups["category:readers"] == nil && divided.appCategories.first?.keys.contains("readers") == true)
        precondition(groups["category:other-tools"] == ["Other tools"])
        precondition(divided.appCategories.first?.iconSVG == "<svg/>")
        let namedTools = try decode(#"""
        {"categories":[{"id":"12","name":"Utilities"},{"id":"all","name":"الكل"}],
         "apps":[{"name":"Toolbox","category":"12"}]}
        """#)
        let namedMedia = try decode(#"""
        {"categories":[{"id":"12","name":"Photo & Video"},{"id":"utility","name":"أدوات"}],
         "apps":[{"name":"Video editor","category":"12"},{"name":"Converter","category":"utility"}]}
        """#)
        let mixed = XSignTestCatalogue.buildSnapshot(snapshot: [(sources[1].0, sources[1].1, namedTools),
            (third.0, third.1, namedMedia)], studioCategories: nil)!
        precondition(mixed.appCategories.count == 2)
        precondition(mixed.appCategories.first { $0.title == "أدوات" }?.items.map { $0.app.currentName } == ["Toolbox", "Converter"])
        precondition(mixed.appCategories.first { $0.title == "صور وفيديو" }?.items.map { $0.app.currentName } == ["Video editor"])
        let overlapping = XSignTestCatalogue.buildSnapshot(snapshot: [(sources[0].0, sources[0].1, namedTools),
            (sources[1].0, sources[1].1, namedMedia)], studioCategories: nil)!
        precondition(overlapping.appCategories.first { $0.title == "صور وفيديو" }?.items.map { $0.app.currentName } == ["Video editor"])
        let appHero = XSignStoreSection(id: "apps-featured", title: "مختارات", page: "apps", kind: "featured", limit: 60)
        let gameHero = XSignStoreSection(id: "games-featured", title: "مختارات", page: "games", kind: "featured", limit: 60)
        precondition(appHero.previewLimit == 18 && appHero.previewLimit == gameHero.previewLimit)
        var todayList = XSignStoreSection(id: "today-apps", title: "اليوم", page: "today", kind: "apps")
        precondition(todayList.continuesTodayFeed)
        todayList.continuous = false
        precondition(!todayList.continuesTodayFeed)
        todayList.continuous = true
        todayList.category_id = "tools"
        precondition(!todayList.continuesTodayFeed)
        let imported = try decode(#"""
        {"categories":[{"id":"games","name":"games"},{"id":"social","name":"Social"}],"apps":[
            {"name":"Sudoku","bundleIdentifier":"test.sudoku","category":"games"},
            {"name":"Chat","bundleIdentifier":"test.chat","category":"social"}
        ]}
        """#)
        let importedState = XSignTestCatalogue.buildSnapshot(snapshot: [(third.0, third.1, imported)], studioCategories: [])!
        precondition(importedState.gameCategories.first?.title == "ألعاب ألغاز")
        precondition(importedState.gameCategories.first?.items.map { $0.app.currentName } == ["Sudoku"])
        precondition(importedState.appCategories.first?.title == "التواصل الاجتماعي")
        precondition(importedState.appCategories.first?.items.map { $0.app.currentName } == ["Chat"])
        let allNames = Set(state.allCombinedItems.map { $0.app.currentName })
        let appNames = Set(state.pureAppsOnly.map { $0.app.currentName })
        let gameNames = Set(state.pureGamesOnly.map { $0.app.currentName })
        precondition(allNames.count == 9)
        precondition(appNames.isDisjoint(with: gameNames) && appNames.union(gameNames) == allNames)
        precondition(appNames == ["Utility", "Unclassified", "Number utility"])
        precondition(gameNames.contains("New studio match") && gameNames.contains("Flat game"))
        precondition(gameNames.contains("New variant") && !gameNames.contains("Old variant"))
        let shared = state.pureGamesOnly.first { $0.id == "bundle:test.shared" }!
        precondition(shared.sourceURLs.count == 2 && shared.catalogueVersions.map(\.version) == ["2.0", "1.5", "1.0"])
        precondition(state.todayItems.filter { $0.id == shared.id }.count == 1)
        let soonOnly = XSignTestCatalogue.buildSnapshot(snapshot: sources, studioCategories: studio,
            todaySourceIDs: ["xsign.core.primary"])!
        precondition(soonOnly.todayItems.first { $0.id == shared.id }?.catalogueVersions.map(\.version) == ["1.5", "1.0"])
        precondition(state.gameCategories.prefix(2).map(\.title) == ["ألعاب الطاولة", "سباقات"])
        precondition(Set(state.gameCategories[1].items.map { $0.app.currentName }) == ["Owner racer", "External racer"])
        precondition(state.appCategories.prefix(2).map(\.title) == ["أدوات المكتب", "تصنيف جديد"])
        precondition(state.appCategories[1].items.isEmpty)
        precondition(state.appCategories.filter { $0.title == "أدوات المكتب" }.count == 1)
        precondition(state.todayNews.first?.badge == "متوفر الآن" && state.todayNews.first?.associatedApp?.app.id == "test.owner-racer")
        precondition(external.news?.count == 2 && external.news?.first?.url == nil)
        precondition(Set(state.todayNews.map(\.id)).count == 4)
        precondition(state.todayNews[1].associatedApp?.app.currentName == "New variant")
        precondition(state.todayNews[2].associatedApp?.id == shared.id && state.todayNews[2].badge == "متوفر الآن")
        precondition(state.todayNews.last?.associatedApp?.app.id == "test.number" && state.todayNews.last?.badge == nil)
        let justOwner = XSignTestCatalogue.buildSnapshot(snapshot: [sources[0]], studioCategories: studio)!
        precondition(justOwner.pureAppsOnly.contains { $0.app.currentName == "New variant" })
        let reversed = XSignTestCatalogue.buildSnapshot(snapshot: sources, studioCategories: [studio[1], studio[0]] + studio.dropFirst(2))!
        precondition(reversed.gameCategories.prefix(2).map(\.title) == ["سباقات", "ألعاب الطاولة"])
        let curated = try decode(#"""
        {"categories":[{"id":"42","name":"Action Review"}],"apps":[
          {"name":"Move from games","bundleIdentifier":"test.move","isGame":true,"category":"owner-productivity"},
          {"name":"Unrelated utility","bundleIdentifier":"test.unrelated","isGame":false,"category":"other"},
          {"name":"Mapped by source label","bundleIdentifier":"test.bylabel","category":42},
          {"name":"Source id higher than alias","bundleIdentifier":"test.idwins","category":"tools-id"}
        ]}
        """#)
        let curatedStudio = [
            ASRepository.CatalogCategory(id: "owner-productivity", name: AppStore2026Category.productivity.rawValue, isGame: false),
            ASRepository.CatalogCategory(id: "editorial", name: "مختارات المالك", isGame: false, aliases: ["Action Review", "tools-id"]),
            ASRepository.CatalogCategory(id: "tools-id", name: "أدوات مستقلة", isGame: true)
        ]
        let curatedState = XSignTestCatalogue.buildSnapshot(snapshot: [(XSignCatalogueEndpoint.ownerURL, "xsign.core.owned", curated)], studioCategories: curatedStudio)!
        precondition(curatedState.pureGamesOnly.map { $0.app.currentName } == ["Source id higher than alias"])
        precondition(curatedState.appCategories.first?.items.map { $0.app.currentName } == ["Move from games"])
        precondition(curatedState.appCategories[1].items.first?.categoryTitle == "مختارات المالك")
        precondition(curatedState.appCategories[1].keys.contains("action-review"))
        let emptyStore = XSignTestCatalogue.buildSnapshot(snapshot: [], studioCategories: curatedStudio)!
        precondition(emptyStore.appCategories.count == 2 && emptyStore.gameCategories.count == 1)
        print("PASS: source category variants, Studio ordering and aliases, exclusive complete app/game lists, Today artwork and badges")
    }

    static func checkManagedCatalogueCache() async throws {
        let defaults = UserDefaults.standard
        let keys = [XSignDashboardSources.key, XSignDashboardSources.historyKey,
                    "xsign.managedCachePolicy.v1", "xsign.managedCatalogFiles.v1"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.removeObject(forKey: $0) }

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalogues = folder.appendingPathComponent("catalogues")
        let previews = folder.appendingPathComponent("previews")
        try fm.createDirectory(at: catalogues, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let io = XSignCatalogIO(directory: catalogues, previewDirectory: previews)
        let kept = XSignManagedSource(id: "stay", name: "Stay", url: "https://cache.test/stay.json")
        let removed = XSignManagedSource(id: "remove", name: "Remove", url: "https://cache.test/remove.json")

        func select(_ sources: [XSignManagedSource]) -> Bool {
            XSignDashboardSources.apply(.init(schema_version: 2, sources: sources, sections: nil, tab_order: nil,
                allow_user_sources: nil, signing_enabled: nil, update: nil))
        }
        precondition(select([kept]))
        let keptFiles = XSignCatalogIO.managedCacheFiles()
        let keptPreviews = SourceSelection.managedPreviewFiles
        precondition(select([kept, removed]))
        let selectedFiles = XSignCatalogIO.managedCacheFiles()
        let selectedPreviews = SourceSelection.managedPreviewFiles
        let discardedFile = selectedFiles.subtracting(keptFiles).first!
        let discardedPreview = selectedPreviews.subtracting(keptPreviews).first!
        let oldAccess = XSignCatalogIO.ManagedAccess(policyID: XSignDashboardSources.cachePolicyID)
        await io.reconcileManagedCache()

        let fixture = Data(#"{"apps":[{"name":"Cached app","bundleIdentifier":"cache.app","version":"2.0"}]}"#.utf8)
        for name in selectedFiles {
            let url = catalogues.appendingPathComponent(name)
            try fixture.write(to: url)
            try Data("etag".utf8).write(to: url.appendingPathExtension("etag"))
        }
        for name in selectedPreviews { await io.storeLaunchPreview(fixture, name: name, managed: oldAccess) }
        let personal = catalogues.appendingPathComponent(String(repeating: "a", count: 64) + ".json")
        try fixture.write(to: personal)
        let cached = await io.cached(removed.safeURL!, managed: oldAccess)
        precondition(cached?.repository.apps.first?.currentVersion == "2.0")
        precondition(fm.fileExists(atPath: previews.appendingPathComponent(discardedPreview).path))

        precondition(select([kept]))
        await io.reconcileManagedCache()
        let obsolete = catalogues.appendingPathComponent(discardedFile)
        precondition(!fm.fileExists(atPath: obsolete.path))
        precondition(!fm.fileExists(atPath: obsolete.appendingPathExtension("etag").path))
        precondition(!fm.fileExists(atPath: previews.appendingPathComponent(discardedPreview).path))
        precondition(fm.fileExists(atPath: personal.path))
        let remaining = await io.cached(kept.safeURL!)
        precondition(remaining?.repository.apps.count == 1)

        precondition(select([kept, removed]))
        precondition(!oldAccess.isCurrent)
        await io.storeLaunchPreview(fixture, name: discardedPreview, managed: oldAccess)
        precondition(!fm.fileExists(atPath: previews.appendingPathComponent(discardedPreview).path))
        do {
            _ = try await io.fetch(removed.safeURL!, managed: oldAccess)
            preconditionFailure("A request from the previous selection must not fetch or write again")
        } catch is CancellationError {}
        print("PASS: managed cache loads without networking, prunes catalogue data, validators and previews, and rejects stale requests after re-add")
    }
}
