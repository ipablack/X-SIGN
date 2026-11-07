import Foundation

@main
struct ApprovedSourceChecks {
    static func main() throws {
        let policyKeys=[XSignDashboardSources.key,XSignDashboardSources.historyKey,XSignDashboardSources.userKey,XSignDashboardSources.profileKey]
        let savedPolicy=policyKeys.map { UserDefaults.standard.object(forKey:$0) }
        policyKeys.forEach { UserDefaults.standard.removeObject(forKey:$0) }
        defer { for (key,value) in zip(policyKeys,savedPolicy) {
            if let value { UserDefaults.standard.set(value,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) }
        } }
        let key = ProtectedSourcesVault.ownedURLKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        precondition(ProtectedSourcesVault.coreURLs == [ProtectedSourcesVault.defaultOwnedURLString, ProtectedSourcesVault.primaryURLString, ProtectedSourcesVault.secondaryURLString] + XSignDashboardSources.iosboomSources.filter { $0.enabled != false }.map(\.url))
        precondition(!ProtectedSourcesVault.isRetiredSource(URL(string: ProtectedSourcesVault.primaryURLString)))
        precondition(!ProtectedSourcesVault.isRetiredSource(URL(string: ProtectedSourcesVault.secondaryURLString)))
        precondition(!ProtectedSourcesVault.isRetiredSource(URL(string: ProtectedSourcesVault.defaultOwnedGitHubRawURLString)))
        precondition(XSignCatalogIO.canonicalURL(URL(string: ProtectedSourcesVault.defaultOwnedGitHubRawURLString)!).absoluteString == ProtectedSourcesVault.defaultOwnedURLString)
        precondition(ProtectedSourcesVault.validOwnedURL(ProtectedSourcesVault.defaultOwnedGitHubRawURLString)?.absoluteString == ProtectedSourcesVault.defaultOwnedURLString)
        for value in ProtectedSourcesVault.legacyURLs {
            precondition(ProtectedSourcesVault.isRetiredSource(URL(string: value)))
            precondition(ProtectedSourcesVault.validOwnedURL(value) == nil)
        }
        let candidate = "https://sources.example.test/repo.json"
        precondition(!ProtectedSourcesVault.isRetiredSource(URL(string: candidate), identifier: "xsign.core.owned"))
        precondition(ProtectedSourcesVault.validOwnedURL("http://sources.example.test/repo.json") == nil)
        precondition(ProtectedSourcesVault.validOwnedURL("https://user:password@sources.example.test/repo.json") == nil)
        precondition(ProtectedSourcesVault.validOwnedURL(XSignRESTSource.primaryURL) == nil)
        let old = [XSignCoreSourceItem(name: "Old", id: "xsign.core.ipablack", url: ProtectedSourcesVault.legacyURLs[0])]
        precondition(SourceSelection.resolvedManagedSources(old).count == 6)
        let configured = old + [XSignCoreSourceItem(name: "IPA BLACK", id: "xsign.core.owned", url: candidate)]
        precondition(SourceSelection.resolvedManagedSources(configured).map(\.url) == ProtectedSourcesVault.coreURLs)
        UserDefaults.standard.set(candidate, forKey: key)
        precondition(ProtectedSourcesVault.coreURLs.count == 6)
        precondition(ProtectedSourcesVault.ownedURL?.absoluteString==ProtectedSourcesVault.defaultOwnedURLString)
        precondition(!ProtectedSourcesVault.isRetiredSource(URL(string: candidate)))
        precondition(!ProtectedSourcesVault.isRetiredSource(URL(string: "https://another.example.test/repo.json")))

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
        precondition(XSignDashboardSources.apply(dashboard))
        precondition(SourceSelection.resolvedManagedSources(nil).count==1)
        let empty=try JSONDecoder().decode(XSignDashboardConfig.self,from:Data(#"{"schema_version":2,"sources":[]}"#.utf8))
        precondition(XSignDashboardSources.apply(empty))
        precondition(SourceSelection.resolvedManagedSources(nil).isEmpty)
        let previous=try JSONDecoder().decode(XSignDashboardConfig.self,from:JSONSerialization.data(withJSONObject:["schema_version":2,"sources":[
            ["id":"xsign.core.primary","name":"Previous","url":XSignDashboardSources.priorPlusURL]
        ]]))
        precondition(XSignDashboardSources.apply(previous))
        precondition(SourceSelection.resolvedManagedSources(nil).map(\.url)==[ProtectedSourcesVault.primaryURLString,ProtectedSourcesVault.secondaryURLString] + XSignDashboardSources.iosboomSources.filter { $0.enabled != false }.map(\.url))
        precondition(!XSignDashboardSources.apply(previous), "Repeated legacy config must be stable")
        precondition(XSignDashboardSources.apply(empty))
        precondition(SourceSelection.resolvedManagedSources(nil).isEmpty, "Deleted sources were resurrected")
        let orderedConfig = try JSONDecoder().decode(XSignDashboardConfig.self,from:JSONSerialization.data(withJSONObject:["schema_version":2,"catalog_profile":"iosboom-public-v1","sources":[
            ["id":"plus","name":"Plus","url":XSignRESTSource.primaryURL],
            ["id":"owner","name":"IPA BLACK","url":ProtectedSourcesVault.defaultOwnedGitHubRawURLString]
        ]]))
        precondition(XSignDashboardSources.apply(orderedConfig))
        precondition(SourceSelection.resolvedManagedSources(nil).map(\.id)==["owner","plus"])
        let legacyURL=ProtectedSourcesVault.legacyURLs[0]
        let explicitLegacy=try JSONDecoder().decode(XSignDashboardConfig.self,from:JSONSerialization.data(withJSONObject:["schema_version":2,"catalog_profile":"iosboom-public-v1","sources":[["id":"chosen","name":"Explicit source","url":legacyURL]]]))
        precondition(XSignDashboardSources.apply(explicitLegacy))
        precondition(!ProtectedSourcesVault.isRetiredSource(URL(string:legacyURL)))
        precondition(XSignDashboardSources.apply(empty))
        precondition(SourceSelection.resolvedManagedSources(nil).isEmpty && ProtectedSourcesVault.isRetiredSource(URL(string:legacyURL)))
        precondition(!XSignDashboardSources.isUserSource(URL(string:"https://custom.example/repo.json")!))
        XSignDashboardSources.registerUser(URL(string:"https://custom.example/repo.json")!)
        precondition(XSignDashboardSources.isUserSource(URL(string:"https://custom.example/repo.json")!))
        XSignDashboardSources.registerUser(URL(string: legacyURL)!)
        precondition(!ProtectedSourcesVault.isRetiredSource(URL(string: legacyURL)))
        precondition(XSignTodaySourcePolicy.allows(URL(string: ProtectedSourcesVault.defaultOwnedGitHubRawURLString)))
        precondition(XSignTodaySourcePolicy.allows(URL(string: ProtectedSourcesVault.primaryURLString)))
        precondition(XSignTodaySourcePolicy.allows(URL(string: "https://vip.appiraq.com/source.php?action=getAll")))
        for other in [ProtectedSourcesVault.secondaryURLString, "https://sources.example/repo.json?name=IPA%20BLACK",
                      "https://appiraq.com/source.php?action=getAll&action=other", "https://appiraq.com/source.php?action=other",
                      "http://appiraq.com/source.php?action=getAll", "https://appiraq.com.evil.test/source.php?action=getAll"] {
            precondition(!XSignTodaySourcePolicy.allows(URL(string: other)))
        }
        let oldExperience = try JSONDecoder().decode(XSignDashboardConfig.self, from: Data(#"{"allow_user_sources":false}"#.utf8))
        let newExperience = try JSONDecoder().decode(XSignDashboardConfig.self, from: Data(#"{"experience_version":2,"allow_user_sources":false}"#.utf8))
        precondition(oldExperience.userSourcesEnabled && !newExperience.userSourcesEnabled)
        precondition(XSignVersion.older("1.9",than:"1.10"))
        precondition(!XSignVersion.valid("1.bad"))
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
        let gameData = try XSignSourceAdapter.normalize(typedGame,from:URL(string:"https://repository.apptesters.org/")!)
        let gameRoot = try JSONSerialization.jsonObject(with:gameData) as! [String:Any]
        precondition((gameRoot["apps"] as! [[String:Any]])[0]["category"] as? String == "games")
        print("PASS: only approved source slots, retired feeds rejected, observed REST schema normalized")
    }
}
