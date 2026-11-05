import Darwin
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String, file: StaticString = #filePath, line: UInt = #line) { description = "\(file):\(line): " + message }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String = "Check failed", file: StaticString = #filePath, line: UInt = #line) throws {
    guard condition() else { throw CheckFailure(message, file: file, line: line) }
}
@main
struct CatalogLoadingTests {
    @MainActor static func main() async {
        setbuf(stdout, nil); setbuf(stderr, nil)
        do { try await runChecks() }
        catch { fputs("TEST FAILURE: \(error)\n", stderr); exit(EXIT_FAILURE) }
    }
    @MainActor static func runChecks() async throws {
        let legacyLocks = try JSONDecoder().decode(XSignSecurityLocks.self, from: Data("{\"lock_bundle_rename\":true}".utf8))
        try require(legacyLocks.allowsAppMetadataEditing, "Legacy locks must not disable the new user editor")
        let locked = try JSONDecoder().decode(XSignSecurityLocks.self, from: Data("{\"allow_app_metadata_editing\":false}".utf8))
        try require(!locked.allowsAppMetadataEditing)
        let unlocked = try JSONDecoder().decode(XSignSecurityLocks.self, from: Data("{\"allow_app_metadata_editing\":true,\"lock_bundle_rename\":true}".utf8))
        try require(unlocked.allowsAppMetadataEditing)
        let originalInfo: [String: Any] = ["CFBundleName":"Original", "CFBundleDisplayName":"Original", "CFBundleIdentifier":"com.example.original", "CFBundleShortVersionString":"1.0", "CFBundleVersion":"10", "CFBundleExecutable":"OriginalBinary"]
        let editedInfo = NSMutableDictionary(dictionary: originalInfo)
        try XSignAppMetadata.apply(name: " تطبيق حسن ", bundleIdentifier: "com.example.personal", version: "2.3.4", to: editedInfo)
        let encodedInfo = try PropertyListSerialization.data(fromPropertyList: editedInfo, format: .xml, options: 0)
        let restoredInfo = try PropertyListSerialization.propertyList(from: encodedInfo, options: [], format: nil) as! [String: Any]
        try require(restoredInfo["CFBundleName"] as? String == "تطبيق حسن")
        try require(restoredInfo["CFBundleDisplayName"] as? String == "تطبيق حسن")
        try require(restoredInfo["CFBundleIdentifier"] as? String == "com.example.personal")
        try require(restoredInfo["CFBundleShortVersionString"] as? String == "2.3.4")
        try require(restoredInfo["CFBundleVersion"] as? String == "2.3.4")
        try require(restoredInfo["CFBundleExecutable"] as? String == "OriginalBinary")
        let invalidInfo = NSMutableDictionary(dictionary: originalInfo)
        var rejected = false
        do { try XSignAppMetadata.apply(name: "Changed", bundleIdentifier: "com.example.good", version: "not-a-version", to: invalidInfo) }
        catch { rejected = true }
        try require(rejected && invalidInfo.isEqual(to: originalInfo), "Invalid metadata was accepted or partly saved")
        try await checkStorageRecovery()

        for bundle in ["", "com..app", "com.example.*", "معرف.تطبيق", "com/example/app"] {
            try require(XSignAppMetadata.errorMessage(for: bundle, field: .bundleIdentifier) != nil)
        }
        print("PASS: user metadata permission, valid fields and actual Info.plist name/bundle/version round-trip without partial edits")

        let resources = URL(fileURLWithPath: "Feather/Resources", isDirectory: true)
        let data = try Data(contentsOf: resources.appendingPathComponent("XSignCatalogIPAOMTKLive.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let expected = (json["apps"] as! [[String: Any]]).count
        try require(expected > 100, "A preview must never replace the full bundled catalog")
        let record = try XSignCatalogIO.decode(data)
        try require(record.repository.apps.count == expected)
        print("PASS: the production decoder retains every bundled application (\(expected))")

        let full = URL(string: "https://raw.githubusercontent.com/ipa-black/X-SIGN/main/public/sources/ipaomtk.json")!
        let blob = URL(string: "https://github.com/ipa-black/X-SIGN/blob/main/public/sources/ipaomtk.json")!
        let refs = URL(string: "https://raw.githubusercontent.com/ipa-black/X-SIGN/refs/heads/main/public/sources/ipaomtk.json")!
        try require(XSignCatalogIO.canonicalURL(blob) == full)
        try require(XSignCatalogIO.canonicalURL(refs) == full)
        let signed = URL(string: "https://example.org/repo.json?signature=a%2Bb%3D&expires=99")!
        try require(XSignCatalogIO.canonicalURL(signed).absoluteString == signed.absoluteString)
        print("PASS: GitHub page/raw URLs share one identity; signed queries remain intact")

        // A legacy panel must retain the live providers and must not restore the retired source.
        let primaryURL = ProtectedSourcesVault.ipaBlackURLString
        let primaryOnly = [XSignCoreSourceItem(name: "IPA BLACK", id: "xsign.core.ipablack", url: primaryURL)]
        let resolved = AppStoreCacheManager.resolvedManagedSources(primaryOnly)
        try require(Set(resolved.map(\.id)) == ["xsign.core.ipablack", "xsign.core.soon.live", "xsign.core.ipaomtk.live", "xsign.core.reference"])
        let aliases = primaryOnly + [XSignCoreSourceItem(name: "alias", id: "alias.store", url: refs.absoluteString)]
        try require(AppStoreCacheManager.resolvedManagedSources(aliases).count == 4)
        let extraSource = XSignCoreSourceItem(name: "extra", id: "user.extra", url: "https://example.org/extra.json")
        try require(AppStoreCacheManager.resolvedManagedSources(primaryOnly + [extraSource]).count == 5)
        let retired = XSignCoreSourceItem(name: "IPA BLACK", id: "legacy.alias", url: ProtectedSourcesVault.storeAPIURLString)
        let migrated = AppStoreCacheManager.resolvedManagedSources(primaryOnly + [retired, extraSource])
        try require(migrated.count == 5 && !migrated.contains { $0.id == retired.id })
        for url in ["https://raw.githubusercontent.com/ipa-black/store-api/refs/heads/main/public/repo.json", "https://github.com/ipa-black/store-api/blob/main/public/repo.json"] {
            try require(ProtectedSourcesVault.isRetiredSource(URL(string: url)))
        }
        try require(ProtectedSourcesVault.isRetiredSource(nil, identifier: "xsign.core.storeapi"))
        try require(!ProtectedSourcesVault.isRetiredSource(URL(string: "https://example.org/ipa-black/store-api/repo.json")))
        let retiredVM = SourcesViewModel()
        let retiredSource = AltSource(sourceURL: URL(string: retired.url), identifier: retired.id)
        await retiredVM.fetchSources([retiredSource], refresh: true)
        try require(retiredVM.sources.isEmpty && retiredVM.isFinished)
        print("PASS: retired store-api URLs and old managed configuration cannot restore the source or start a download; unrelated sources remain")
        print("PASS: independent sources and reference snapshot survive legacy panel config; aliases deduplicate; custom sources remain")

        let primaryData = try Data(contentsOf: resources.appendingPathComponent("XSignCatalogIPABlack.json"))
        let panelRoot = try JSONDecoder().decode(XSignRemoteRoot.self, from: primaryData)
        try require(panelRoot.xsign_config != nil)
        let primary = try XSignCatalogIO.decode(primaryData)
        func pair(_ app: ASRepository.App) -> String {
            (app.id ?? "").lowercased() + "\u{1F}" + app.currentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let primaryPairs = Set(primary.repository.apps.map(pair))
        let liveAdditions = record.repository.apps.filter { !primaryPairs.contains(pair($0)) }.count
        let paired = await Task.detached {
            AppStoreCacheManager.buildSnapshot(snapshot: [
                (URL(string: primaryURL), "xsign.core.ipablack", primary.repository),
                (full, "xsign.core.ipaomtk.live", record.repository)
            ], previousItems: [])
        }.value!
        try require(paired.ipablackItems.count == primary.repository.apps.count)
        try require(paired.allCombinedItems.count == liveAdditions + primary.repository.apps.count)
        print("PASS: panel schema decodes; Today stays scoped to IPA BLACK while apps/games include both catalogs")

        let referenceURL = URL(string: ProtectedSourcesVault.referenceURLString)!
        let referenceData = try Data(contentsOf: resources.appendingPathComponent("XSignCatalogReference.json"))
        let referenceRepo = try XSignCatalogIO.decode(referenceData).repository
        let rawReference = try JSONSerialization.jsonObject(with: referenceData) as! [String: Any]
        try require(referenceRepo.apps.count == (rawReference["apps"] as! [[String: Any]]).count)
        try require(referenceRepo.apps.allSatisfy { $0.catalogID != nil })
        let existingPairs = Set((primary.repository.apps + record.repository.apps).map(pair))
        let existingDownloads = Set((primary.repository.apps + record.repository.apps).compactMap { $0.currentDownloadUrl?.absoluteString })
        let referenceAdditions = referenceRepo.apps.filter { !existingPairs.contains(pair($0)) && $0.currentDownloadUrl.map { !existingDownloads.contains($0.absoluteString) } != false }.count
        let combined = await Task.detached {
            AppStoreCacheManager.buildSnapshot(snapshot: [
                (URL(string: primaryURL), "xsign.core.ipablack", primary.repository),
                (full, "xsign.core.ipaomtk.live", record.repository),
                (referenceURL, "xsign.core.reference", referenceRepo)
            ], previousItems: [])
        }.value!
        try require(combined.allCombinedItems.count == paired.allCombinedItems.count + referenceAdditions)
        let variantsJSON: [String: Any] = ["name":"Fixture", "apps":[
            ["name":"Fixture Standard", "bundleIdentifier":"org.fixture.variant", "catalogID":"ref_standard", "version":"1.0", "downloadURL":"https://example.org/shared.ipa"],
            ["name":"Fixture Plus", "bundleIdentifier":"org.fixture.variant", "catalogID":"ref_plus", "version":"1.0", "downloadURL":"https://example.org/shared.ipa"]]]
        let variants = try XSignCatalogIO.decode(JSONSerialization.data(withJSONObject: variantsJSON)).repository
        let variantSnapshot = await Task.detached {
            AppStoreCacheManager.buildSnapshot(snapshot: [(referenceURL, "xsign.core.reference", variants)], previousItems: [])
        }.value!
        try require(variantSnapshot.allCombinedItems.count == 2)
        try require(Set(variantSnapshot.allCombinedItems.map { $0.app.id }) == ["org.fixture.variant"])
        try require(Set(variantSnapshot.allCombinedItems.map(\.id)).count == 2)
        print("PASS: every reference row decodes, real bundle IDs stay intact, mod variants survive and duplicate rows prefer existing sources; additional=\(referenceAdditions)")

        let isolatedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: isolatedDirectory) }
        let offlineIO = XSignCatalogIO(directory: isolatedDirectory, bundledResources: resources)
        let automatic = AppStoreCacheManager(catalogIO: offlineIO, bundledResources: resources)
        var automaticPublications = 0
        let observer = automatic.objectWillChange.sink { automaticPublications += 1 }
        await automatic.waitForInitialCatalog()
        try require(automatic.allCombinedItems.count == combined.allCombinedItems.count)
        try require(automatic.catalogRevision > 0 && automaticPublications > 0)
        observer.cancel()
        print("PASS: full catalogs publish automatically after construction, without pull-to-refresh or any network request")

        try require(XSignSearchDocument.normalize("وَاتـسَاب") == "واتساب")
        try require(XSignSearchDocument.normalize("Ｃａｆé ++") == "cafe")
        let insta = XSignSearchDocument(name: "Instagram", bundleID: "com.instagram.app", aliasGroups: AppStoreBilingualEngine.preNormalizedSynonymGroups)
        try require(insta.score(for: "انست") != nil)
        try require(insta.score(for: "x") == nil)
        try require(insta.score(for: "spotify") == nil)
        for name in ["Calculator Plus", "Rocket Game", "BH Notes", "DL Utility"] {
            let document = XSignSearchDocument(name: name, bundleID: "org.fixture.utility", aliasIndex: AppStoreBilingualEngine.preparedAliasIndex)
            try require(document.score(for: "انست") == nil, "Unrelated application activated brand aliases: " + name)
        }
        try require(XSignSearchDocument.normalize("إِنْسْتَغْرَام") == "انستغرام")
        try require(XSignSearchDocument.normalize("  APP++ TEST 42 ") == "app test 42")

        try require(XSignSearchDocument(name: "WhatsApp Watusi", bundleID: "net.whatsapp.watusi").score(for: "whats app") != nil)
        try require(XSignAppStoreReference.parse("https://apps.apple.com/us/app/telegram/id686449807?l=ar")?.id == "686449807")
        try require(XSignAppStoreReference.parse("https://itunes.apple.com/lookup?id=686449807")?.id == "686449807")
        for bad in ["https://apps.apple.com.evil.example/app/id123", "https://example.com/app/id123", "https://user@evil.example/id123", "file:///app/id123", "https://apps.apple.com/app/idnope"] {
            try require(XSignAppStoreReference.parse(bad) == nil)
        }
        print("PASS: Arabic/diacritics/width normalization, strict one-letter matching, non-cascading aliases and App Store URL validation")

        var sample = (json["apps"] as! [[String: Any]])[0]
        sample["name"] = "Fixture Utility"; sample["bundleIdentifier"] = "org.fixture.utility"
        sample["localizedDescription"] = ""; sample["subtitle"] = ""; sample["category"] = "forced_game"
        let categoryRoot: [String: Any] = ["name": "Fixture", "identifier": "fixture.category", "apps": [sample],
            "categories": [["id": "forced_game", "name": "ألعاب", "isGame": true]]]
        let categorized = try XSignCatalogIO.decode(JSONSerialization.data(withJSONObject: categoryRoot)).repository
        let categorySnapshot = await Task.detached {
            AppStoreCacheManager.buildSnapshot(snapshot: [(full, "fixture.category", categorized)], previousItems: [])
        }.value!
        try require(categorySnapshot.pureGamesOnly.count == 1)
        try require(categorySnapshot.itemsByCategory[.social]?.isEmpty == true)
        print("PASS: panel game categories affect the store; empty categories do not repeat the full catalog")

        let liveRoot: [String: Any] = ["name":"Soon live", "apps":[sample], "website":"", "news":[["identifier":"fixture.news", "title":"Update", "date":""], ["id":"malformed-ad", "title":"Optional ad"]],
            "categories":[["value":"forced_game", "label":"Games"], ["value":"forced_game", "label":"Games duplicate"]],
            "gameCategories":[["value":"forced_game", "label":"Games"]]]
        let liveRepository = try XSignCatalogIO.decode(JSONSerialization.data(withJSONObject: liveRoot)).repository
        try require(liveRepository.apps.count == 1 && liveRepository.categories?.count == 1)
        try require(liveRepository.news?.count == 1 && liveRepository.news?.first?.caption == "")
        try require(liveRepository.categories?.first?.isGame == true)
        let liveFirst = await Task.detached {
            AppStoreCacheManager.buildSnapshot(snapshot: [
                (URL(string: ProtectedSourcesVault.soonLiveURLString), "xsign.core.soon.live", liveRepository),
                (referenceURL, "xsign.core.reference", liveRepository)
            ], previousItems: [])
        }.value!
        try require(liveFirst.allCombinedItems.count == 1, "The bundled snapshot duplicated the live provider row")
        print("PASS: live provider value/label categories decode without duplication and current live rows override the older reference snapshot")

        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let began = Date()
        let snapshot = await Task.detached(priority: .userInitiated) {
            AppStoreCacheManager.buildSnapshot(snapshot: [(full, "xsign.core.ipaomtk.live", record.repository)], previousItems: [])
        }.value!
        heartbeat.cancel()
        try require(ticks > 0, "Catalog work blocked the main actor")
        try require(snapshot.allCombinedItems.count == expected)
        try require(snapshot.pureAppsOnly.count + snapshot.pureGamesOnly.count == expected)
        try require(!snapshot.pureGamesOnly.isEmpty && !snapshot.pureAppsOnly.isEmpty)
        print("PASS: full background indexing keeps all apps and games; main-actor ticks=\(ticks), indexing=\(Date().timeIntervalSince(began))s")

        var late = (json["apps"] as! [[String: Any]])[0]
        late["name"] = "Fixture Exact"; late["bundleIdentifier"] = "org.fixture.exact"
        late["category"] = "utilities"
        let lateRepo = try XSignCatalogIO.decode(JSONSerialization.data(withJSONObject: ["name": "Fixture", "apps": [late]])).repository
        let lateItem = AppStoreAppItem(id: "fixture-late", sourceURL: full, repository: lateRepo, app: lateRepo.apps[0])
        let input = snapshot.allCombinedItems + [lateItem]
        let ranked = await Task.detached { XSignSearchEngine.search(input, query: "Fixture Exact") }.value!
        try require(ranked.first?.id == "fixture-late", "A late exact name was hidden behind the old first-60 limit")
        let expectedLetter = input.filter { $0.searchDocument.score(for: "a") != nil }.count
        let letter = await Task.detached { XSignSearchEngine.search(input, query: "a") }.value!
        try require(letter.count == expectedLetter)
        let state = XSignSearchResults()
        state.update(query: "this query must be canceled", items: input)
        state.update(query: "Fixture Exact", items: input)
        for _ in 0..<500 where state.isSearching { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(!state.isSearching && state.visible.first?.id == "fixture-late")
        state.update(query: "a", items: input)
        for _ in 0..<500 where state.isSearching { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(state.total == expectedLetter && state.visible.count <= 40)
        if state.total > 40 { state.showMore(); try require(state.visible.count == min(80, state.total)) }
        state.update(query: "", items: input)
        try require(state.visible.isEmpty && !state.isSearching)
        print("PASS: whole-catalog ranking, bounded result rows, cancellation and immediate empty-query reset")

        let secondRecord = try XSignCatalogIO.decode(data)
        let second = await Task.detached {
            AppStoreCacheManager.buildSnapshot(snapshot: [(full, "xsign.core.ipaomtk.live", secondRecord.repository)], previousItems: snapshot.allCombinedItems)
        }.value!
        try require(snapshot.allCombinedItems.map(\.id) == second.allCombinedItems.map(\.id))
        try require(snapshot.allCombinedItems.map { $0.app.uuid } == second.allCombinedItems.map { $0.app.uuid })
        print("PASS: unchanged refresh preserves row identities instead of rebuilding every item")

        let previewData = AppStoreCacheManager.makeLaunchPreview(record.repository)!
        let preview = try XSignCatalogIO.decode(previewData).repository
        try require(preview.apps.count <= 24 && previewData.count <= 131_072)
        try require(preview.apps.contains { AppStore2026Category.strictlyClassify(app: $0).isGameCategory })
        try require(preview.apps.contains { !AppStore2026Category.strictlyClassify(app: $0).isGameCategory })
        print("PASS: bounded launch screen contains apps and games without decoding the full catalog on-main")

        let base = URL(string: ProcessInfo.processInfo.environment["XSIGN_FIXTURE_URL"]!)!
        try checkMachOHeaders()
        try await checkIPAProvider(base)
        let catalogURL = base.appendingPathComponent("catalog")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let io = XSignCatalogIO(directory: cache)
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let result = try await io.fetch(catalogURL)
                    return result.repository.apps.count
                }
            }
            var result: [Int] = []
            for try await count in group { result.append(count) }
            return result
        }
        try require(counts.count == 20 && counts.allSatisfy { $0 == expected })
        let (statsData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try JSONSerialization.jsonObject(with: statsData) as! [String: Any]
        try require(stats["body_requests"] as? Int == 1)
        try require(stats["catalog_requests"] as? Int == 1)
        print("PASS: twenty concurrent requests cause exactly one catalog download")

        let stored = await io.cached(catalogURL, includeBundled: false)!
        try require(stored.repository.apps.count == expected)
        let revalidated = try await io.fetch(catalogURL)
        try require(revalidated.fingerprint == stored.fingerprint)
        print("PASS: a 304 response uses the validated disk catalog")

        let vm = SourcesViewModel()
        let source = AltSource(sourceURL: catalogURL, identifier: "fixture.catalog")
        await vm.fetchSources([source], refresh: true)
        try require(vm.isFinished && vm.sources[source]?.apps.count == expected)
        _ = try await URLSession.shared.data(from: base.appendingPathComponent("break"))
        do { _ = try await io.fetch(catalogURL); throw CheckFailure("Invalid JSON was accepted") }
        catch { try require(error is XSignCatalogError) }
        let retained = await io.cached(catalogURL, includeBundled: false)!
        try require(retained.fingerprint == stored.fingerprint)
        await vm.fetchSources([source], refresh: true)
        try require(vm.isFinished && vm.errors[source] != nil)
        try require(vm.sources[source]?.apps.count == expected)
        print("PASS: a broken refresh ends loading, reports an error and preserves every cached app")

        let invalid = AltSource(sourceURL: base.appendingPathComponent("invalid"), identifier: "fixture.invalid")
        await vm.fetchSources([invalid], refresh: true)
        try require(vm.isFinished && vm.sources[invalid] == nil && vm.errors[invalid] != nil)
        print("PASS: invalid HTML cannot leave a source in an endless loading state")
        print("All catalog-loading integration checks passed.")
    }
}
