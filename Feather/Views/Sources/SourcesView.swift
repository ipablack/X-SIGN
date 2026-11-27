//
//  SourcesView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import Foundation
import CryptoKit
import CoreData
import AltSourceKit
import SwiftUI
import Combine
import NaturalLanguage
import Translation
import NimbleViews
import NukeUI
import Nuke
import UIKit

// MARK: - Appearance-aware application colors
enum AppStoreTheme {
    nonisolated static let oceanBlue = Color.accentColor
    nonisolated static let deepOcean = Color(red: 0.02, green: 0.16, blue: 0.36)
    nonisolated static let baseUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .systemGroupedBackground
    }
    nonisolated static let background = Color(uiColor: baseUIColor)
    nonisolated static let pureBlack = background
    nonisolated static let cardSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.075, alpha: 1) : .secondarySystemGroupedBackground
    })
    nonisolated static let controlSurface = Color(uiColor: .tertiarySystemFill)
    nonisolated static let outline = Color.primary.opacity(0.08)

    nonisolated static var dynamicAccent: Color { Color.accentColor }

    // Keep labels readable even when the wheel selects a very bright color.
    nonisolated static func contrastingText(forHex hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return .white
        }
        func channel(_ shift: Int) -> Double {
            let component = Double((value >> shift) & 0xFF) / 255.0
            return component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        return luminance > 0.179 ? .black : .white
    }
}

// MARK: - Protected Sources Vault (IPA BLACK and live providers)
enum ProtectedSourcesVault {
    nonisolated static var ownedURL: URL? { XSignCatalogueEndpoint.ownerURL }
    nonisolated static var coreURLs: [String] { [XSignCatalogueEndpoint.ownerURL.absoluteString] }

    nonisolated static func isRetiredSource(_ sourceURL: URL?, identifier: String? = nil) -> Bool {
        guard let sourceURL else { return true }
        return !isIPABlackSource(sourceURL) && XSignManagedSource.httpsURL(sourceURL.absoluteString) == nil
    }

    nonisolated static func isIPABlackSource(_ sourceURL: URL?, identifier: String? = nil) -> Bool {
        sourceURL.map(XSignDashboardSources.sourceKey) == XSignCatalogueEndpoint.ownerURL.absoluteString
    }

    nonisolated static func migrateOldSourceCaches() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "xsign.approvedSourcesMigrated.v1") else { return }
        defaults.removeObject(forKey: "xsign.managedSources")
        defaults.set(true, forKey: "xsign.approvedSourcesMigrated.v1")
        // New cache namespaces are active immediately; old catalogs are removed off the UI thread.
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? fm.removeItem(at: cache.appendingPathComponent("XSignInstantStoreCache_v2"))
            try? fm.removeItem(at: support.appendingPathComponent("XSignCatalogs_v3"))
        }
    }
}

// MARK: - Rich Apple App Store Metadata Model (Skips Deleted Apps Automatically)
struct AppleStoreRichMetadata: Codable, Sendable {
	let screenshots: [URL]
	let artworkURL: URL?
	let description: String?
	let releaseNotes: String?
	let sellerName: String?
	let genre: String?
	let contentRating: String?
	let rating: Double?
	let fileSizeBytes: Int64?
    var ratingCount: Int? = nil
    var minimumOSVersion: String? = nil
    var languageCodes: [String]? = nil
    var sellerURL: URL? = nil
    var storeURL: URL? = nil
    var releaseDate: String? = nil
}

actor AppStoreLiveMetadataBridge {
	static let shared = AppStoreLiveMetadataBridge()

	private var memoryCache: [String: AppleStoreRichMetadata] = [:]
    private var metadataOrder: [String] = []
	private var negativeCache: Set<String> = []
	private var inFlightTasks: [String: Task<AppleStoreRichMetadata?, Never>] = [:]

	private nonisolated static var diskCacheDir: URL {
		let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XSignAppleMetadataCache_SA_v6", isDirectory: true)
		try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

    private var metadataGeneration = 0

    func invalidateCache() {
        metadataGeneration += 1
        metadataOrder.removeAll()
        for task in inFlightTasks.values { task.cancel() }
        inFlightTasks.removeAll()
        memoryCache.removeAll()
        negativeCache.removeAll()
        try? FileManager.default.removeItem(at: Self.diskCacheDir)
    }

	// إذا كانت الأيقونة مستخرجة من ملفات التطبيق ومرفوعة على GitHub، فالتطبيق محذوف من متجر أبل ولا نطلب أي صور من أبل
	nonisolated static func hasExtractedGitHubIcon(_ iconURL: URL?) -> Bool {
		guard let str = iconURL?.absoluteString.lowercased() else { return false }
		return str.contains("/assets/icons/")
	}

	func fetchMetadata(bundleID: String?, appName: String, iconURL: URL? = nil, skipLookup: Bool = false) async -> AppleStoreRichMetadata? {
		// تخطي متجر أبل نهائياً إذا كان التطبيق يستخدم أيقونة مستخرجة من ملفاته على GitHub
		if skipLookup || Self.hasExtractedGitHubIcon(iconURL) {
			return nil
		}

        let language = XSignLanguage.current
		let cacheKey = "\(language.rawValue)_\(bundleID ?? "")_\(appName)".lowercased()
			.replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression)

		if negativeCache.contains(cacheKey) {
			return nil
		}

		if let cached = memoryCache[cacheKey] {
			return cached
		}

		let diskFile = Self.diskCacheDir.appendingPathComponent("\(cacheKey).json")
		if let data = try? Data(contentsOf: diskFile),
		   let decoded = try? JSONDecoder().decode(AppleStoreRichMetadata.self, from: data) {
			storeMetadata(decoded, for: cacheKey)
			return decoded
		}

		if let existingTask = inFlightTasks[cacheKey] {
			return await existingTask.value
		}

        guard !Task.isCancelled, inFlightTasks.count < 4 else { return nil }
		let generation = metadataGeneration
        let task = Task<AppleStoreRichMetadata?, Never> {
			// الفحص يتم حصرياً عبر الـ Bundle ID؛ إذا كان التطبيق محذوفاً من المتجر نتوقف فوراً ولا نجلب صوراً عشوائية بالاسم
			guard let bID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
				  bID.contains("."),
				  !bID.hasPrefix("games."),
				  bID != "com.ipablack.app",
				  let encodedID = bID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
			else {
				return nil
			}

            let storefronts = language == .arabic ? ["SA", "US"] : ["US", "SA"]
            let preference: String
            switch language {
            case .arabic: preference = "ar, en;q=0.8"
            case .english: preference = "en"
            case .kurdish: preference = "ckb, en;q=0.8"
            }
            for storefront in storefronts {
                let lookup = "https://itunes.apple.com/lookup?bundleId=\(encodedID)&country=\(storefront)"
                if let metadata = await Self.queryiTunes(urlString: lookup, preferredLanguage: preference) {
                    return metadata
                }
            }
			return nil
		}

		inFlightTasks[cacheKey] = task
		let result = await task.value
        guard metadataGeneration == generation else { return nil }
		inFlightTasks.removeValue(forKey: cacheKey)

		if let result {
			storeMetadata(result, for: cacheKey)
			if let encodedData = try? JSONEncoder().encode(result) {
				try? encodedData.write(to: diskFile, options: .atomic)
			}
		} else {
            if negativeCache.count >= 256 { negativeCache.removeAll(keepingCapacity: true) }
			negativeCache.insert(cacheKey)
		}
		return result
	}

    private func storeMetadata(_ metadata: AppleStoreRichMetadata, for key: String) {
        if memoryCache[key] == nil {
            if metadataOrder.count >= 128 {
                memoryCache.removeValue(forKey: metadataOrder.removeFirst())
            }
            metadataOrder.append(key)
        }
        memoryCache[key] = metadata
    }

	private nonisolated static func queryiTunes(urlString: String, preferredLanguage: String) async -> AppleStoreRichMetadata? {
		guard let url = URL(string: urlString) else { return nil }
		do {
			var request = URLRequest(url: url)
			request.timeoutInterval = 6
			request.setValue(preferredLanguage, forHTTPHeaderField: "Accept-Language")
			let (data, response) = try await URLSession.shared.data(for: request)
			guard let http = response as? HTTPURLResponse,
			      (200..<300).contains(http.statusCode) else { return nil }
			guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				  let results = json["results"] as? [[String: Any]],
				  let first = results.first else {
				return nil
			}

			var screenshots = (first["screenshotUrls"] as? [String])?.compactMap { URL(string: $0) } ?? []
			if screenshots.isEmpty {
				screenshots = (first["ipadScreenshotUrls"] as? [String])?.compactMap { URL(string: $0) } ?? []
			}

			let artString = (first["artworkUrl512"] as? String) ?? (first["artworkUrl100"] as? String)
			let artworkURL = artString.flatMap { URL(string: $0) }
			let description = first["description"] as? String
			let releaseNotes = first["releaseNotes"] as? String
			let sellerName = first["sellerName"] as? String
			let genre = first["primaryGenreName"] as? String
			let contentRating = first["trackContentRating"] as? String
			let rating = first["averageUserRating"] as? Double

			var parsedBytes: Int64? = nil
			if let sizeStr = first["fileSizeBytes"] as? String, let b = Int64(sizeStr) {
				parsedBytes = b
			} else if let sizeNum = first["fileSizeBytes"] as? NSNumber {
				parsedBytes = sizeNum.int64Value
			}

			var metadata = AppleStoreRichMetadata(
				screenshots: screenshots,
				artworkURL: artworkURL,
				description: description,
				releaseNotes: releaseNotes,
				sellerName: sellerName,
				genre: genre,
				contentRating: contentRating,
				rating: rating,
				fileSizeBytes: parsedBytes
			)
            metadata.ratingCount = first["userRatingCount"] as? Int
            metadata.minimumOSVersion = first["minimumOsVersion"] as? String
            metadata.languageCodes = first["languageCodesISO2A"] as? [String]
            metadata.sellerURL = (first["sellerUrl"] as? String).flatMap { XSignManagedSource.httpsURL($0) }
            metadata.storeURL = (first["trackViewUrl"] as? String).flatMap { value in
                guard let url = XSignManagedSource.httpsURL(value), ["apps.apple.com", "itunes.apple.com"].contains(url.host?.lowercased() ?? "") else { return nil }
                return url
            }
            metadata.releaseDate = first["currentVersionReleaseDate"] as? String
            return metadata
		} catch {
			return nil
		}
	}
}

// MARK: - Zero-Lag Bilingual Search & Clean Localization Engine
enum AppStoreBilingualEngine {
	nonisolated static let rawSynonymGroups: [[String]] = [
		["instagram", "insta", "ig", "rocket", "plus", "bhinsta", "انستقرام", "انستا", "انستجرام", "إنستجرام", "انستغرام", "إنستغرام"],
		["whatsapp", "watusi", "wa", "واتساب", "واتس", "واتس اب", "وتساب"],
		["tiktok", "tik tok", "lrd", "bh", "dl", "تيك توك", "تيكتوك", "تك توك"],
		["snapchat", "snap", "wicked", "shadow", "سناب", "سناب شات", "سنابشات"],
		["youtube", "uplus", "uyou", "cercube", "yt", "يوتيوب", "يتوب", "فيديو"],
		["telegram", "swiftgram", "nicegram", "tele", "تليجرام", "تلغرام", "تلكرام", "تيليجرام"],
		["twitter", "x", "bhx", "twt", "تويتر", "اكس", "إكس"],
		["facebook", "fb", "wolf", "فيسبوك", "فيس بوك", "فيس"],
		["messenger", "مسنجر", "ماسنجر"],
		["discord", "enmity", "vendetta", "ديسكورد", "دسكورد"],
		["reddit", "ريديت"],
		["threads", "ثريدز"],
		["spotify", "eevee", "spotilife", "سبوتيفاي", "سبوتفاي", "موسيقى", "اغاني", "أغاني"],
		["soundcloud", "ساوند كلاود", "ساوندكلاود"],
		["shahid", "شاهد", "مسلسلات"],
		["netflix", "نتفلكس", "نتفليكس", "افلام", "أفلام"],
		["osn", "ostora", "اسطورة", "الأسطورة", "مباريات", "بث", "تلفزيون", "iptv", "tv", "movie", "anime", "انمي", "أنمي"],
		["capcut", "كاب كات", "كابكات", "مونتاج", "تعديل فيديو"],
		["picsart", "بيكس ارت", "بيكس آرت", "تعديل صور"],
		["lightroom", "لايت روم", "لايتروم", "فلاتر"],
		["inshot", "انشوت", "إنشوت"],
		["videostar", "video star", "فيديو ستار", "فيديوستار"],
		["alight", "alight motion", "الايت موشن", "ألايت موشن"],
		["canva", "كانفا", "تصميم"],
		["photoshop", "فوتوشوب"],
		["remini", "ريميني", "توضيح الصور"],
		["pubg", "ببجي", "بوبجي", "شدات"],
		["8ball", "pool", "8 ball", "بلياردو", "بول", "بليارد"],
		["roblox", "روبلوكس", "روبلكس"],
		["minecraft", "ماين كرافت", "ماينكرافت"],
		["subway", "صب واي", "سابوي", "ركض"],
		["gta", "san andreas", "قراند", "جاتا", "حرامي السيارات"],
		["cod", "call of duty", "كود", "كول اوف ديوتي"],
		["freefire", "free fire", "فري فاير"],
		["clash", "brawl", "كلاش", "براول ستارز"],
		["fifa", "fc", "pes", "efootball", "فيفا", "بيس", "كرة قدم"],
		["ludo", "yalla", "لودو", "يلا لودو"],
		["chess", "شطرنج"],
		["car", "racing", "drift", "سيارات", "سباق", "هجولة", "تفحيط"],
		["filza", "فيلزا", "مدير ملفات", "ملفات"],
		["esign", "feather", "scarlet", "gbox", "ksign", "x-sign", "vsign", "توقيع", "شهادات", "متجر", "اي ساين", "فيذر"],
		["troll", "trollstore", "ترول ستور", "ترول"],
		["vpn", "adblock", "dns", "في بي ان", "كاسر بروكسي", "حجب اعلانات", "مانع اعلانات"],
		["ai", "chatgpt", "gemini", "claude", "ذكاء اصطناعي", "شات جي بي تي", "جيميناي"]
	]

	// تجهيز المرادفات مسبقاً لمرة واحدة في الذاكرة لمنع أي لاك أثناء الكتابة في البحث
	nonisolated static let preNormalizedSynonymGroups: [[String]] = {
		rawSynonymGroups.map { group in
			group.map { normalize($0) }
		}
	}()

    nonisolated static let preparedAliasIndex = XSignSearchAliasIndex(groups: preNormalizedSynonymGroups)

    nonisolated static func normalize(_ text: String) -> String {
        XSignSearchDocument.normalize(text)
    }

    nonisolated static func buildFastSearchTokens(for app: ASRepository.App, category: AppStore2026Category) -> String {
        let document = XSignSearchDocument(name: app.currentName, bundleID: app.id ?? "", aliasIndex: preparedAliasIndex)
        return ([document.name, document.bundle, normalize(category.rawValue)] + document.aliases).joined(separator: " ")
    }

	nonisolated static func matchesQuery(tokens: String, normalizedQuery: String) -> Bool {
		guard !normalizedQuery.isEmpty else { return true }
		return tokens.contains(normalizedQuery)
	}

	nonisolated static func isInternalSourceNote(_ text: String?) -> Bool {
		guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
			return true
		}
		let lower = text.lowercased()
		return lower.hasPrefix("sources:") ||
			lower.contains("flekstore") ||
			lower.contains("unkeyapp") ||
			lower.contains("khoipa") ||
			lower.contains(" | ")
	}

	nonisolated static func localizedSubtitle(for app: ASRepository.App, category: AppStore2026Category) -> String {
		if let customDesc = app.localizedDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
		   !customDesc.isEmpty,
		   !isInternalSourceNote(customDesc),
		   customDesc.count <= 65 {
			return customDesc
		}

		let nameAndID = "\(app.name ?? "") \(app.id ?? "")".lowercased()

		if nameAndID.contains("instagram") || nameAndID.contains("insta") || nameAndID.contains("rocket") {
			return "تواصل، شارك الصور والريلز بميزات إضافية"
		}
		if nameAndID.contains("whatsapp") || nameAndID.contains("watusi") {
			return "مراسلة فورية مع مزايا الخصوصية والتحميل"
		}
		if nameAndID.contains("tiktok") || nameAndID.contains("lrd") {
			return "فيديوهات قصيرة وحفظ بدون علامة مائية"
		}
		if nameAndID.contains("snapchat") || nameAndID.contains("wicked") || nameAndID.contains("shadow") {
			return "شارك اللحظات مع أدوات الحفظ المتقدمة"
		}
		if nameAndID.contains("youtube") || nameAndID.contains("uyou") || nameAndID.contains("uplus") {
			return "مشاهدة بدون إعلانات وتشغيل في الخلفية"
		}
		if nameAndID.contains("telegram") || nameAndID.contains("swiftgram") || nameAndID.contains("nicegram") {
			return "مراسلة سحابية سريعة وآمنة بلا حدود"
		}
		if nameAndID.contains("twitter") || nameAndID.contains("bhx") {
			return "أحدث الأخبار والتغريدات مع تحميل الوسائط"
		}
		if nameAndID.contains("spotify") || nameAndID.contains("eevee") {
			return "استمع للموسيقى والبودكاست بجودة عالية"
		}
		if nameAndID.contains("capcut") || nameAndID.contains("videostar") || nameAndID.contains("alight") || nameAndID.contains("inshot") {
			return "تحرير ومونتاج الفيديو باحترافية عالية"
		}
		if nameAndID.contains("picsart") || nameAndID.contains("lightroom") || nameAndID.contains("photoshop") || nameAndID.contains("remini") {
			return "تعديل الصور والفلاتر الاحترافية"
		}
		if nameAndID.contains("canva") {
			return "تصميم الجرافيك والشعارات بسهولة"
		}
		if nameAndID.contains("pubg") {
			return "معارك باتل رويال جماعية مشوقة"
		}
		if nameAndID.contains("pool") || nameAndID.contains("8ball") {
			return "لعبة البلياردو العالمية رقم 1"
		}
		if nameAndID.contains("roblox") {
			return "استمتع بلعب ملايين الألعاب والعوالم"
		}
		if nameAndID.contains("minecraft") {
			return "ابنِ عالمك واستكشف بلا حدود"
		}
		if nameAndID.contains("subway") || nameAndID.contains("minion") || nameAndID.contains("temple") || nameAndID.contains("sonic") {
			return "انضم إلى مرح دائم من الركض والقفز!"
		}
		if nameAndID.contains("filza") {
			return "مدير ملفات متكامل لنظام iOS"
		}
		if nameAndID.contains("esign") || nameAndID.contains("feather") || nameAndID.contains("scarlet") || nameAndID.contains("sign") {
			return "توقيع وتثبيت تطبيقات IPA بسهولة"
		}

		return category.defaultArabicSubtitle
	}
}

struct AppStoreAppItem: Identifiable, Hashable, Sendable {
	private(set) var id: String
	let sourceURL: URL?
    private(set) var sourceURLs: Set<URL>
    private(set) var sourceCatalogIDs: Set<String>
    let sourceName: String
    private(set) var categoryKeys: Set<String>
    private(set) var declaredCategories: [XSignCategoryLabel]
    private(set) var catalogueVersions: [ASRepository.App.Version] = []
	let app: ASRepository.App
	private(set) var category: AppStore2026Category
	private(set) var isGame: Bool
    let typeEvidence: XSignCatalogKindPolicy.TypeEvidence?
    let initialGame: Bool
    let inferredCategory: AppStore2026Category
	private(set) var arabicSubtitle: String
	let searchIndexTokens: String
    let searchDocument: XSignSearchDocument
	let screenshots: [URL]

    var categoryTitle: String { declaredCategories.first?.title ?? category.rawValue }

    init(id: String, sourceURL: URL?, sourceName: String?, taxonomy: XSignCategoryLookup,
         studioTaxonomy: XSignCategoryLookup, ownsCategory: Bool, app: ASRepository.App) {
		self.id = id
		self.sourceURL = sourceURL
        self.sourceURLs = Set([sourceURL].compactMap { $0 })
        self.sourceCatalogIDs = Set([app.id, app.catalogID].compactMap { $0 })
        self.sourceName = sourceName ?? "المصدر"
		self.app = app

        let match = taxonomy.match(app.categoryReferences, namesFrom: studioTaxonomy, owned: ownsCategory)
        self.categoryKeys = match.keys
        self.declaredCategories = match.labels.filter { label in
            let key = XSignCatalogKindPolicy.categoryKey(label.title) ?? label.key
            if XSignStoreCategory.allLabels.contains(key) { return false }
            let broad = ["game", "games", "gaming", "6014", "العاب", "الالعاب"].contains(key) ||
                ["games", "6014"].contains(label.key)
            return !broad || studioTaxonomy.definition(for: label.key) != nil
        }
        let inferred = AppStore2026Category.strictlyClassify(app: app)
        self.inferredCategory = inferred
        let declared = match.kind.map { XSignCatalogKindPolicy.TypeEvidence(game: $0, priority: match.explicit ? 4 : 2) }
        let mapped = match.studioKind.map { XSignCatalogKindPolicy.TypeEvidence(game: $0, priority: 3) }
        let recognised = XSignCatalogKindPolicy.recognizesGame(name: app.currentName, bundleID: app.id)
            ? XSignCatalogKindPolicy.TypeEvidence(game: true, priority: 1) : nil
        let sourceEvidence = match.explicit ? declared : (mapped ?? declared)
        let ownerKind = ownsCategory ? (match.primaryStudioKind ?? app.isGame) : nil
        let knownGame = XSignCatalogKindPolicy.knownGameBundle(app.id)
            ? XSignCatalogKindPolicy.TypeEvidence(game: true, priority: 6) : nil
        let genre = app.categoryReferences.lazy.compactMap { value -> Bool? in
            guard let key = XSignCatalogKindPolicy.categoryKey(value),
                  let id = Int(key), id == 6014 || (7001...7019).contains(id),
                  taxonomy.definition(for: value) == nil else { return nil }
            return true
        }.first
        let evidence = ownerKind.map { XSignCatalogKindPolicy.TypeEvidence(game: $0, priority: 7) }
            ?? knownGame ?? genre.map { XSignCatalogKindPolicy.TypeEvidence(game: $0, priority: 6) }
            ?? app.isGame.map { XSignCatalogKindPolicy.TypeEvidence(game: $0, priority: 5) } ?? sourceEvidence ?? recognised
        self.typeEvidence = evidence
        let game = evidence?.game ?? false
        self.isGame = game
        self.initialGame = game
        let category = game && !inferred.isGameCategory ? .casualGames
            : !game && inferred.isGameCategory ? .productivity : inferred
        self.category = category
        self.arabicSubtitle = AppStoreBilingualEngine.localizedSubtitle(for: app, category: category)
        self.searchDocument = XSignSearchDocument(name: app.currentName, bundleID: app.id ?? "", aliasIndex: AppStoreBilingualEngine.preparedAliasIndex)
        self.searchIndexTokens = ([searchDocument.name, searchDocument.bundle] + searchDocument.aliases).joined(separator: " ")

        let images = app.screenshotURLs.flatMap { $0.isEmpty ? nil : $0 } ?? app.screenshots?.iPhone ?? []
        self.screenshots = images.filter { XSignManagedSource.httpsURL($0.absoluteString) != nil }
	}

    func downloadProvenance(version: ASRepository.App.Version? = nil) -> SourceAppProvenance? {
        guard let sourceURL, let identifier = app.catalogID ?? app.id else { return nil }
        if let url = version?.downloadURL,
           url != app.currentDownloadUrl, app.versions?.contains(where: { $0.downloadURL == url }) != true {
            return nil
        }
        return SourceAppProvenance(sourceRepositoryURL: sourceURL, sourceRepositoryIdentifier: nil,
            sourceRepositoryName: sourceName, sourceAppIdentifier: identifier, sourceAppName: app.currentName,
            sourceAppVersion: version?.version ?? app.currentVersion, sourceAppVersionDate: version?.date?.date ?? app.currentDate?.date,
            sourceAppDownloadURL: version?.downloadURL ?? app.currentDownloadUrl)
    }

    nonisolated var typeGroupKey: String? {
        if let bundle = XSignCatalogKindPolicy.bundleKey(app.id) { return "bundle:" + bundle }
        return app.currentDownloadUrl.map { "download:" + $0.absoluteString }
    }

    nonisolated var catalogueKey: String { typeGroupKey ?? id }

    nonisolated static func combined(_ entries: [Self]) -> [Self] {
        let groups = Dictionary(grouping: entries, by: \.catalogueKey)
        var seen = Set<String>()
        return entries.compactMap { first in
            let key = first.catalogueKey
            guard seen.insert(key).inserted, let variants = groups[key] else { return nil }
            var evidence: XSignCatalogKindPolicy.TypeEvidence?
            for entry in variants {
                if let candidate = entry.typeEvidence { evidence = XSignCatalogKindPolicy.preferred(evidence, candidate) }
            }
            let game = evidence?.game ?? first.initialGame
            let primary = variants.reduce(first) { best, candidate in
                let ready = candidate.app.currentDownloadUrl != nil
                if ready != (best.app.currentDownloadUrl != nil) { return ready ? candidate : best }
                guard candidate.sourceURL == best.sourceURL,
                      let lhs = candidate.app.currentVersion,
                      let rhs = best.app.currentVersion,
                      XSignReleaseVersion.compare(lhs, rhs) == 1 else { return best }
                return candidate
            }
            var merged = primary.placed(inGames: game)
            merged.id = key
            var labels = Set<String>()
            merged.declaredCategories = []
            merged.categoryKeys = []
            var versions: [ASRepository.App.Version] = []
            var downloadURLs = Set<URL>()
            var metadataVersions = Set<String>()
            for item in variants {
                merged.sourceURLs.formUnion(item.sourceURLs)
                merged.sourceCatalogIDs.formUnion(item.sourceCatalogIDs)
                if item.typeEvidence.map({ $0.game == game || $0.priority < 2 }) != false {
                    merged.categoryKeys.formUnion(item.categoryKeys.filter { key in
                        XSignCatalogKindPolicy.categoryKind(key).map { $0 == game } ?? true
                    })
                    merged.declaredCategories += item.declaredCategories.filter { label in
                        let kind = XSignCatalogKindPolicy.categoryKind(label.title)
                        return (kind == nil || kind == game) && labels.insert(label.key).inserted
                    }
                }
                var releases = item.app.versions ?? []
                if let url = item.app.currentDownloadUrl, !releases.contains(where: { $0.downloadURL == url }) {
                    releases.insert(.init(version: item.app.currentVersion ?? "نسخة أخرى", date: item.app.currentDate,
                        localizedDescription: item.app.versionDescription, downloadURL: url,
                        size: item.app.size.flatMap { UInt(exactly: $0) }), at: 0)
                }
                for release in releases {
                    if let url = release.downloadURL {
                        if downloadURLs.insert(url).inserted { versions.append(release) }
                    } else if metadataVersions.insert(release.id).inserted {
                        versions.append(release)
                    }
                }
            }
            let downloadable = Set(versions.filter { $0.downloadURL != nil }.map(\.id))
            merged.catalogueVersions = versions.filter { $0.downloadURL != nil || !downloadable.contains($0.id) }
                .enumerated().sorted { lhs, rhs in
                    let leftValid = XSignReleaseVersion.valid(lhs.element.version)
                    let rightValid = XSignReleaseVersion.valid(rhs.element.version)
                    if leftValid != rightValid { return leftValid }
                    if let order = XSignReleaseVersion.compare(lhs.element.version, rhs.element.version), order != 0 {
                        return order > 0
                    }
                    if let left = lhs.element.date, let right = rhs.element.date, left != right { return left > right }
                    if (lhs.element.date != nil) != (rhs.element.date != nil) { return lhs.element.date != nil }
                    return lhs.offset < rhs.offset
                }.map(\.element)
            return merged
        }
    }

    nonisolated func placed(inGames game: Bool) -> Self {
        var item = self
        item.isGame = game
        item.category = inferredCategory.isGameCategory == game ? inferredCategory : (game ? .casualGames : .productivity)
        if item.category != category {
            item.arabicSubtitle = AppStoreBilingualEngine.localizedSubtitle(for: app, category: item.category)
        }
        return item
    }

	nonisolated func matchesNormalizedQuery(_ normalizedQuery: String) -> Bool {
		searchDocument.score(for: normalizedQuery) != nil
	}

	static func == (lhs: AppStoreAppItem, rhs: AppStoreAppItem) -> Bool {
		lhs.id == rhs.id
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}
}

// MARK: - Editorial Instruction Model
enum XSignSearchEngine {
    nonisolated static func search(_ items: [AppStoreAppItem], query: String) -> [AppStoreAppItem]? {
        let query = XSignSearchDocument.normalize(query)
        guard !query.isEmpty else { return [] }
        var matches: [(score: Int, position: Int)] = []
        for (position, item) in items.enumerated() {
            if position.isMultiple(of: 64), Task.isCancelled { return nil }
            if let score = item.searchDocument.score(for: query) { matches.append((score, position)) }
        }
        matches.sort { $0.score == $1.score ? $0.position < $1.position : $0.score < $1.score }
        guard !Task.isCancelled else { return nil }
        return matches.map { items[$0.position] }
    }
}

@MainActor
final class XSignSearchResults: ObservableObject {
    @Published private(set) var visible: [AppStoreAppItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var total = 0
    private var ranked: [AppStoreAppItem] = []
    private var task: Task<Void, Never>?
    private var worker: Task<[AppStoreAppItem]?, Never>?
    private var generation: UInt64 = 0

    func update(query: String, items: [AppStoreAppItem]) {
        cancel()
        let current = generation
        let normalized = XSignSearchDocument.normalize(query)
        guard !normalized.isEmpty else {
            visible = []; ranked = []; total = 0; isSearching = false; return
        }
        isSearching = true
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard let self, self.generation == current, !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { XSignSearchEngine.search(items, query: normalized) }
            self.worker = work
            guard let result = await work.value, !Task.isCancelled, self.generation == current else { return }
            self.ranked = result
            self.total = result.count
            self.visible = Array(result.prefix(40))
            self.isSearching = false
            self.worker = nil
        }
    }

    func showMore(after count: Int) {
        guard !isSearching, visible.count == count else { return }
        visible = Array(ranked.prefix(count + 40))
    }
    func cancel() {
        generation &+= 1
        task?.cancel(); worker?.cancel(); task = nil; worker = nil
        isSearching = false
    }
}

struct TodayEditorialInstruction: Identifiable, Sendable {
	let id: String
	let badge: String?
	let title: String
	let caption: String
	let imageURL: URL?
	let tintColor: Color
	let associatedApp: AppStoreAppItem?
    let targetURL: URL?
    let sourceURL: URL?
}

enum AppStore2026Category: String, CaseIterable, Identifiable, Sendable {
    static let importedTitles = [
        "social": "التواصل الاجتماعي", "social-networking": "التواصل الاجتماعي",
        "lifestyle": "نمط حياة", "entertainment": "ترفيه", "utilities": "أدوات",
        "productivity": "إنتاجية", "photo-video": "صور وفيديو", "games": "الألعاب",
        "puzzle": "ألعاب ألغاز", "simulation": "ألعاب محاكاة"
    ]

    nonisolated static func importedTitle(_ name: String) -> String {
        XSignCatalogKindPolicy.categoryKey(name).flatMap { importedTitles[$0] } ?? name
    }

	case topApps = "مختارات التطبيقات"
	case topGames = "مختارات الألعاب"
	case bestSellingApps = "اكتشف تطبيقات أخرى"
	case bestSellingGames = "اكتشف ألعابًا أخرى"
	case puzzleGames = "ألعاب ألغاز"
	case simulationGames = "ألعاب محاكاة"
	case social = "التواصل الاجتماعي"
	case casualGames = "ألعاب تسالي"
	case timePass = "تمضية وقت"
	case mediaReaders = "قارئات الوسائط"
	case productivity = "إنتاجية"
	case strategyGames = "ألعاب إستراتيجية"
	case pvpGames = "لاعب ضد لاعب"
	case devTools = "تطبيقات أدوات التطوير"
	case visualArts = "فنون بصرية"
	case photoVideo = "صور وفيديو"

	var id: String { rawValue }

	nonisolated var isGameCategory: Bool {
		switch self {
		case .topGames, .bestSellingGames, .puzzleGames, .simulationGames, .casualGames, .timePass, .strategyGames, .pvpGames:
			return true
		case .topApps, .bestSellingApps, .social, .mediaReaders, .productivity, .devTools, .visualArts, .photoVideo:
			return false
		}
	}

	nonisolated var defaultArabicSubtitle: String {
		switch self {
		case .topApps, .bestSellingApps: return "تطبيق مميز للآيفون"
		case .topGames, .bestSellingGames: return "لعبة رائجة ومختارة"
		case .puzzleGames: return "ألغاز وتحديات ذكاء ممتعة"
		case .simulationGames: return "محاكاة واقعية وبناء عوالم"
		case .social: return "تواصل اجتماعي ومراسلة فورية"
		case .casualGames: return "ألعاب تسالي سريعة وممتعة"
		case .timePass: return "ترفيه وتسلية في كل وقت"
		case .mediaReaders: return "مشاهدة الفيديو والموسيقى"
		case .productivity: return "إنتاجية وأدوات ذكية يومية"
		case .strategyGames: return "تخطيط، معارك، وإستراتيجية"
		case .pvpGames: return "منافسات جماعية لاعب ضد لاعب"
		case .devTools: return "أدوات النظام والتوقيع والمطورين"
		case .visualArts: return "تصميم جرافيك وفنون رقمية"
		case .photoVideo: return "تصوير ومونتاج وتحرير احترافي"
		}
	}

	var sfSymbol: String {
		switch self {
		case .topApps:          return "star.fill"
		case .topGames:         return "trophy.fill"
		case .bestSellingApps:  return "crown.fill"
		case .bestSellingGames: return "medal.fill"
		case .puzzleGames:      return "puzzlepiece.fill"
		case .simulationGames:  return "house.and.flag.fill"
		case .social:           return "bubble.left.and.bubble.right.fill"
		case .casualGames:      return "airplane.departure"
		case .timePass:         return "sparkles"
		case .mediaReaders:     return "book.pages.fill"
		case .productivity:     return "paperplane.fill"
		case .strategyGames:    return "flag.2.crossed.fill"
		case .pvpGames:         return "gamecontroller.fill"
		case .devTools:         return "wrench.and.screwdriver.fill"
		case .visualArts:       return "paintpalette.fill"
		case .photoVideo:       return "camera.fill"
		}
	}

    nonisolated static func declaredKind(app: ASRepository.App, categories: [ASRepository.CatalogCategory]) -> Bool? {
        app.isGame ?? XSignCategoryLookup(categories).match(app.categoryReferences).kind
    }

	nonisolated static func strictlyClassify(app: ASRepository.App) -> AppStore2026Category {
		let catRaw = (app.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if catRaw == "social" { return .social }
		if catRaw == "media" { return .photoVideo }
		if catRaw == "tools" { return .devTools }

		let nameAndBundle = "\(app.name ?? "") \(app.id ?? "") \(catRaw)".lowercased()
        let tokens = nameAndBundle.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let normalizedName = " " + tokens.joined(separator: " ") + " "
        func matches(_ keywords: [String]) -> Bool {
            keywords.contains { normalizedName.contains(" " + $0 + " ") }
        }

		let socialApps = ["instagram", "whatsapp", "tiktok", "snapchat", "twitter", "telegram", "facebook", "discord", "messenger", "reddit", "threads", "watusi", "bhinsta", "uplus", "rocket", "swiftgram", "nicegram", "wicked", "انستقرام", "واتس", "تيك توك", "سناب", "تليجرام", "تويتر", "فيسبوك", "ديسكورد"]
		if socialApps.contains(where: { nameAndBundle.contains($0) }) { return .social }

		let mediaApps = ["youtube", "uyou", "cercube", "spotify", "eevee", "soundcloud", "shahid", "netflix", "ostora", "iptv", "movie", "anime", "music", "podcast", "player", "infuse", "vlc", "يوتيوب", "سبوتيفاي", "شاهد", "نتفلكس", "افلام", "مسلسلات", "انمي", "موسيقى", "اسطورة"]
		if mediaApps.contains(where: { nameAndBundle.contains($0) }) { return .mediaReaders }

		let photoVideoApps = ["capcut", "lightroom", "picsart", "inshot", "videostar", "alight", "photoshop", "remini", "camera", "dazz", "lensa", "b612", "snow", "vsco", "snapseed", "كاب كات", "بيكس ارت", "لايت روم", "فيديو ستار", "مونتاج", "فوتوشوب"]
		if photoVideoApps.contains(where: { nameAndBundle.contains($0) }) { return .photoVideo }

		let visualArtApps = ["canva", "procreate", "ibis", "sketch", "pixelmator", "vector", "font", "logo", "كانفا", "رسم", "خطوط"]
		if visualArtApps.contains(where: { nameAndBundle.contains($0) }) { return .visualArts }

		let devToolApps = ["filza", "esign", "feather", "scarlet", "troll", "gbox", "ksign", "x-sign", "vsign", "vpn", "adblock", "adguard", "dns", "flex", "igamegod", "dl", "terminal", "ssh", "cert", "ipa", "sideload", "altstore", "فيلزا", "توقيع", "شهادات", "ترول"]
        if matches(devToolApps) { return .devTools }

		let pvpKeywords = ["pubg", "8ball", "8ballpool", "eightballpool", "8 ball", "pool", "cod", "callofduty", "call of duty", "freefire", "free fire", "brawl", "fortnite", "fifa", "efootball", "pes", "mobilelegends", "mobile legends", "wildrift", "wild rift", "standoff", "bullet", "pvp", "multiplayer", "ark", "ببجي", "بلياردو", "فري فاير", "كود", "فيفا", "بيس"]
		if matches(pvpKeywords) { return .pvpGames }

		let strategyKeywords = ["clash", "royale", "clans", "strategy", "chess", "tower", "defense", "war", "stick war", "empire", "civilization", "boombeach", "plantsvs", "كلاش", "شطرنج", "حرب", "استراتيجيه"]
		if matches(strategyKeywords) { return .strategyGames }

		let simulationKeywords = ["roblox", "minecraft", "sims", "simcity", "gta", "grand theft auto", "gangstar", "rockstar", "sanandreas", "parking", "simulator", "bus", "truck", "flight", "farm", "hayday", "township", "روبلوكس", "ماين كرافت", "قراند", "محاكاة", "مزرعه"]
		if matches(simulationKeywords) { return .simulationGames }

		let puzzleKeywords = ["puzzle", "candy", "crush", "match", "brain", "sudoku", "word", "gardenscapes", "homescapes", "royalmatch", "angrybirds", "cuttherope", "2048", "trivia", "الغاز", "ألغاز", "ذكاء", "كلمات"]
		if matches(puzzleKeywords) { return .puzzleGames }

		let casualGameKeywords = [
			"game", "games", "gaming", "arcade", "subway", "surfers", "minion", "temple run", "sonic",
			"talking tom", "flappy", "racing", "race", "asphalt", "carx", "drift", "hillclimb",
			"ludo", "yalla", "uno", "monopoly", "fruitninja", "jetpack", "pacman", "mario", "pokemon",
			"zelda", "playdead", "gameloft", "supercell",
			"zynga", "rovio", "ketchapp", "voodoo", "miniclip", "ubisoft", "activision", "konami", "sega",
			"لعبة", "لعبه", "العاب", "ألعاب"
		]
		if matches(casualGameKeywords) { return .casualGames }

		return .productivity
	}
}

struct XSignCategoryLabel: Sendable {
    let key: String
    let title: String
}

struct XSignCategoryLookup: Sendable {
    private var byKey: [String: ASRepository.CatalogCategory] = [:]

    init(_ categories: [ASRepository.CatalogCategory]) {
        for category in categories {
            if let key = XSignCatalogKindPolicy.categoryKey(category.id), byKey[key] == nil { byKey[key] = category }
        }
        for category in categories {
            for key in ([category.name] + (category.aliases ?? [])).compactMap(XSignCatalogKindPolicy.categoryKey) {
                if byKey[key] == nil { byKey[key] = category }
            }
        }
    }

    func definition(for value: String?) -> ASRepository.CatalogCategory? {
        XSignCatalogKindPolicy.categoryKey(value).flatMap { byKey[$0] }
    }

    static func externalKey(_ category: ASRepository.CatalogCategory) -> String? {
        guard let id = XSignCatalogKindPolicy.categoryKey(category.id) else { return nil }
        let name = XSignCatalogKindPolicy.categoryKey(category.name) ?? id
        return "source:" + id + ":" + name
    }

    func match(_ values: [String], namesFrom studio: Self? = nil, owned: Bool = false) -> (keys: Set<String>, labels: [XSignCategoryLabel], kind: Bool?, explicit: Bool, studioKind: Bool?, primaryStudioKind: Bool?) {
        var keys = Set<String>()
        var seenLabels = Set<String>()
        var labels: [XSignCategoryLabel] = []
        var kind: Bool?
        var studioKind: Bool?
        var primaryStudioKind: Bool?
        var explicit = false
        for (index, value) in values.enumerated() {
            guard let key = XSignCatalogKindPolicy.categoryKey(value) else { continue }
            let category = byKey[key]
            let categoryKey = category.flatMap { XSignCatalogKindPolicy.categoryKey($0.id) } ?? key
            let mapped = studio.flatMap { lookup -> ASRepository.CatalogCategory? in
                let byID = lookup.byKey[key] ?? lookup.byKey[categoryKey]
                guard !owned, let category else { return byID ?? lookup.definition(for: category?.name) }
                if let byName = lookup.definition(for: category.name) { return byName }
                // Numeric IDs are local to a feed. Only an explicit alias may remap a named foreign category.
                if Int(categoryKey) != nil, XSignCatalogKindPolicy.categoryKey(category.name) != categoryKey,
                   byID.flatMap({ XSignCatalogKindPolicy.categoryKey($0.id) }) == categoryKey { return nil }
                return byID
            }
            if let mapped {
                if studioKind == nil { studioKind = mapped.isGame }
                if index == 0 { primaryStudioKind = mapped.isGame }
            }
            let display = mapped ?? category
            let labelKey = mapped.flatMap { XSignCatalogKindPolicy.categoryKey($0.id) }
                ?? (owned ? categoryKey : category.flatMap(Self.externalKey)) ?? categoryKey
            keys.insert(labelKey)
            keys.insert(categoryKey)
            keys.insert(key)
            let lookup = mapped == nil ? self : (studio ?? self)
            if let display {
                for alias in [display.name] + (display.aliases ?? []) {
                    guard lookup.definition(for: alias)?.id == display.id,
                          let aliasKey = XSignCatalogKindPolicy.categoryKey(alias) else { continue }
                    keys.insert(aliasKey)
                }
            }
            if seenLabels.insert(labelKey).inserted { labels.append(.init(key: labelKey, title: mapped?.name ?? AppStore2026Category.importedTitle(display?.name ?? value))) }
            if !explicit, let flag = category?.isGame {
                kind = flag
                explicit = true
            } else if kind == nil {
                kind = XSignCatalogKindPolicy.categoryKind(value) ?? XSignCatalogKindPolicy.categoryKind(category?.name)
            }
        }
        return (keys, labels, kind, explicit, studioKind, primaryStudioKind)
    }
}

struct XSignStoreCategory: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    var iconSVG: String? = nil
    var items: [AppStoreAppItem]
    var keys: Set<String>
    static let allLabels: Set<String> = ["all", "all-apps", "all-games", "الكل", "كل-التطبيقات", "كل-الالعاب", "جميع-التطبيقات", "جميع-الالعاب"]

    static func groups(_ items: [AppStoreAppItem], studio: [ASRepository.CatalogCategory],
                       sourceCategories: [ASRepository.CatalogCategory], legacy: [AppStore2026Category]) -> [Self] {
        var index: [String: [AppStoreAppItem]] = [:]
        var labels: [XSignCategoryLabel] = []
        var known = Set<String>()
        for item in items {
            for label in item.declaredCategories {
                index[label.key, default: []].append(item)
                if known.insert(label.key).inserted { labels.append(label) }
            }
        }

        let fallback = Dictionary(grouping: items.filter { $0.declaredCategories.isEmpty }, by: \.category)
        var seen = Set<String>()
        var result: [Self] = []
        let definitions = studio.map { ($0, true) } + sourceCategories.map { ($0, false) }
        for (definition, isOwned) in definitions {
            guard let id = XSignCatalogKindPolicy.categoryKey(definition.id),
                  let key = isOwned ? id : XSignCategoryLookup.externalKey(definition),
                  seen.insert(key).inserted else { continue }
            let group = index[key] ?? []
            guard !group.isEmpty || isOwned else { continue }
            let aliases = ([definition.name] + (definition.aliases ?? [])).compactMap(XSignCatalogKindPolicy.categoryKey)
            let isGame = definition.isGame ?? group.allSatisfy(\.isGame)
            result.append(.init(id: "category:" + key, title: isOwned ? definition.name : AppStore2026Category.importedTitle(definition.name),
                symbol: isGame ? "gamecontroller" : "square.grid.2x2", iconSVG: definition.iconSVG,
                items: group, keys: Set([id, key] + aliases)))
        }
        for label in labels where !seen.contains(label.key) {
            guard let group = index[label.key] else { continue }
            result.append(.init(id: "category:" + label.key, title: label.title,
                symbol: group.allSatisfy(\.isGame) ? "gamecontroller" : "square.grid.2x2",
                items: group, keys: [label.key]))
        }
        for kind in legacy {
            guard let group = fallback[kind], !group.isEmpty else { continue }
            result.append(.init(id: "legacy:" + kind.rawValue, title: kind.rawValue, symbol: kind.sfSymbol,
                items: group, keys: Set([XSignCatalogKindPolicy.categoryKey(kind.rawValue)].compactMap { $0 })))
        }
        var positions: [String: Int] = [:]
        var unique: [Self] = []
        for group in result {
            guard let title = XSignCatalogKindPolicy.categoryKey(AppStore2026Category.importedTitle(group.title)),
                  !allLabels.contains(title), allLabels.isDisjoint(with: group.keys) else { continue }
            if let position = positions[title] {
                var itemIDs = Set(unique[position].items.map(\.id))
                unique[position].items += group.items.filter { itemIDs.insert($0.id).inserted }
                unique[position].keys.formUnion(group.keys)
                if unique[position].iconSVG == nil { unique[position].iconSVG = group.iconSVG }
            } else {
                positions[title] = unique.count
                unique.append(group)
            }
        }
        return unique
    }
}

// MARK: - Cached catalog shown before background refresh
private struct XSignCatalogSnapshot: Sendable {
    var ipablackItems: [AppStoreAppItem] = []
    var ipablackEditorialNews: [TodayEditorialInstruction] = []
    var allCombinedItems: [AppStoreAppItem] = []
    var pureAppsOnly: [AppStoreAppItem] = []
    var pureGamesOnly: [AppStoreAppItem] = []
    var includesIPABlack = false
    var skippedLookupBundleIDs: Set<String> = []
    var todayItems: [AppStoreAppItem] = []
    var todayNews: [TodayEditorialInstruction] = []
    var todayFeaturedBySource: [URL: [String]] = [:]
    var appCategories: [XSignStoreCategory] = []
    var gameCategories: [XSignStoreCategory] = []
    var searchCategories: [XSignStoreCategory] = []
    var todayCategoryGroups: [XSignStoreCategory] = []
}

@MainActor
final class AppStoreCacheManager: ObservableObject {
    static let shared = AppStoreCacheManager()

    @Published private var catalog = XSignCatalogSnapshot()
    var ipablackItems: [AppStoreAppItem] { catalog.ipablackItems }
    var ipablackEditorialNews: [TodayEditorialInstruction] { catalog.ipablackEditorialNews }
    var allCombinedItems: [AppStoreAppItem] { catalog.allCombinedItems }
    var pureAppsOnly: [AppStoreAppItem] { catalog.pureAppsOnly }
    var pureGamesOnly: [AppStoreAppItem] { catalog.pureGamesOnly }
    var todayItems: [AppStoreAppItem] {
        guard let selectedTodayURLs else { return catalog.todayItems }
        return catalog.todayItems.filter { $0.sourceURL.map(selectedTodayURLs.contains) == true }
    }
    var todayEditorialNews: [TodayEditorialInstruction] {
        guard let selectedTodayURLs else { return catalog.todayNews }
        return catalog.todayNews.filter { $0.sourceURL.map(selectedTodayURLs.contains) == true }
    }

    private var todaySourceIDs: Set<String>?
    var todayEmptyMessage: String {
        let targets = todayTargets
        if targets.isEmpty { return "لا توجد مصادر مفعّلة لصفحة اليوم." }
        if targets.allSatisfy(sourceFailures.contains) { return "تعذّر الوصول إلى مصادر اليوم. تحقق من الاتصال وأعد المحاولة." }
        return "لا يوجد محتوى متاح لليوم حاليًا."
    }

    private var todayTargets: [URL] {
        Self.coreTargets.compactMap { target in
            guard let url = URL(string: target.urlStr),
                  XSignTodaySourcePolicy.allows(id: target.id, url: url, selected: todaySourceIDs) else { return nil }
            return url
        }
    }

    private var selectedTodayURLs: Set<URL>? {
        todaySourceIDs.map { _ in Set(todayTargets.map(XSignCatalogIO.canonicalURL)) }
    }

    func applyTodaySources(_ ids: [String]?) {
        let selected = ids.map(Set.init)
        guard selected != todaySourceIDs else { return }
        todaySourceIDs = selected
        scheduleSnapshot(priority: .userInitiated)
    }
    var todayFeaturedBySource: [URL: [String]] { catalog.todayFeaturedBySource }

    func categories(for page: String) -> [XSignStoreCategory] {
        switch page {
        case "apps": return catalog.appCategories
        case "games": return catalog.gameCategories
        case "today":
            guard let selectedTodayURLs else { return catalog.todayCategoryGroups }
            return catalog.todayCategoryGroups.compactMap { group in
                var visible = group
                visible.items = group.items.filter { $0.sourceURL.map(selectedTodayURLs.contains) == true }
                return visible.items.isEmpty ? nil : visible
            }
        default: return catalog.searchCategories
        }
    }

    func categories(for page: String, section: XSignStoreSection) -> [XSignStoreCategory] {
        let source = XSignDashboardSources.sectionSource(section.source_url)
        let category = XSignCatalogKindPolicy.categoryKey(section.category_id)
        let appIDs = Set(section.app_ids ?? [])
        var groups = categories(for: page).compactMap { group -> XSignStoreCategory? in
            if let category, !group.keys.contains(category) { return nil }
            guard source != nil || !appIDs.isEmpty else { return group }
            var filtered = group
            filtered.items = group.items.filter { item in
                (source.map(item.sourceURLs.contains) ?? true) &&
                    (appIDs.isEmpty || !appIDs.isDisjoint(with: item.sourceCatalogIDs))
            }
            return filtered.items.isEmpty ? nil : filtered
        }
        if section.sort == "name" { groups.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }
        if section.sort == "reverse" { groups.reverse() }
        return Array(groups.prefix(section.boundedLimit))
    }

    private var studioCategories: [ASRepository.CatalogCategory]?

    func applyStudioCategories(_ categories: [ASRepository.CatalogCategory]?) {
        guard categories != studioCategories else { return }
        studioCategories = categories
        scheduleSnapshot(priority: .userInitiated)
    }


    var featuredCatalogIDs: [String] {
        Self.coreTargets.flatMap { directLoadedRepos[$0.urlStr]?.featuredApps ?? [] }.compactMap { $0 }
    }

    var hasLoadedCatalog: Bool { !catalog.allCombinedItems.isEmpty || finishedInitialLoad }
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingToday = false
    @Published private(set) var isPreparing = false
    @Published private(set) var catalogErrorMessage: String? = nil
    @Published private var sourceFailures = Set<URL>()
    @Published private(set) var catalogRevision: UInt64 = 0
    private var finishedInitialLoad = false
    private var publicationTask: Task<Void, Never>?
    private var sourceSubscription: AnyCancellable?
    private var requestedSources: [AltSource] = []
    private var customFingerprints: [String: Data] = [:]
    private let catalogIO: XSignCatalogIO

    func shouldSkipStoreLookup(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return catalog.skippedLookupBundleIDs.contains(bundleID)
    }

    private var loadedCacheIdentities: [String: String] = [:]
    private var acceptedOwnerRevision = 0
    private var directLoadedRepos: [String: ASRepository] = [:]
    private var repoFingerprints: [String: Data] = [:]
    private var customSnapshot: [(URL?, String?, ASRepository)] = []
    private var diskSnapshotTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var nextRefreshAllowed = Date.distantPast
    private var indexGeneration: UInt64 = 0
    private var indexTask: Task<XSignCatalogSnapshot?, Never>?

    private nonisolated static let defaultCoreTargets: [XSignManagedSource] = [
        .init(id: XSignCatalogueEndpoint.primaryID, name: "IPA SOON", url: XSignCatalogueEndpoint.soonSnapshot.absoluteString),
        .init(id: XSignCatalogueEndpoint.iosBoomID, name: "iOSBoom Public", url: XSignCatalogueEndpoint.iosBoomCatalogue.absoluteString)
    ]

    nonisolated static func availableManagedSources(_ legacy: [XSignCoreSourceItem]? = nil) -> [XSignManagedSource] {
        let fallback = legacy?.map { XSignManagedSource(id: $0.id, name: $0.name, url: $0.url) } ?? defaultCoreTargets
        return XSignDashboardSources.managed ?? XSignDashboardSources.normalized(fallback)
    }

    nonisolated static func resolvedManagedSources(_ legacy: [XSignCoreSourceItem]?) -> [XSignCoreSourceItem] {
        availableManagedSources(legacy).filter { $0.enabled != false }
            .map { XSignCoreSourceItem(name: $0.name, id: $0.id, url: $0.url) }
    }

    private nonisolated static var coreTargets: [(urlStr: String, id: String, file: String)] {
        resolvedManagedSources(nil).compactMap { source in
            guard let url = URL(string: source.url) else { return nil }
            let file = "managed_" + SHA256.hash(data: Data(XSignCatalogIO.cacheIdentity(url).utf8)).prefix(12)
                .map { String(format: "%02x", $0) }.joined() + ".json"
            return (source.url, source.id, file)
        }
    }

    @discardableResult
    func configureManagedSources(_ sources: [XSignCoreSourceItem]?, resetAdapters: Bool = false) -> Bool {
        let valid = Self.resolvedManagedSources(sources)
        guard let encoded = try? JSONEncoder().encode(valid) else { return false }
        let prior = UserDefaults.standard.data(forKey: "xsign.managedSources")
        if !resetAdapters, let prior, (try? JSONDecoder().decode([XSignCoreSourceItem].self, from: prior)) == valid { return false }
        UserDefaults.standard.set(encoded, forKey: "xsign.managedSources")
        let allowed = Set(valid.map { $0.url })
        let identities = Dictionary(uniqueKeysWithValues: Self.coreTargets.map { ($0.urlStr, $0.file) })
        directLoadedRepos = directLoadedRepos.filter { allowed.contains($0.key) && (!resetAdapters ||
            identities[$0.key] == loadedCacheIdentities[$0.key]) }
        repoFingerprints = repoFingerprints.filter { directLoadedRepos[$0.key] != nil }
        loadedCacheIdentities = identities
        rebuildCustomSnapshot(sources: requestedSources, repositories: SourcesViewModel.shared.sources, viewModel: .shared)
        let liveURLs = Set(valid.compactMap { URL(string: $0.url) } + customSnapshot.compactMap { $0.0 })
        if allCombinedItems.contains(where: { $0.sourceURL.map(liveURLs.contains) != true }) ||
            catalog.todayItems.contains(where: { $0.sourceURL.map(liveURLs.contains) != true }) ||
            catalog.todayNews.contains(where: { $0.sourceURL.map(liveURLs.contains) != true }) {
            var visible = catalog
            visible.allCombinedItems.removeAll { $0.sourceURL.map(liveURLs.contains) != true }
            visible.todayItems.removeAll { $0.sourceURL.map(liveURLs.contains) != true }
            visible.pureAppsOnly.removeAll { $0.sourceURL.map(liveURLs.contains) != true }
            visible.pureGamesOnly.removeAll { $0.sourceURL.map(liveURLs.contains) != true }
            visible.todayNews.removeAll { $0.sourceURL.map(liveURLs.contains) != true }
            visible.todayFeaturedBySource = visible.todayFeaturedBySource.filter { liveURLs.contains($0.key) }
            func filterGroups(_ groups: [XSignStoreCategory]) -> [XSignStoreCategory] {
                groups.compactMap { group in
                    let items = group.items.filter { $0.sourceURL.map(liveURLs.contains) == true }
                    guard group.items.isEmpty || !items.isEmpty else { return nil }
                    var visible = group
                    visible.items = items
                    return visible
                }
            }
            visible.appCategories = filterGroups(visible.appCategories)
            visible.gameCategories = filterGroups(visible.gameCategories)
            visible.searchCategories = filterGroups(visible.searchCategories)
            visible.todayCategoryGroups = filterGroups(visible.todayCategoryGroups)
            catalog = visible
            catalogRevision &+= 1
        }
        nextRefreshAllowed = .distantPast
        restoreBoundedLaunchPreviews()
        scheduleSnapshot(priority: .userInitiated)
        loadInstantDiskSnapshot()
        return true
    }

    func invalidateNetworkCache() {
        repoFingerprints.removeAll()
        nextRefreshAllowed = .distantPast
        Task { await catalogIO.invalidateValidators() }
        // Keep the visible snapshot and last good disk catalog until a valid response replaces them.
        Task { await AppStoreLiveMetadataBridge.shared.invalidateCache() }
    }

    private nonisolated static var diskCacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XSignApprovedStoreCache_v2", isDirectory: true)
        try? XSignPrivateFiles.createDirectory(dir)
        return dir
    }

    private nonisolated static let bundledLaunchSeedPayloads: [String: String] = [:] // __XSIGN_BUNDLE_SEED__

    private func restoreBoundedLaunchPreviews() {
        // Bound synchronous launch work; use fresh device previews first, then ultra-light build-time seed for 0ms first launch.
        for target in Self.coreTargets.prefix(6) where directLoadedRepos[target.urlStr] == nil {
            guard let url = URL(string: target.urlStr) else { continue }
            let path = Self.diskCacheDirectory.appendingPathComponent("preview_" + target.file)
            if let size = (try? path.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               size <= 524_288, let data = try? Data(contentsOf: path),
               let record = try? XSignCatalogIO.decode(data), record.repository.apps.count <= 60 {
                directLoadedRepos[target.urlStr] = record.repository
                loadedCacheIdentities[target.urlStr] = target.file
                continue
            }
            let canonical = XSignCatalogIO.canonicalURL(url).absoluteString
            if let encoded = Self.bundledLaunchSeedPayloads[target.urlStr] ?? Self.bundledLaunchSeedPayloads[canonical],
               let seedData = Data(base64Encoded: encoded),
               seedData.count <= 524_288,
               let record = try? XSignCatalogIO.decode(seedData),
               record.repository.apps.count <= 60 {
                directLoadedRepos[target.urlStr] = record.repository
                loadedCacheIdentities[target.urlStr] = target.file
            }
        }
    }

    // Previously validated previews come from the device cache.
    init(catalogIO: XSignCatalogIO = .shared) {
        ProtectedSourcesVault.migrateOldSourceCaches()
        self.catalogIO = catalogIO
        restoreBoundedLaunchPreviews()
        let preview = Self.coreTargets.compactMap { target -> (URL?, String?, ASRepository)? in
            guard let repo = directLoadedRepos[target.urlStr] else { return nil }
            return (URL(string: target.urlStr).map(XSignCatalogIO.canonicalURL), target.id, repo)
        }
        studioCategories = XSignRemoteManager.shared.catalogueCategories
        todaySourceIDs = XSignRemoteManager.shared.config?.dashboard?.today_source_ids.map { Set($0) }
        if !preview.isEmpty,
           let snapshot = Self.buildSnapshot(snapshot: preview, studioCategories: studioCategories,
                                             todaySourceIDs: todaySourceIDs, launchPreview: true) {
            catalog = snapshot
            prefetchVisibleIcons(from: snapshot)
        }
        loadInstantDiskSnapshot()
    }

    private func loadInstantDiskSnapshot() {
        diskSnapshotTask?.cancel()
        let targets = Self.coreTargets
        diskSnapshotTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: (Int, XSignRepositoryRecord?).self) { group in
                guard let io = self?.catalogIO else { return }
                let load: @Sendable (Int) async -> (Int, XSignRepositoryRecord?) = { index in
                    guard let url = URL(string: targets[index].urlStr) else { return (index, nil) }
                    return (index, await io.cached(url))
                }
                let count = min(6, targets.count)
                for index in 0..<count { group.addTask { await load(index) } }
                var next = count
                for await (index, record) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    let target = targets[index]
                    if let self, let record, let url = URL(string: target.urlStr),
                       self.repoFingerprints[target.urlStr] == nil,
                       Self.coreTargets.contains(where: { $0.urlStr == target.urlStr && $0.file == target.file }) {
                        self.acceptRepository(record, from: url)
                    }
                    if next < targets.count {
                        let index = next
                        next += 1
                        group.addTask { await load(index) }
                    }
                }
            }
            guard !Task.isCancelled, let self else { return }
            await self.publicationTask?.value
        }
    }

    func acceptRepository(_ record: XSignRepositoryRecord, from input: URL) {
        let key = XSignCatalogIO.canonicalURL(input).absoluteString
        guard let target = Self.coreTargets.first(where: {
            URL(string: $0.urlStr).map { XSignCatalogIO.canonicalURL($0).absoluteString } == key
        }), repoFingerprints[target.urlStr] != record.fingerprint else { return }
        if key == XSignCatalogueEndpoint.ownerURL.absoluteString {
            let revision = record.revision ?? 0
            guard revision >= acceptedOwnerRevision else { return }
            acceptedOwnerRevision = revision
        }
        directLoadedRepos[target.urlStr] = record.repository
        repoFingerprints[target.urlStr] = record.fingerprint
        loadedCacheIdentities[target.urlStr] = target.file
        scheduleSnapshot(priority: key == XSignCatalogueEndpoint.iosBoomCatalogue.absoluteString ? .utility : .userInitiated)
        let repo = record.repository
        let path = Self.diskCacheDirectory.appendingPathComponent("preview_" + target.file)
        Task.detached(priority: .utility) {
            if let preview = Self.makeLaunchPreview(repo) {
                try? preview.write(to: path, options: .atomic)
                try? XSignPrivateFiles.protect(path)
            }
        }
    }

    private func customSources(_ sources: [AltSource]) -> [AltSource] {
        let managed = Set(Self.availableManagedSources().compactMap(\.safeURL).map(XSignDashboardSources.sourceKey))
            .union([XSignDashboardSources.sourceKey(XSignCatalogueEndpoint.soonSnapshot)])
        return sources.filter { source in
            guard !source.isDeleted, let url = source.sourceURL.map(XSignCatalogIO.canonicalURL),
                  source.identifier != XSignCatalogueEndpoint.primaryID,
                  !ProtectedSourcesVault.isRetiredSource(url, identifier: source.identifier) else { return false }
            return !XSignDashboardSources.isHidden(url.absoluteString) &&
                !managed.contains(XSignDashboardSources.sourceKey(url)) && XSignDashboardSources.isUserSource(url)
        }
    }

    func ensureFetched<S: Collection>(sources: S, viewModel: SourcesViewModel) async where S.Element == AltSource {
        await refresh(sources: Array(sources), viewModel: viewModel, force: false)
    }

    func runAutomaticUpdates(sources: @escaping @MainActor () -> [AltSource], viewModel: SourcesViewModel) async {
        while !Task.isCancelled {
            await ensureFetched(sources: sources(), viewModel: viewModel)
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
        }
    }

    func waitForInitialCatalog() async {
        await diskSnapshotTask?.value
        await publicationTask?.value
    }

    func forceRefresh<S: Collection>(sources: S, viewModel: SourcesViewModel) async where S.Element == AltSource {
        await refresh(sources: Array(sources), viewModel: viewModel, force: true)
    }

    private func refresh(sources: [AltSource], viewModel: SourcesViewModel, force: Bool) async {
        requestedSources = sources
        if sourceSubscription == nil {
            sourceSubscription = viewModel.$sources.sink { [weak self, weak viewModel] repositories in
                guard let self, let viewModel else { return }
                self.rebuildCustomSnapshot(sources: self.requestedSources, repositories: repositories, viewModel: viewModel)
            }
        }
        if let running = refreshTask {
            if force { refreshAgain = true }
            await running.value
            // A source added during an existing refresh must not get lost.
            if customSources(requestedSources).contains(where: { viewModel.sources[$0] == nil && viewModel.errors[$0] == nil }) {
                await refresh(sources: requestedSources, viewModel: viewModel, force: false)
            }
            return
        }
        let custom = customSources(sources)
        let hasNewSources = custom.contains { viewModel.sources[$0] == nil && viewModel.errors[$0] == nil }
        guard force || hasNewSources || Date() >= nextRefreshAllowed else {
            rebuildCacheIfNeeded(sources: sources, repositoriesMap: viewModel.sources)
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            defer { self.refreshTask = nil; self.isRefreshing = false; self.finishedInitialLoad = true }
            repeat {
                self.refreshAgain = false
                let custom = self.customSources(self.requestedSources)
                async let coreSucceeded = self.fetchCoreRepositories()
                // This path already passed the refresh deadline. Refresh custom URLs too,
                // even when a previous response is visible; otherwise they never update automatically.
                await viewModel.fetchSources(custom, refresh: true, batchSize: 6)
                let succeeded = await coreSucceeded
                self.rebuildCacheIfNeeded(sources: self.requestedSources, repositoriesMap: viewModel.sources)
                await self.publicationTask?.value
                let customSourceFailed = custom.contains { viewModel.errors[$0] != nil }
                if self.catalogErrorMessage == nil, customSourceFailed {
                    self.catalogErrorMessage = "تعذّر تحديث أحد المصادر. ستتم إعادة المحاولة تلقائيًا."
                }
                self.nextRefreshAllowed = Date().addingTimeInterval(succeeded && !customSourceFailed ? 300 : 30)
            } while self.refreshAgain && !Task.isCancelled
        }
        refreshTask = task
        await task.value
    }

    func refreshToday() async {
        guard !isRefreshingToday else { return }
        isRefreshingToday = true
        defer { isRefreshingToday = false }
        await XSignRemoteManager.shared.fetchRemoteConfig(force: true)
        guard !XSignRemoteManager.shared.isMaintenanceActive, !XSignRemoteManager.shared.isForceUpdateRequired,
              !XSignSecurityEnforcer.shared.isVPNOrProxyDetected else { return }
        _ = await fetchRepositories(todayTargets)
        await publicationTask?.value
    }

    private func fetchCoreRepositories() async -> Bool {
        let today = todayTargets
        let prioritized = Set(today)
        let others = Self.coreTargets.compactMap { URL(string: $0.urlStr) }.filter { !prioritized.contains($0) }
        let result = await fetchRepositories(today + others)
        catalogErrorMessage = result.error
        return result.succeeded
    }

    private func fetchRepositories(_ urls: [URL]) async -> (succeeded: Bool, error: String?) {
        let revision = XSignRemoteManager.shared.currentRevisionID
        let ownerRevision: Int? = revision > 0 ? revision : nil
        var failures: [String] = []
        var successes = 0
        let identities = Dictionary(uniqueKeysWithValues: urls.map { ($0, XSignCatalogIO.cacheIdentity($0)) })
        let io = catalogIO
        let load: @Sendable (URL) async -> (URL, XSignRepositoryRecord?, String?) = { url in
            do { return (url, try await io.fetch(url, ownerRevision: ownerRevision), nil) }
            catch { return (url, await io.cached(url), error.localizedDescription) }
        }
        await withTaskGroup(of: (URL, XSignRepositoryRecord?, String?).self) { group in
            var next = 0
            for url in urls.prefix(6) {
                next += 1
                group.addTask { await load(url) }
            }
            for await (url, record, message) in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if identities[url] == XSignCatalogIO.cacheIdentity(url) {
                    if let message {
                        sourceFailures.insert(url)
                        failures.append(message)
                        // A late disk result must not overwrite data already on screen.
                        if let record, directLoadedRepos[url.absoluteString] == nil {
                            acceptRepository(record, from: url)
                        }
                    } else if let record {
                        sourceFailures.remove(url)
                        acceptRepository(record, from: url)
                        successes += 1
                    }
                }
                if next < urls.count {
                    let url = urls[next]
                    next += 1
                    group.addTask { await load(url) }
                }
            }
        }
        return (successes == urls.count && failures.isEmpty, failures.first)
    }

    func rebuildCacheIfNeeded<S: Collection>(sources: S, repositoriesMap: [AltSource: ASRepository]) where S.Element == AltSource {
        requestedSources = Array(sources)
        rebuildCustomSnapshot(sources: requestedSources, repositories: repositoriesMap, viewModel: .shared)
    }

    private func rebuildCustomSnapshot(sources: [AltSource], repositories: [AltSource: ASRepository], viewModel: SourcesViewModel) {
        var signatures: [String: Data] = [:]
        var seen = Set<String>()
        let next: [(URL?, String?, ASRepository)] = customSources(sources).compactMap { source in
            guard let input = source.sourceURL, let repo = repositories[source] else { return nil }
            let url = XSignCatalogIO.canonicalURL(input)
            guard seen.insert(url.absoluteString).inserted else { return nil }
            signatures[url.absoluteString] = viewModel.fingerprint(for: source) ?? Data()
            return (url, source.identifier, repo)
        }
        guard signatures != customFingerprints else { return }
        customFingerprints = signatures
        customSnapshot = next
        scheduleSnapshot(priority: .userInitiated)
    }

    private func scheduleSnapshot(priority: TaskPriority) {
        var entries: [(URL?, String?, ASRepository)] = []
        for target in Self.coreTargets {
            if let repo = directLoadedRepos[target.urlStr] {
                entries.append((URL(string: target.urlStr).map(XSignCatalogIO.canonicalURL), target.id, repo))
            }
        }
        entries += customSnapshot
        indexGeneration &+= 1
        let generation = indexGeneration
        indexTask?.cancel()
        publicationTask?.cancel()
        let categories = studioCategories
        let todayIDs = todaySourceIDs
        guard !entries.isEmpty || categories?.isEmpty == false else {
            catalog = XSignCatalogSnapshot(); indexTask = nil; isPreparing = false
            catalogRevision &+= 1
            return
        }
        let input = entries
        let needsLaunchPreview = catalog.allCombinedItems.isEmpty && input.contains { $0.2.apps.count > 24 }
        isPreparing = true
        let hadVisibleItems = !catalog.allCombinedItems.isEmpty
        let worker = Task.detached(priority: priority) { [weak self] () -> XSignCatalogSnapshot? in
            if hadVisibleItems {
                // Several feeds often finish together. Keep the current rows while coalescing those rebuilds.
                do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return nil }
            }
            if needsLaunchPreview, let preview = Self.buildSnapshot(snapshot: input, studioCategories: categories,
                    todaySourceIDs: todayIDs, launchPreview: true) {
                await self?.publishLaunchPreview(preview, generation: generation)
            }
            return Self.buildSnapshot(snapshot: input, studioCategories: categories, todaySourceIDs: todayIDs)
        }
        indexTask = worker
        publicationTask = Task { @MainActor [weak self] in
            guard let next = await worker.value, !Task.isCancelled, let self, self.indexGeneration == generation else { return }
            self.catalog = next
            self.catalogRevision &+= 1
            self.isPreparing = false
            self.indexTask = nil
            self.prefetchVisibleIcons(from: next)
        }
    }

    private let iconPrefetcher = ImagePrefetcher()

    private func prefetchVisibleIcons(from snapshot: XSignCatalogSnapshot) {
        let requests = snapshot.allCombinedItems
            .prefix(36)
            .compactMap { $0.app.iconURL.flatMap(xsignImageRequest) }
        guard !requests.isEmpty else { return }
        iconPrefetcher.startPrefetching(with: requests)
    }

    private func publishLaunchPreview(_ preview: XSignCatalogSnapshot, generation: UInt64) {
        guard !Task.isCancelled, indexGeneration == generation, catalog.allCombinedItems.isEmpty,
              !preview.allCombinedItems.isEmpty else { return }
        catalog = preview
        catalogRevision &+= 1
        prefetchVisibleIcons(from: preview)
    }

    private nonisolated static func launchApps(in repo: ASRepository, scanLimit: Int? = nil) -> [ASRepository.App] {
        var games: [ASRepository.App] = []
        var apps: [ASRepository.App] = []
        let candidates = repo.apps.prefix(scanLimit ?? repo.apps.count)
        for app in candidates {
            if Task.isCancelled { return [] }
            let isGame = AppStore2026Category.declaredKind(app: app, categories: repo.categories ?? [])
                ?? XSignCatalogKindPolicy.recognizesGame(name: app.currentName, bundleID: app.id)
            if isGame {
                if games.count < 12 { games.append(app) }
            } else if apps.count < 12 { apps.append(app) }
            if apps.count == 12 && games.count == 12 { break }
        }
        var selected = apps + games
        if selected.count < 24 {
            let used = Set(selected.map { $0.stableCatalogIdentifier })
            selected += candidates.lazy.filter { !used.contains($0.stableCatalogIdentifier) }.prefix(24 - selected.count)
        }
        return selected
    }

    private nonisolated static func makeLaunchPreview(_ repo: ASRepository) -> Data? {
        let page = launchApps(in: repo).map { app -> [String: Any] in
            var item: [String: Any] = ["name": app.currentName]
            item["bundleIdentifier"] = app.id
            item["catalogID"] = app.catalogID
            item["downloadURL"] = app.currentDownloadUrl?.absoluteString
            item["iconURL"] = app.iconURL?.absoluteString
            item["version"] = app.currentVersion
            item["size"] = app.size
            item["category"] = app.category
            item["categories"] = app.categoryReferences
            item["artworkURL"] = app.artworkURL?.absoluteString
            item["screenshotURLs"] = app.screenshotURLs?.prefix(4).map(\.absoluteString)
            item["isGame"] = app.isGame
            item["skipAppStoreLookup"] = app.skipAppStoreLookup
            item["developerName"] = app.developer
            item["subtitle"] = app.subtitle.map { String($0.prefix(200)) }
            item["localizedDescription"] = app.localizedDescription.map { String($0.prefix(800)) }
            return item
        }
        var root: [String: Any] = ["apps": page]
        root["name"] = repo.name
        root["identifier"] = repo.id
        root["subtitle"] = repo.subtitle
        root["iconURL"] = repo.iconURL?.absoluteString
        root["featuredApps"] = repo.featuredApps.map { Array($0.prefix(32)) }
        if let categories = repo.categories, let encoded = try? JSONEncoder().encode(categories) {
            root["categories"] = try? JSONSerialization.jsonObject(with: encoded)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root), data.count <= 131_072 else { return nil }
        return data
    }

    private nonisolated static func buildSnapshot(snapshot: [(URL?, String?, ASRepository)],
                                                  studioCategories: [ASRepository.CatalogCategory]?,
                                                  todaySourceIDs: Set<String>? = nil,
                                                  launchPreview: Bool = false) -> XSignCatalogSnapshot? {
        if Task.isCancelled { return nil }
        let ownerRepoDefinitions = snapshot.first(where: {
            ProtectedSourcesVault.isIPABlackSource($0.0, identifier: $0.1)
        })?.2.categories ?? []
        let configured = studioCategories ?? []
        let configuredKeys = Set(configured.compactMap { XSignCatalogKindPolicy.categoryKey($0.id) })
        let ownerDefinitions = configured + ownerRepoDefinitions.filter { definition in
            XSignCatalogKindPolicy.categoryKey(definition.id).map { !configuredKeys.contains($0) } ?? false
        }
        let studioTaxonomy = XSignCategoryLookup(configured.isEmpty ? ownerDefinitions : configured)
        let totalCount = snapshot.reduce(0) { count, source in
            count + (launchPreview ? min(24, source.2.apps.count) : source.2.apps.count)
        }
        var allItems: [AppStoreAppItem] = []
        var ipaBlackOnly: [AppStoreAppItem] = []
        var ipaBlackNews: [TodayEditorialInstruction] = []
        var didIncludeIPABlackRepo = false
        var todayGroups: [[AppStoreAppItem]] = []
        var todayNews: [TodayEditorialInstruction] = []
        var todayCategories: [ASRepository.CatalogCategory] = []
        var sourceCategories: [ASRepository.CatalogCategory] = []
        var todayFeaturedBySource: [URL: [String]] = [:]

		allItems.reserveCapacity(totalCount)

		for (sourceURL, sourceID, repo) in snapshot {
			let isIPABlack = ProtectedSourcesVault.isIPABlackSource(sourceURL, identifier: sourceID)
            let isTodaySource = XSignTodaySourcePolicy.allows(id: sourceID, url: sourceURL, selected: todaySourceIDs)
            let appSourceName = isIPABlack ? "IPA BLACK" : (sourceID == XSignCatalogueEndpoint.primaryID ? "IPA SOON" : repo.name)
            if isIPABlack { didIncludeIPABlackRepo = true }
            let definitions = repo.categories ?? []
            let taxonomy = XSignCategoryLookup(definitions)
            let visibleDefinitions = isIPABlack ? ownerDefinitions : definitions
            sourceCategories += visibleDefinitions
            if isTodaySource { todayCategories += visibleDefinitions }
            let sourceURLString = sourceURL?.absoluteString ?? ""

			var currentRepoItems: [AppStoreAppItem] = []
            let apps = launchPreview ? launchApps(in: repo, scanLimit: 96) : repo.apps
            currentRepoItems.reserveCapacity(apps.count)

            for (index, app) in apps.enumerated() {
                if index.isMultiple(of: 64) && Task.isCancelled { return nil }
                let uniqueKey = sourceURLString + "\u{1F}" + app.catalogRowKey
                let item = AppStoreAppItem(id: uniqueKey, sourceURL: sourceURL, sourceName: appSourceName, taxonomy: taxonomy,
                    studioTaxonomy: studioTaxonomy, ownsCategory: isIPABlack, app: app)
				if isIPABlack || isTodaySource {
					currentRepoItems.append(item)
				}
                allItems.append(item)
			}

			if isIPABlack { ipaBlackOnly.append(contentsOf: currentRepoItems) }
            if isTodaySource {
                todayGroups.append(currentRepoItems)
                let features = (repo.featuredApps ?? []).compactMap { $0 }
                if let sourceURL, !features.isEmpty { todayFeaturedBySource[sourceURL] = features }

            }
            if isTodaySource || isIPABlack {
                var sourceNews: [TodayEditorialInstruction] = []
                if !launchPreview, let newsList = repo.news, !newsList.isEmpty {
                    let byCatalogID = Dictionary(currentRepoItems.compactMap { item in
                        item.app.catalogID.map { ($0, item) }
                    }, uniquingKeysWith: { first, _ in first })
                    let byBundle = Dictionary(grouping: currentRepoItems) { XSignCatalogKindPolicy.bundleKey($0.app.id) ?? "" }
                    var newsIDs = Set<String>()
                    for newsItem in newsList where newsIDs.insert(newsItem.id).inserted {
                        let matchedApp = newsItem.appID.flatMap { reference -> AppStoreAppItem? in
                            if let exact = byCatalogID[reference] { return exact }
                            let parts = reference.components(separatedBy: "||")
                            guard let bundle = XSignCatalogKindPolicy.bundleKey(parts.first) else { return nil }
                            let matches = byBundle[bundle] ?? []
                            guard parts.count == 2 else { return matches.first }
                            let title = XSignSearchDocument.normalize(parts[1])
                            if let match = matches.first(where: { $0.searchDocument.name == title }) { return match }
                            if matches.count == 1 { return matches.first }
                            if matches.isEmpty, let dot = bundle.lastIndex(of: "."), Int(bundle[bundle.index(after: dot)...]) != nil {
                                return byBundle[String(bundle[..<dot])]?.first { $0.searchDocument.name == title }
                            }
                            return nil
                        }

						sourceNews.append(
							TodayEditorialInstruction(
								id: sourceURLString + "#" + newsItem.id,
								badge: newsItem.badge ?? (newsItem.notify ? "تنبيه" : nil),
								title: newsItem.title,
								caption: newsItem.caption,
								imageURL: newsItem.imageURL,
								tintColor: newsItem.tintColor ?? AppStoreTheme.oceanBlue,
								associatedApp: matchedApp,
                                targetURL: xsignSafeURL(newsItem.url?.absoluteString),
                                sourceURL: sourceURL
							)
						)
					}
				}
                if isIPABlack { ipaBlackNews += sourceNews }
                if isTodaySource { todayNews += sourceNews }
			}
		}

        let categorized = AppStoreAppItem.combined(allItems)
        let catalogueByID = Dictionary(uniqueKeysWithValues: categorized.map { ($0.id, $0) })
        let onlyApps = categorized.filter { XSignCatalogKindPolicy.showsInPage("apps", isGame: $0.isGame) }
        let onlyGames = categorized.filter { XSignCatalogKindPolicy.showsInPage("games", isGame: $0.isGame) }

		// Keep curated Today content separate from the complete catalogue.
		let finalIPABlack = AppStoreAppItem.combined(ipaBlackOnly)
		let finalAll = categorized
		let finalApps = onlyApps
		let finalGames = onlyGames
		let shouldUpdateIPABlack = didIncludeIPABlackRepo

        if Task.isCancelled { return nil }
        let visibleToday = AppStoreAppItem.combined(XSignTodaySourcePolicy.interleave(todayGroups)).map { item in
            catalogueByID[item.id].map { item.placed(inGames: $0.isGame) } ?? item
        }
        let todayByID = Dictionary(uniqueKeysWithValues: visibleToday.map { ($0.id, $0) })
        func mappedNews(_ entries: [TodayEditorialInstruction], to apps: [String: AppStoreAppItem]) -> [TodayEditorialInstruction] {
            entries.map { entry in
                .init(id: entry.id, badge: entry.badge, title: entry.title, caption: entry.caption,
                    imageURL: entry.imageURL, tintColor: entry.tintColor,
                    associatedApp: entry.associatedApp.flatMap { apps[$0.catalogueKey] },
                    targetURL: entry.targetURL, sourceURL: entry.sourceURL)
            }
        }
        let appCategories = XSignStoreCategory.groups(finalApps, studio: ownerDefinitions.filter { $0.isGame != true },
            sourceCategories: sourceCategories, legacy: [.social, .photoVideo, .mediaReaders, .devTools, .visualArts, .productivity])
        let gameCategories = XSignStoreCategory.groups(finalGames, studio: ownerDefinitions.filter { $0.isGame == true },
            sourceCategories: sourceCategories, legacy: [.pvpGames, .simulationGames, .strategyGames, .puzzleGames, .casualGames])
        let searchCategories = XSignStoreCategory.groups(finalAll, studio: ownerDefinitions,
            sourceCategories: sourceCategories, legacy: [.social, .photoVideo, .mediaReaders, .devTools, .visualArts, .productivity,
                .pvpGames, .simulationGames, .strategyGames, .puzzleGames, .casualGames])
        let todayCategoryGroups = XSignStoreCategory.groups(visibleToday, studio: ownerDefinitions,
            sourceCategories: todayCategories, legacy: [])
        if Task.isCancelled { return nil }
        return XSignCatalogSnapshot(
            ipablackItems: finalIPABlack,
            ipablackEditorialNews: mappedNews(ipaBlackNews, to: catalogueByID),
            allCombinedItems: finalAll,
            pureAppsOnly: finalApps,
            pureGamesOnly: finalGames,
            includesIPABlack: shouldUpdateIPABlack,
            skippedLookupBundleIDs: Set(finalAll.filter { $0.app.skipAppStoreLookup == true }.compactMap { $0.app.id }),
            todayItems: visibleToday, todayNews: mappedNews(todayNews, to: todayByID),
            todayFeaturedBySource: todayFeaturedBySource,
            appCategories: appCategories, gameCategories: gameCategories, searchCategories: searchCategories,
            todayCategoryGroups: todayCategoryGroups
        )
    }
}

// MARK: - Serial FIFO download queue
struct XSignSerialQueue<Element> {
    struct Entry {
        let key: String
        let value: Element
    }
    private var waiting: [Entry?] = []
    private var head = 0
    private var registered: Set<String> = []
    private(set) var active: Entry? = nil
    var pendingCount: Int { registered.count - (active == nil ? 0 : 1) }

    init() {}

    mutating func enqueue(key: String, value: Element) -> Bool {
        guard registered.insert(key).inserted else { return false }
        waiting.append(Entry(key: key, value: value))
        return true
    }

    mutating func next() -> Entry? {
        guard case nil = active else { return nil }
        while head < waiting.count && waiting[head] == nil { head += 1 }
        guard head < waiting.count, let entry = waiting[head] else {
            waiting.removeAll(keepingCapacity: true)
            head = 0
            return nil
        }
        waiting[head] = nil
        head += 1
        if head == waiting.count {
            waiting.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64 && head >= waiting.count / 2 {
            waiting.removeFirst(head)
            head = 0
        }
        active = entry
        return entry
    }

    @discardableResult
    mutating func finish(key: String) -> Bool {
        guard active?.key == key else { return false }
        registered.remove(key)
        active = nil
        return true
    }

    mutating func removeWaiting(key: String) -> Bool {
        guard let position = waiting.indices.dropFirst(head).first(where: { waiting[$0]?.key == key }) else { return false }
        waiting[position] = nil
        registered.remove(key)
        if pendingCount == 0 {
            waiting.removeAll(keepingCapacity: true)
            head = 0
        }
        return true
    }
}

// MARK: - Bounded download and signing pipeline
// The network may download the next IPA while the previous IPA is processed.
// Only one network stream and one file on deck are allowed; payloads stay on disk.
struct XSignBoundedPipeline<Job, File> {
    struct Prepared {
        let key: String
        let job: Job
        let file: File
    }
    private var downloads = XSignSerialQueue<Job>()
    private var registered: Set<String> = []
    private(set) var staged: Prepared? = nil
    private(set) var processing: Prepared? = nil
    var activeDownload: XSignSerialQueue<Job>.Entry? { downloads.active }
    var pendingCount: Int { downloads.pendingCount }
    var canStartDownload: Bool {
        if case nil = activeDownload, case nil = staged { return pendingCount > 0 }
        return false
    }
    var inFlightCount: Int {
        (activeDownload.map { _ in 1 } ?? 0) + (staged.map { _ in 1 } ?? 0) + (processing.map { _ in 1 } ?? 0)
    }
    mutating func enqueue(key: String, job: Job) -> Bool {
        guard registered.insert(key).inserted else { return false }
        guard downloads.enqueue(key: key, value: job) else {
            registered.remove(key)
            return false
        }
        return true
    }
    mutating func takeDownload() -> XSignSerialQueue<Job>.Entry? {
        guard canStartDownload else { return nil }
        return downloads.next()
    }
    mutating func completeDownload(key: String, file: File) -> Bool {
        guard let entry = activeDownload, entry.key == key, case nil = staged,
              downloads.finish(key: key) else { return false }
        staged = Prepared(key: key, job: entry.value, file: file)
        return true
    }
    mutating func failDownload(key: String) -> Bool {
        guard downloads.finish(key: key) else { return false }
        registered.remove(key)
        return true
    }
    mutating func cancelWaiting(key: String) -> File? {
        if let staged, staged.key == key {
            self.staged = nil
            registered.remove(key)
            return staged.file
        }
        if downloads.removeWaiting(key: key) { registered.remove(key) }
        return nil
    }
    mutating func takeProcessing() -> Prepared? {
        guard case nil = processing, let next = staged else { return nil }
        staged = nil
        processing = next
        return next
    }
    mutating func finishProcessing(key: String) -> Bool {
        guard processing?.key == key else { return false }
        processing = nil
        registered.remove(key)
        return true
    }
}

// Collapse byte-level KVO callbacks before they enqueue work on the UI actor.
final class XSignDownloadProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var greatest = -1
    private var lastPublication: UInt64?
    func shouldPublish(_ percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard percent > greatest else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        if let lastPublication, now - lastPublication < 100_000_000 { return false }
        greatest = percent
        lastPublication = now
        return true
    }
}

// MARK: - Universal IPABlack & KhoIPA Payload Extractor + Instant ZSign
@MainActor
final class AutoSignPipelineManager: ObservableObject {
	static let shared = AutoSignPipelineManager()

	@Published var activeStates: [String: Stage] = [:]
	private var downloadProgress: [String: CurrentValueSubject<Int, Never>] = [:]

    func progressPublisher(for key: String) -> AnyPublisher<Int, Never>? {
        downloadProgress[key]?.removeDuplicates().eraseToAnyPublisher()
    }
    @Published var showCertificateSetup = false
    private struct DownloadRequest {
        let app: ASRepository.App
        let url: URL
        let provenance: SourceAppProvenance?
    }
    private var pendingCertificateDownloads: [DownloadRequest] = []
    private var packagePipeline = XSignBoundedPipeline<DownloadRequest, URL>()
    private var activeNetworkTask: URLSessionDownloadTask?
    private var activeImportTask: Task<Void, Never>?
    private var activeAttempt: UUID?
    private var protectedTransfers: [String: UUID] = [:]
    private var isCheckingDownloadPolicy = false
    private var abortingTransferQueue = false
    private var downloadPreflightBlocked = false

	enum Stage: Equatable {
        case queued
        case failed(String)
        case preparing
		case downloading
		case signing
		case ready
	}

	private var cachedCertificate: CertificatePair? = nil
	private var progressObservations: [String: NSKeyValueObservation] = [:]

	private lazy var turboSession: URLSession = {
		let config = URLSessionConfiguration.default
		config.networkServiceType = .default
		config.httpMaximumConnectionsPerHost = 1
		config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
		config.requestCachePolicy = .reloadIgnoringLocalCacheData
		config.urlCache = nil
		return URLSession(configuration: config, delegate: XSignCatalogRedirects(), delegateQueue: nil)
	}()

	init() {
		refreshCertificateCache()
	}

	func refreshCertificateCache() {
		cachedCertificate = Self.fetchActiveCertificate()
	}

	nonisolated static func prewarmInfoPlist(for app: Imported) {
		prewarmAndNormalizePayload(for: app)
	}

	nonisolated static func prewarmAndNormalizePayload(for app: Imported) {
		guard let uuid = app.uuid else { return }
		let unsignedDir = FileManager.default.unsigned.appendingPathComponent(uuid)

		guard let enumerator = FileManager.default.enumerator(
			at: unsignedDir,
			includingPropertiesForKeys: [.isDirectoryKey],
			options: [.skipsHiddenFiles]
		) else { return }

		for case let fileURL as URL in enumerator {
			if fileURL.pathExtension == "app" {
				let infoPlistURL = fileURL.appendingPathComponent("Info.plist")
				if let plist = NSDictionary(contentsOf: infoPlistURL) {
					_ = plist["CFBundleExecutable"]
					_ = plist["CFBundleIdentifier"]
				}
				break
			}
		}
	}

    func downloadAndAutoSign(app: ASRepository.App, provenance: SourceAppProvenance?) {
        let security = XSignSecurityEnforcer.shared
        security.evaluateNetworkSecurity()
        if let reason = security.packageNetworkFailure ?? XSignRemoteManager.shared.blockingReason {
            security.reportInstallationFailure(reason)
            return
        }
        let key = app.downloadKey
        if let state = activeStates[key] {
            guard case .failed = state else { return }
        }
        guard let url = app.currentDownloadUrl.flatMap({ XSignManagedSource.httpsURL($0.absoluteString) }) else {
            activeStates[key] = .failed("رابط التنزيل غير صالح.")
            return
        }
        let request = DownloadRequest(app: app, url: url, provenance: provenance)
        guard Self.fetchActiveCertificate() != nil else {
            if !pendingCertificateDownloads.contains(where: { $0.app.downloadKey == key }) {
                pendingCertificateDownloads.append(request)
            }
            showCertificateSetup = true
            return
        }
        downloadPreflightBlocked = false
        guard packagePipeline.enqueue(key: key, job: request) else { return }
        activeStates[key] = .queued
        protectedTransfers[key] = security.startProtectedTransfer { [weak self] reason in
            self?.stopDownload(key: key, reason: reason)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        startNextDownload()
    }

    func resumeAfterCertificateSetup() {
        let pending = pendingCertificateDownloads
        pendingCertificateDownloads = []
        refreshCertificateCache()
        guard cachedCertificate != nil else { return }
        for request in pending { downloadAndAutoSign(app: request.app, provenance: request.provenance) }
    }

    func applyRemotePolicy() {
        if let reason = XSignRemoteManager.shared.blockingReason {
            activeNetworkTask?.cancel()
            if let key = packagePipeline.processing?.key, let activeImportTask {
                activeStates[key] = .failed(reason)
                activeImportTask.cancel()
            }
        } else {
            downloadPreflightBlocked = false
            startNextProcessing()
            startNextDownload()
        }
    }

    private func startNextDownload() {
        guard packagePipeline.canStartDownload, !isCheckingDownloadPolicy, !downloadPreflightBlocked, !abortingTransferQueue,
              XSignRemoteManager.shared.blockingReason == nil else { return }
        isCheckingDownloadPolicy = true
        Task { @MainActor in
            let reason = await XSignRemoteManager.shared.prepareProtectedOperation()
            isCheckingDownloadPolicy = false
            if let reason {
                downloadPreflightBlocked = true
                if let entry = packagePipeline.takeDownload() { failNetworkDownload(key: entry.key, message: reason) }
                return
            }
            beginNextDownload()
        }
    }

    private func beginNextDownload() {
        guard XSignRemoteManager.shared.blockingReason == nil, !abortingTransferQueue,
              let entry = packagePipeline.takeDownload() else { return }
        let key = entry.key
        let url = entry.value.url
        downloadProgress[key] = CurrentValueSubject(0)
        activeStates[key] = .downloading
        let attempt = UUID()
        activeAttempt = attempt
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("X-SIGN/2.0", forHTTPHeaderField: "User-Agent")
        Task { @MainActor in
            do {
                let approved = try XSignCatalogueEndpoint.packageRequest(request)
                XSignSecurityEnforcer.shared.evaluateNetworkSecurity()
                guard self.activeAttempt == attempt else { return }
                if let reason = XSignRemoteManager.shared.blockingReason {
                    self.failNetworkDownload(key: key, message: reason)
                    return
                }
                self.startTransfer(approved, key: key, attempt: attempt)
            } catch {
                guard self.activeAttempt == attempt else { return }
                self.failNetworkDownload(key: key, message: error.localizedDescription)
            }
        }
    }

    private func startTransfer(_ request: URLRequest, key: String, attempt: UUID) {
        let task = turboSession.downloadTask(with: request) { [weak self] location, response, error in
            guard let self else { return }
            guard error == nil, let location,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Task { @MainActor in
                    guard self.activeAttempt == attempt else { return }
                    self.failNetworkDownload(key: key, message: error?.localizedDescription ?? "تعذّر تنزيل التطبيق من الخادم.")
                }
                return
            }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("XSignQueue_\(UUID().uuidString).ipa")
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
                guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                    throw NSError(domain: "XSign.Download", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "الملف الذي نزله الخادم فارغ."])
                }
                guard size.int64Value <= XSignIPAExtractor.maximumArchiveBytes else {
                    throw XSignIPAExtractor.InvalidArchive.tooLarge
                }
                try FileManager.default.moveItem(at: location, to: file)
            } catch {
                try? FileManager.default.removeItem(at: file)
                Task { @MainActor in
                    guard self.activeAttempt == attempt else { return }
                    self.failNetworkDownload(key: key, message: error.localizedDescription)
                }
                return
            }
            Task { @MainActor in self.receivedPackage(file, key: key, attempt: attempt) }
        }
        let progressGate = XSignDownloadProgressGate()
        progressObservations[key] = task.progress.observe(\Progress.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            guard fraction.isFinite else { return }
            let percent = Int(max(0, min(99, fraction * 100)))
            guard progressGate.shouldPublish(percent) else { return }
            Task { @MainActor in
                guard let self, self.activeAttempt == attempt, self.activeStates[key] == .downloading else { return }
                self.downloadProgress[key]?.send(percent)
            }
        }
        activeNetworkTask = task
        task.priority = URLSessionTask.highPriority
        task.resume()
    }

    private func receivedPackage(_ file: URL, key: String, attempt: UUID) {
        XSignSecurityEnforcer.shared.evaluateNetworkSecurity()
        guard activeAttempt == attempt, packagePipeline.activeDownload?.key == key else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        if let reason = XSignRemoteManager.shared.blockingReason {
            try? FileManager.default.removeItem(at: file)
            failNetworkDownload(key: key, message: reason)
            return
        }
        guard packagePipeline.completeDownload(key: key, file: file) else {
            try? FileManager.default.removeItem(at: file)
            failNetworkDownload(key: key, message: "تعذّر إدراج الملف في طابور التجهيز.")
            return
        }
        activeNetworkTask = nil
        activeAttempt = nil
        progressObservations.removeValue(forKey: key)
        downloadProgress.removeValue(forKey: key)
        activeStates[key] = .preparing
        // These two lanes overlap without opening a second simultaneous download.
        startNextProcessing()
        startNextDownload()
    }

    private func startNextProcessing() {
        guard XSignRemoteManager.shared.blockingReason == nil, !abortingTransferQueue,
              let entry = packagePipeline.takeProcessing() else { return }
        let key = entry.key
        let file = entry.file
        activeStates[key] = .preparing
        refreshCertificateCache()
        activeImportTask = FR.importPackageFile(file, sourceProvenance: entry.job.provenance,
                                                consumeTemporaryFile: true) { [weak self] result in
            try? FileManager.default.removeItem(at: file)
            guard let self else { return }
            self.activeImportTask = nil
            if case .failed(let reason) = self.activeStates[key] {
                if case .success(let uuid) = result { Storage.shared.deleteInterruptedImport(uuid: uuid) }
                self.finishDownload(key: key, error: reason)
                return
            }
            switch result {
            case .failure(let error):
                self.finishDownload(key: key, error: error.localizedDescription)
            case .success(let uuid):
                let request = NSFetchRequest<Imported>(entityName: "Imported")
                request.fetchLimit = 1
                request.predicate = NSPredicate(format: "uuid == %@", uuid)
                guard let imported = (try? Storage.shared.context.fetch(request))?.first else {
                    self.finishDownload(key: key, error: "تعذّر العثور على التطبيق المستورد.")
                    return
                }
                self.triggerInstantZSign(for: imported, appKey: key)
            }
        }
    }

    private func failNetworkDownload(key: String, message: String) {
        guard packagePipeline.failDownload(key: key) else { return }
        activeNetworkTask = nil
        activeAttempt = nil
        progressObservations.removeValue(forKey: key)
        downloadProgress.removeValue(forKey: key)
        activeStates[key] = .failed(message)
        XSignSecurityEnforcer.shared.finishProtectedTransfer(protectedTransfers.removeValue(forKey: key))
        startNextProcessing()
        startNextDownload()
    }

    private func finishDownload(key: String, error: String?) {
        guard packagePipeline.finishProcessing(key: key) else { return }
        if let error { activeStates[key] = .failed(error) }
        XSignSecurityEnforcer.shared.finishProtectedTransfer(protectedTransfers.removeValue(forKey: key))
        startNextProcessing()
        startNextDownload()
    }

    private func stopDownload(key: String, reason: String) {
        abortingTransferQueue = true
        defer { abortingTransferQueue = false }
        protectedTransfers[key] = nil
        if packagePipeline.activeDownload?.key == key {
            activeNetworkTask?.cancel()
            failNetworkDownload(key: key, message: reason)
        } else {
            if packagePipeline.processing?.key == key { activeImportTask?.cancel() }
            if let file = packagePipeline.cancelWaiting(key: key) { try? FileManager.default.removeItem(at: file) }
            activeStates[key] = .failed(reason)
        }
    }

    func triggerInstantZSign(for importedApp: Imported, appKey: String) {
        guard let cert = Self.fetchActiveCertificate() else {
            finishDownload(key: appKey, error: "تم الاستيراد. أضف شهادة من الإعدادات للتوقيع.")
            return
        }
        activeStates[appKey] = .signing
        var options = OptionsManager.shared.options
        options.signingOption = .default
        FR.signPackageFileWithResult(importedApp, using: options, icon: nil, certificate: cert) { [weak self] result in
            guard let self else { return }
            XSignSecurityEnforcer.shared.evaluateNetworkSecurity()
            if case .failed(let reason) = self.activeStates[appKey] {
                self.finishDownload(key: appKey, error: reason)
                return
            }
            switch result {
            case .failure(let error):
                self.finishDownload(key: appKey, error: error.localizedDescription)
            case .success(let uuid):
                let request = NSFetchRequest<Signed>(entityName: "Signed")
                request.fetchLimit = 1
                request.predicate = NSPredicate(format: "uuid == %@", uuid)
                guard let signed = (try? Storage.shared.context.fetch(request))?.first else {
                    self.finishDownload(key: appKey, error: "تعذّر العثور على التطبيق الموقّع.")
                    return
                }
                self.activeStates[appKey] = .ready
                XSignInstallation.shared.install(signed, afterDismissal: true)
                self.finishDownload(key: appKey, error: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    if self?.activeStates[appKey] == .ready { self?.activeStates[appKey] = nil }
                }
            }
        }
    }

	nonisolated static func fetchImportedApps() -> [Imported] {
		let request = NSFetchRequest<Imported>(entityName: "Imported")
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Imported.date, ascending: false)]
		request.fetchLimit = 5
		return (try? Storage.shared.context.fetch(request)) ?? []
	}

    nonisolated static func fetchSignedApp(uuid: String) -> Signed? {
        let request = NSFetchRequest<Signed>(entityName: "Signed")
        request.predicate = NSPredicate(format: "uuid == %@", uuid)
        request.fetchLimit = 1
        return (try? Storage.shared.context.fetch(request))?.first
    }

	nonisolated static func fetchActiveCertificate() -> CertificatePair? {
        Storage.shared.activeSigningCertificate()
	}
}

// MARK: - Authentic App Store 2026 Detail View (Hides Screenshots if App is Removed from App Store)
struct AppStore2026DetailView: View {
    let item: AppStoreAppItem
    var body: some View { XSignAppStoreProductPage(item: item) }
}

struct AppStoreStatBadge: View {
	let topTitle: String
	let mainValue: String
	let bottomText: String

	var body: some View {
		VStack(spacing: 4) {
			Text(xsignText(topTitle))
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(.secondary)
			Text(mainValue)
				.font(.system(size: 20, weight: .heavy, design: .rounded))
				.foregroundStyle(Color.primary.opacity(0.9))
			Text(xsignText(bottomText))
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.frame(width: 92)
	}
}

struct AppStoreInfoRow: View {
	let label: String
	let value: String

	var body: some View {
		VStack(spacing: 10) {
			HStack {
				Text(xsignText(label))
					.font(.system(size: 14))
					.foregroundStyle(.secondary)
				Spacer()
				Text(value)
					.font(.system(size: 14, weight: .medium))
					.foregroundStyle(.primary)
					.lineLimit(1)
			}
			Divider().background(Color.primary.opacity(0.08))
		}
	}
}

// MARK: - Today
struct AppStoreTodayView: View {
    @StateObject private var cache = AppStoreCacheManager.shared
    @ObservedObject private var sourcesViewModel = SourcesViewModel.shared
    @State private var showSettingsSheet = false
    @ObservedObject private var remote = XSignRemoteManager.shared
    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)])
    private var sources: FetchedResults<AltSource>

    private var dashboard: XSignDashboardConfig? { remote.config?.dashboard }
    private var showsDefaultEmptyState: Bool {
        let sections = dashboard?.sections(for: "today") ?? XSignDashboardConfig.defaultSections.filter { $0.page == "today" }
        return cache.todayItems.isEmpty && !(sections.contains { $0.kind == "news" } && !cache.todayEditorialNews.isEmpty) &&
            sections.contains { ["featured", "apps"].contains($0.kind) }
    }

    var body: some View {
        XSignNavigationView {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    AppStore2026TopHeader(title: "اليوم", onSettingsTap: { showSettingsSheet = true },
                        date: dashboard?.today_show_date != false ? Date() : nil,
                        showsAccount: dashboard?.today_show_account != false, horizontalInset: 0)

                    XSignClassicStoreContent(page: "today")
                    if showsDefaultEmptyState {
                        AppStore2026EmptyState(isLoading: cache.isRefreshingToday || cache.isRefreshing || cache.isPreparing,
                            emptyMessage: cache.todayEmptyMessage,
                            retry: { Task { await cache.refreshToday() } })
                    }
                }.padding(.horizontal, 20).padding(.bottom, 110)
            }
            .xsignPageBackground()
            .navigationBarHidden(true)
            .refreshable { await cache.refreshToday() }
            .sheet(isPresented: $showSettingsSheet, onDismiss: { XSignInstallation.shared.resumeIfPossible() }) {
                AppStore2026SettingsPopup()
            }
        }

        .task(id: sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            await cache.ensureFetched(sources: sources, viewModel: sourcesViewModel)
        }
    }
}

struct XSignTodayFeatureCard: View {
    let item: AppStoreAppItem?
    let title: String
    let caption: String
    let badge: String?
    let artwork: URL?
    let tint: Color?
    var targetURL: URL? = nil
    var showsDownload = true
    var compact = false

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 32.0
    private let shape = RoundedRectangle(cornerRadius: 23, style: .continuous)
    private var cardColor: Color { tint ?? Color.accentColor }
    private var artURL: URL? {
        [artwork, item?.app.artworkURL, item?.screenshots.first].compactMap { $0 }
            .first { XSignManagedSource.httpsURL($0.absoluteString) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let targetURL {
                Link(destination: targetURL) { artworkContent }.buttonStyle(.plain)
            } else if let item {
                NavigationLink { AppStore2026DetailView(item: item) } label: { artworkContent }.buttonStyle(.plain)
            } else {
                artworkContent
            }

            if let item {
                HStack(spacing: 10) {
                    NavigationLink { AppStore2026DetailView(item: item) } label: {
                        HStack(spacing: 10) {
                            AppStoreIconView(url: item.app.iconURL, bundleID: item.app.id,
                                appName: item.app.currentName, size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.app.currentName).font(.headline).foregroundStyle(.white).lineLimit(1)
                                Text(xsignText(item.arabicSubtitle)).font(.subheadline).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.buttonStyle(.plain)
                    if showsDownload {
                        AppStore2026DownloadButton(app: item.app, provenance: item.downloadProvenance(), onArtwork: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(Color.black.opacity(0.13))
            }
        }
        .frame(maxWidth: .infinity)
        .background { ZStack { Color.black; cardColor.opacity(0.58) } }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.13), lineWidth: 1).allowsHitTesting(false) }
    }

    private var artworkContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let badge, !badge.isEmpty {
                Text(xsignText(badge)).font(.caption.weight(.bold))
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(.black.opacity(0.44), in: Capsule())
            }
            Spacer(minLength: compact ? 38 : 82)
            Text(xsignText(title)).font(.system(size: compact ? titleSize * 0.77 : titleSize, weight: .heavy))
                .lineLimit(3).accessibilityAddTraits(.isHeader)
            if !caption.isEmpty {
                Text(xsignText(caption)).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.83)).lineLimit(3)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: !compact && (artURL != nil || item != nil) ? 334 : 174, alignment: .leading)
        .background {
            GeometryReader { proxy in
                ZStack {
                    if let artURL {
                        LazyImage(request: xsignImageRequest(artURL)) { state in
                            if let image = state.image {
                                image.resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                            } else { iconArtwork }
                        }
                        .processors([.resize(size: CGSize(width: 840, height: 840))])
                    } else { iconArtwork }
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.27),
                        .init(color: cardColor.opacity(0.53), location: 0.67),
                        .init(color: .black.opacity(0.76), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var iconArtwork: some View {
        if let item {
            AppStoreIconView(url: item.app.iconURL, bundleID: item.app.id, appName: item.app.currentName, size: compact ? 62 : 116)
                .rotationEffect(.degrees(-8))
                .shadow(color: .black.opacity(0.35), radius: 15, y: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, compact ? 17 : 42)
        } else {
            LinearGradient(colors: [cardColor.opacity(0.6), .black.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Apps and games
struct SourcesView: View {
    var body: some View { XSignStoreCataloguePage(page: "apps") }
}

struct AppStoreGamesView: View {
    var body: some View { XSignStoreCataloguePage(page: "games") }
}

private struct XSignStoreCataloguePage: View {
    let page: String
    private let viewModel = SourcesViewModel.shared
    @ObservedObject private var cache = AppStoreCacheManager.shared
    @ObservedObject private var remote = XSignRemoteManager.shared
    @State private var showSettings = false
    @State private var selection: String?
    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)])
    private var sources: FetchedResults<AltSource>

    private var games: Bool { page == "games" }
    var body: some View {
        let configured = remote.config?.dashboard?.sections ?? XSignDashboardConfig.defaultSections
        let categorySection = configured.first { $0.page == page && $0.kind == "categories" && $0.enabled != false }
        let hasExplicitCategorySetting = configured.contains { $0.page == page && $0.kind == "categories" }
        let categories = (categorySection.map { cache.categories(for: page, section: $0) }
            ?? (hasExplicitCategorySetting ? [] : cache.categories(for: page))).filter { !$0.items.isEmpty }
        let selected = categories.first { $0.id == selection }
        let allItems = games ? cache.pureGamesOnly : cache.pureAppsOnly
        XSignNavigationView {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    AppStore2026TopHeader(title: games ? "الألعاب" : "التطبيقات", onSettingsTap: { showSettings = true })
                    if !categories.isEmpty {
                        XSignStoreCategoryBar(title: categorySection?.title ?? (games ? "أقسام الألعاب" : "أقسام التطبيقات")) {
                            Button { selection = nil } label: {
                                XSignStoreCategoryPill(title: "الكل", symbol: "square.grid.2x2", isSelected: selected == nil)
                            }.buttonStyle(.plain)
                            ForEach(categories) { category in
                                Button { selection = category.id } label: {
                                    XSignStoreCategoryPill(title: category.title, symbol: category.symbol,
                                        svg: category.iconSVG, isSelected: selected?.id == category.id)
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                    let visibleItems = selected?.items ?? allItems
                    XSignClassicStoreContent(page: page, completeItems: visibleItems, showsCategories: false, categoryID: selected?.id)
                        .padding(.horizontal, 18)
                    if visibleItems.isEmpty {
                        AppStore2026EmptyState(isLoading: !cache.hasLoadedCatalog || cache.isPreparing,
                            emptyMessage: games ? "لا توجد ألعاب متاحة الآن." : "لا توجد تطبيقات متاحة الآن.")
                    }
                }.padding(.bottom, 100)
            }
            .xsignPageBackground()
            .navigationBarHidden(true)
            .refreshable { await cache.forceRefresh(sources: sources, viewModel: viewModel) }
            .sheet(isPresented: $showSettings, onDismiss: { XSignInstallation.shared.resumeIfPossible() }) {
                AppStore2026SettingsPopup()
            }
        }

        .task(id: sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            await cache.ensureFetched(sources: sources, viewModel: viewModel)
        }
    }

}

struct XSignStoreCategoryBar<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(xsignText(title)).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: 8) { pills }
                } else {
                    pills
                }
            }
        }
    }

    private var pills: some View {
        LazyHStack(spacing: 8, content: content)
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
    }
}

struct XSignStoreCategoryPill: View {
    let title: String
    let symbol: String
    var svg: String? = nil
    var isSelected = false
    @AppStorage("Feather.userTintColor") private var userTintHex = "#005BBB"

    var body: some View {
        HStack(spacing: 6) {
            XSignCategoryIcon(svg: svg, symbol: symbol)
                .accessibilityHidden(true)
            Text(xsignText(title)).lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isSelected ? AppStoreTheme.contrastingText(forHex: userTintHex) : .primary)
        .padding(.horizontal, 15)
        .frame(minHeight: 44)
        .xsignGlassControl(in: Capsule(), tint: isSelected ? Color(hex: userTintHex) : nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 4. SEARCH VIEW (Background Debounced 120fps Zero-Lag Search)
struct AppStoreSearchView: View {
	@StateObject private var viewModel = SourcesViewModel.shared
	@StateObject private var cache = AppStoreCacheManager.shared
	@State private var localSearchText = ""
    private let tabSearchQuery: Binding<String>?
    private var searchText: String { tabSearchQuery?.wrappedValue ?? localSearchText }
	@StateObject private var results = XSignSearchResults()
	@State private var showSettingsSheet = false

    init(tabSearchQuery: Binding<String>? = nil) { self.tabSearchQuery = tabSearchQuery }

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>

	var body: some View {
		XSignNavigationView {
			ScrollView(.vertical, showsIndicators: false) {
				LazyVStack(alignment: .leading, spacing: 26) {
					AppStore2026TopHeader(
						title: "بحث",
						onSettingsTap: { showSettingsSheet = true }
					)
                    if tabSearchQuery == nil {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("الألعاب والتطبيقات والمزيد…", text: $localSearchText).submitLabel(.search)
                            if !localSearchText.isEmpty {
                                Button { localSearchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .accessibilityLabel("مسح البحث")
                            }
                        }.padding(12).xsignGlassControl(in: Capsule(), interactive: false)
                            .padding(.horizontal, 18)
                    }
					if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        XSignCatalogCategories(cache: cache)
					} else {
                        HStack {
                            if results.isSearching { ProgressView().controlSize(.small); Text("جاري البحث…") }
                            else { Text("\(results.total) نتيجة") }
                            Spacer()
                        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18)
                        if results.visible.isEmpty && !results.isSearching {
                            VStack(spacing: 12) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 42))
                                    .foregroundStyle(.secondary)
                                Text("لا توجد نتائج لـ \"\(searchText)\"")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        } else if !results.visible.isEmpty {
                            let count = results.visible.count
                            XSignCatalogueRows(items: results.visible.prefix(count),
                                               hasMore: count < results.total && !results.isSearching) {
                                results.showMore(after: count)
                            }
                            .padding(.horizontal, 18)
                        }
					}
				}
				.padding(.bottom, 110)
			}
			.xsignPageBackground()
			.navigationBarHidden(true)
			.onChange(of: searchText) { newQuery in
				triggerBackgroundSearch(query: newQuery)
			}
            .onChange(of: cache.catalogRevision) { _ in triggerBackgroundSearch(query: searchText) }
            .onDisappear { results.cancel() }
			.sheet(isPresented: $showSettingsSheet, onDismiss: { XSignInstallation.shared.resumeIfPossible() }) {
				AppStore2026SettingsPopup()
			}
		}

        .task(id: _sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            triggerBackgroundSearch(query: searchText)
            await cache.ensureFetched(sources: _sources, viewModel: viewModel)
        }
	}

    private func triggerBackgroundSearch(query: String) {
        results.update(query: query, items: cache.allCombinedItems)
    }

}

// MARK: - Top Header
struct AppStore2026TopHeader: View {
    let title: String
    let onSettingsTap: () -> Void
    var date: Date? = nil
    var showsAccount = true
    var horizontalInset: CGFloat = 18

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                if let date {
                    Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(xsignText(title)).font(.largeTitle.weight(.heavy))
                    .foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
            }
            Spacer()
            if showsAccount { AppStoreAccountAppIconButton(action: onSettingsTap) }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, 14)
    }
}

struct AppStoreAccountAppIconButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FRAppIconView(size: 38)
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .padding(3)
                .xsignGlassControl(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("الإعدادات")
    }
}

// MARK: - Authentic Apple App Store Today Cards
struct TodayLiveEventHeroCard: View {
	let outerTitle: String?
	let outerSubtitle: String?
	let cornerBadge: String
	let eventTag: String
	let headline: String
	let descriptionText: String
	let bannerImageURL: URL?
	let cardColor: Color
	let item: AppStoreAppItem

	@State private var liveScreenshots: [URL] = []

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if let outerTitle {
				VStack(alignment: .leading, spacing: 2) {
					Text(xsignText(outerTitle))
						.font(.system(size: 22, weight: .heavy))
						.foregroundStyle(.primary)
					if let outerSubtitle {
						Text(xsignText(outerSubtitle))
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
				.padding(.horizontal, 2)
			}

			VStack(spacing: 0) {
				ZStack(alignment: .topLeading) {
					Color.clear
						.frame(maxWidth: .infinity)
						.frame(height: 350)
						.background(
							LinearGradient(
								colors: [
									cardColor,
									cardColor.opacity(0.82),
									Color(red: 0.08, green: 0.08, blue: 0.10)
								],
								startPoint: .top,
								endPoint: .bottom
							)
						)
						.overlay {
							let displayBanner = bannerImageURL ?? liveScreenshots.first
							if let bannerURL = displayBanner {
								LazyImage(request: xsignImageRequest(bannerURL)) { state in
									if let image = state.image {
										image
											.resizable()
											.scaledToFill()
											.opacity(0.55)
									}
								}
								.processors([.resize(size: CGSize(width: 500, height: 500))])
							} else {
								AppStoreIconView(
									url: item.app.iconURL,
									bundleID: item.app.id,
									appName: item.app.currentName,
									size: 138
								)
								.shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
								.offset(y: -38)
							}
						}
						.clipped()
						.overlay(alignment: .bottomLeading) {
							ZStack(alignment: .bottomLeading) {
								LinearGradient(
									colors: [.clear, cardColor.opacity(0.88), cardColor],
									startPoint: .center,
									endPoint: .bottom
								)

								VStack(alignment: .leading, spacing: 6) {
									Text(xsignText(eventTag))
										.font(.system(size: 13, weight: .bold))
										.foregroundStyle(.white.opacity(0.9))

									Text(xsignText(headline))
										.font(.system(size: 26, weight: .heavy))
										.foregroundStyle(.white)
										.lineLimit(2)
										.multilineTextAlignment(.leading)

									Text(descriptionText)
										.font(.system(size: 14, weight: .medium))
										.foregroundStyle(.white.opacity(0.88))
										.lineLimit(2)
										.multilineTextAlignment(.leading)
								}
								.frame(maxWidth: .infinity, alignment: .leading)
								.padding(.horizontal, 20)
								.padding(.bottom, 18)
							}
						}

					Text(xsignText(cornerBadge))
						.font(.system(size: 13, weight: .bold))
						.foregroundStyle(.white)
						.padding(.horizontal, 16)
						.padding(.vertical, 8)
						.background(
							NBUnevenRoundedRectangle(
								topLeadingRadius: 26,
								bottomLeadingRadius: 0,
								bottomTrailingRadius: 16,
								topTrailingRadius: 0,
								style: .continuous
							)
							.fill(Color.black.opacity(0.42))
						)
				}

				Divider()
					.background(Color.white.opacity(0.14))

				HStack(spacing: 12) {
					AppStoreIconView(
						url: item.app.iconURL,
						bundleID: item.app.id,
						appName: item.app.currentName,
						size: 50
					)

					VStack(alignment: .leading, spacing: 2) {
						Text(item.app.currentName)
							.font(.system(size: 16, weight: .bold))
							.foregroundStyle(.white)
							.lineLimit(1)
						Text(xsignText(item.arabicSubtitle))
							.font(.system(size: 13))
							.foregroundStyle(.white.opacity(0.8))
							.lineLimit(1)
					}

					Spacer(minLength: 8)

					AppStore2026DownloadButton(app: item.app, provenance: item.downloadProvenance(), onArtwork: true)
				}
				.padding(.horizontal, 18)
				.padding(.vertical, 14)
				.frame(maxWidth: .infinity)
				.background(cardColor.opacity(0.95))
			}
			.frame(maxWidth: .infinity)
			.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
			.overlay(
				RoundedRectangle(cornerRadius: 28, style: .continuous)
					.stroke(Color.white.opacity(0.10), lineWidth: 0.7)
			)
			.task {
				if bannerImageURL == nil && liveScreenshots.isEmpty && !AppStoreLiveMetadataBridge.hasExtractedGitHubIcon(item.app.iconURL) {
					if let meta = await AppStoreLiveMetadataBridge.shared.fetchMetadata(
						bundleID: item.app.id,
						appName: item.app.currentName,
						iconURL: item.app.iconURL,
                skipLookup: item.app.skipAppStoreLookup == true
					) {
						liveScreenshots = meta.screenshots
					}
				}
			}
		}
	}
}

struct TodayTwoRowIconGridCard: View {
	let outerTitle: String?
	let outerSubtitle: String?
	let outerPuzzleIcon: Bool
	let caption: String
	let headline: String
	let descriptionText: String?
	let gradientColors: [Color]
	let items: [AppStoreAppItem]
	let fallbackItem: AppStoreAppItem

	private var topRowItems: [AppStoreAppItem] {
		Array(items.prefix(4))
	}

	private var bottomRowItems: [AppStoreAppItem] {
		let rest = Array(items.dropFirst(4).prefix(4))
		return rest.isEmpty ? Array(items.reversed().prefix(4)) : rest
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if let outerTitle {
				VStack(alignment: .leading, spacing: 3) {
					HStack(spacing: 6) {
						if outerPuzzleIcon {
							Image(systemName: "puzzlepiece.extension.fill")
								.font(.system(size: 20))
								.foregroundStyle(AppStoreTheme.dynamicAccent)
						}
						Text(xsignText(outerTitle))
							.font(.system(size: 22, weight: .heavy))
							.foregroundStyle(.primary)
					}
					if let outerSubtitle {
						Text(xsignText(outerSubtitle))
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
				.padding(.horizontal, 2)
			}

			Color.clear
				.frame(maxWidth: .infinity)
				.frame(height: 365)
				.background(
					LinearGradient(
						colors: gradientColors,
						startPoint: .top,
						endPoint: .bottom
					)
				)
				.overlay(alignment: .top) {
					VStack(spacing: 16) {
						HStack(spacing: 14) {
							ForEach(topRowItems) { appItem in
								AppStoreIconView(
									url: appItem.app.iconURL,
									bundleID: appItem.app.id,
									appName: appItem.app.currentName,
									size: 80
								)
								.shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 5)
							}
						}
						.offset(x: 12)

						HStack(spacing: 14) {
							ForEach(bottomRowItems) { appItem in
								AppStoreIconView(
									url: appItem.app.iconURL,
									bundleID: appItem.app.id,
									appName: appItem.app.currentName,
									size: 80
								)
								.shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 5)
							}
						}
						.offset(x: -12)
					}
					.padding(.top, 26)
				}
				.overlay(alignment: .bottomLeading) {
					ZStack(alignment: .bottomLeading) {
						LinearGradient(
							colors: [.clear, gradientColors.last?.opacity(0.95) ?? .black],
							startPoint: .center,
							endPoint: .bottom
						)

						VStack(alignment: .leading, spacing: 6) {
							Text(xsignText(caption))
								.font(.system(size: 13, weight: .bold))
								.foregroundStyle(.white.opacity(0.88))

							Text(xsignText(headline))
								.font(.system(size: 27, weight: .heavy))
								.foregroundStyle(.white)
								.lineLimit(2)
								.multilineTextAlignment(.leading)

							if let descriptionText {
								Text(descriptionText)
									.font(.system(size: 14, weight: .medium))
									.foregroundStyle(.white.opacity(0.90))
									.lineLimit(2)
							}
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(22)
					}
				}
				.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
				.overlay(
					RoundedRectangle(cornerRadius: 28, style: .continuous)
						.stroke(Color.white.opacity(0.10), lineWidth: 0.7)
			)
		}
	}
}

struct XSignTodayListCard: View {
    let items: [AppStoreAppItem]
    let showsDownload: Bool
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let caption {
                Text(xsignText(caption)).font(.subheadline.bold()).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                AppStore2026AppRow(item: item, showsDownload: showsDownload)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppStoreTheme.cardSurface, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
    }
}

struct TodayFullArtworkDockCard: View {
	let categoryTag: String
	let headline: String
	let subtitle: String
	let showPlayBadge: Bool
	let item: AppStoreAppItem
	@AppStorage("Feather.userTintColor") private var userTintHex: String = "#005BBB"

	@State private var liveScreenshots: [URL] = []

	private var baseColor: Color {
		item.app.tintColor ?? Color(hex: userTintHex)
	}

	var body: some View {
		VStack(spacing: 0) {
			Color.clear
				.frame(maxWidth: .infinity)
				.frame(height: 330)
				.background(
					LinearGradient(
						colors: [
							baseColor.opacity(0.75),
							Color(red: 0.16, green: 0.28, blue: 0.42),
							Color(red: 0.12, green: 0.20, blue: 0.30)
						],
						startPoint: .topTrailing,
						endPoint: .bottomLeading
					)
				)
				.overlay {
					let displayImg = item.screenshots.first ?? liveScreenshots.first
					if let firstScreen = displayImg {
						LazyImage(request: xsignImageRequest(firstScreen)) { state in
							if let image = state.image {
								image
									.resizable()
									.scaledToFill()
							}
						}
						.processors([.resize(size: CGSize(width: 500, height: 500))])
					} else {
						AppStoreIconView(
							url: item.app.iconURL,
							bundleID: item.app.id,
							appName: item.app.currentName,
							size: 128
						)
						.shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
						.offset(y: -35)
					}
				}
				.clipped()
				.overlay {
					if showPlayBadge {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .xsignGlassControl(in: Circle(), tint: .black.opacity(0.30), interactive: false)
                            .offset(y: -30)
                            .accessibilityHidden(true)
					}
				}
				.overlay(alignment: .bottomLeading) {
					ZStack(alignment: .bottomLeading) {
						LinearGradient(
							colors: [.clear, Color.black.opacity(0.82)],
							startPoint: .center,
							endPoint: .bottom
						)

						VStack(alignment: .leading, spacing: 5) {
							Text(xsignText(categoryTag))
								.font(.system(size: 13, weight: .bold))
								.foregroundStyle(.white.opacity(0.88))
							Text(xsignText(headline))
								.font(.system(size: 26, weight: .heavy))
								.foregroundStyle(.white)
								.lineLimit(2)
							Text(subtitle)
								.font(.system(size: 14, weight: .medium))
								.foregroundStyle(.white.opacity(0.88))
								.lineLimit(2)
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.horizontal, 20)
						.padding(.bottom, 16)
					}
				}

			HStack(spacing: 12) {
				AppStoreIconView(
					url: item.app.iconURL,
					bundleID: item.app.id,
					appName: item.app.currentName,
					size: 50
				)

				VStack(alignment: .leading, spacing: 2) {
					Text(item.app.currentName)
						.font(.system(size: 16, weight: .bold))
						.foregroundStyle(.white)
						.lineLimit(1)
					Text(xsignText(item.category.rawValue))
						.font(.caption)
						.foregroundStyle(.white.opacity(0.75))
						.lineLimit(1)
				}

				Spacer(minLength: 8)

				AppStore2026DownloadButton(app: item.app, provenance: item.downloadProvenance(), onArtwork: true)
			}
			.padding(.horizontal, 18)
			.padding(.vertical, 14)
			.frame(maxWidth: .infinity)
			.background(Color(red: 0.16, green: 0.22, blue: 0.28))
		}
		.frame(maxWidth: .infinity)
		.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 28, style: .continuous)
				.stroke(Color.white.opacity(0.10), lineWidth: 0.6)
		)
		.task {
			if item.screenshots.isEmpty && liveScreenshots.isEmpty && !AppStoreLiveMetadataBridge.hasExtractedGitHubIcon(item.app.iconURL) {
				if let meta = await AppStoreLiveMetadataBridge.shared.fetchMetadata(
					bundleID: item.app.id,
					appName: item.app.currentName,
					iconURL: item.app.iconURL,
                skipLookup: item.app.skipAppStoreLookup == true
				) {
					liveScreenshots = meta.screenshots
				}
			}
		}
	}
}

// MARK: - Settings Popup
struct AppStore2026SettingsPopup: View {
	@Environment(\.dismiss) private var dismiss
	@State private var selectedSection = 0
	@AppStorage("Feather.userTintColor") private var userTintHex: String = "#005BBB"

	var body: some View {
		XSignNavigationView {
			VStack(spacing: 0) {
				VStack(spacing: 12) {
					HStack(spacing: 12) {
						ZStack {
							RoundedRectangle(cornerRadius: 12, style: .continuous)
								.fill(
									LinearGradient(
										colors: [Color(hex: userTintHex), AppStoreTheme.deepOcean],
										startPoint: .topLeading,
										endPoint: .bottomTrailing
									)
								)
							FRAppIconView(size: 48)
						}
						.frame(width: 48, height: 48)

						VStack(alignment: .leading, spacing: 2) {
							Text("X-SIGN")
								.font(.headline.weight(.bold))
							Text("الإعدادات، الشهادات، والمصادر")
								.font(.caption)
								.foregroundStyle(.secondary)
						}

						Spacer()

						Button("تم") {
							dismiss()
						}
                        .font(.body.weight(.bold))
                        .xsignGlassButton()
					}

					Picker("", selection: $selectedSection) {
						Text("الإعدادات").tag(0)
						Text("الشهادات").tag(1)
						Text("مصادري").tag(2)
					}
					.pickerStyle(.segmented)
				}
				.padding(.horizontal, 18)
				.padding(.vertical, 12)
                .xsignSurface(radius: 24)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

				if selectedSection == 0 {
					SettingsView()
				} else if selectedSection == 1 {
					CertificatesView()
				} else {
					XSignPersonalSourcesView()
				}
			}
			.xsignPageBackground()
			.navigationBarHidden(true)
		}

	}
}

struct CustomSafeAddSourceSheet: View {
	@Environment(\.dismiss) private var dismiss
	@State private var sourceURLText = ""
	@State private var isSaving = false
    @State private var errorMessage: String?

	var body: some View {
		XSignNavigationView {
			Form {
				Section("رابط المصدر (JSON URL)") {
				TextField("رابط السورس عبر HTTPS", text: $sourceURLText)
						.keyboardType(.URL)
						.textInputAutocapitalization(.never)
						.disableAutocorrection(true)
				}

				Section {
					Button {
						addSource()
					} label: {
						HStack {
							Spacer()
							if isSaving {
								ProgressView()
							} else {
								Text("إضافة المصدر")
									.font(.body.weight(.bold))
							}
							Spacer()
						}
					}
					.disabled(sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
				}
                if let errorMessage { Section { Text(xsignText(errorMessage)).font(.footnote).foregroundStyle(.red) } }
			}
			.xsignListBackground()
			.navigationTitle("إضافة مصدر")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("إلغاء") {
						dismiss()
					}
				}
			}
		}

	}

	private func addSource() {
		let trimmed = sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard XSignManagedSource.httpsURL(trimmed) != nil else { errorMessage = "أدخل رابط HTTPS صالحاً لملف المصدر."; return }
		isSaving = true
        errorMessage = nil
		FR.handleSource(trimmed, onFailure: { error in isSaving = false; errorMessage = error.localizedDescription }) {
			isSaving = false
			dismiss()
		}
	}
}

// MARK: - Unified Download & Auto-Sign Button
struct AppStore2026DownloadButton: View {
    let app: ASRepository.App
    var provenance: SourceAppProvenance? = nil
    var onArtwork = false
    var usesGlass = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentStage: AutoSignPipelineManager.Stage?
    @State private var progressPercent = 0

    private let pipeline = AutoSignPipelineManager.shared
	@AppStorage("Feather.userTintColor") private var userTintHex: String = "#005BBB"

	private var accentColor: Color {
		Color(hex: userTintHex)
	}

	private var appKey: String {
		app.downloadKey
	}

    private var canDownload: Bool {
        app.currentDownloadUrl.flatMap { XSignManagedSource.httpsURL($0.absoluteString) } != nil
    }

	var body: some View {
		Button {
			pipeline.downloadAndAutoSign(app: app, provenance: provenance)
		} label: {
            Group {
                if currentStage == nil { pillLabel }
                else { circularLabel }
            }
            .frame(minWidth: 78, minHeight: 44)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: currentStage)
            .animation(reduceMotion ? nil : .linear(duration: 0.17), value: progressPercent)
		}
		.buttonStyle(.plain)
		.disabled(currentStage == .ready || (currentStage == nil && !canDownload))
        .accessibilityLabel(Text(verbatim: installAccessibilityLabel))
        .onReceive(pipeline.$activeStates.map { $0[appKey] }.removeDuplicates()) {
            if currentStage != $0 {
                currentStage = $0
                if $0 != .downloading { progressPercent = 0 }
            }
        }
        .background {
            if currentStage == .downloading, let progress = pipeline.progressPublisher(for: appKey) {
                Color.clear.onReceive(progress) { progressPercent = $0 }
            }
        }
    }

    private var installAccessibilityLabel: String {
        switch currentStage {
        case .queued: return xsignText("بالانتظار")
        case .failed(let message): return String(format: xsignText("أعد المحاولة. %@"), xsignText(message))
        case .downloading: return String(format: xsignText("جاري التنزيل، %lld بالمئة"), Int64(progressPercent))
        case .preparing: return xsignText("جاري التجهيز")
        case .signing: return xsignText("جاري التوقيع")
        case .ready: return xsignText("تم التوقيع")
        case nil: return canDownload ? String(format: xsignText("تثبيت %@"), app.currentName) : xsignText("التنزيل غير متاح")
        }
    }

    private var circularLabel: some View {
        let foreground: Color = onArtwork ? .white : accentColor
        return ZStack {
            Circle().strokeBorder(foreground.opacity(0.20), lineWidth: 1.3)
            switch currentStage {
            case .downloading:
                Circle().trim(from: 0, to: CGFloat(min(100, max(0, progressPercent))) / 100)
                    .stroke(foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
                Image(systemName: "arrow.down").font(.system(size: 13, weight: .bold))
            case .preparing, .signing:
                ProgressView().tint(foreground).controlSize(.small)
            case .queued:
                Image(systemName: "clock").font(.system(size: 15, weight: .semibold))
            case .failed:
                Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .semibold))
            case .ready:
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold))
            case nil: EmptyView()
            }
        }
        .foregroundStyle(foreground)
        .frame(width: 44, height: 44)
        .xsignGlassControl(in: Circle(), tint: onArtwork ? .black.opacity(0.26) : nil, interactive: false)
    }

    @ViewBuilder
    private var pillLabel: some View {
        let label = Text(xsignText(canDownload ? "تثبيت" : "غير متاح"))
            .font(.subheadline.weight(.bold))
            .foregroundStyle(canDownload ? AppStoreTheme.contrastingText(forHex: userTintHex) : .secondary)
            .frame(minWidth: 78, minHeight: 32)
        let tint = canDownload ? accentColor : nil
        if usesGlass {
            label.xsignGlassControl(in: Capsule(), tint: tint, interactive: canDownload)
        } else {
            label.background(tint ?? AppStoreTheme.controlSurface, in: Capsule())
        }
    }
}


struct AppStore2026AppRow: View {
    let item: AppStoreAppItem
    var showsDownload = true

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                AppStore2026DetailView(item: item)
            } label: {
                HStack(spacing: 12) {
                    AppStoreIconView(url: item.app.iconURL, bundleID: item.app.id,
                                     appName: item.app.currentName, size: 50, looksUpMissingArtwork: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.app.currentName).font(.body.weight(.semibold)).lineLimit(2)
                        Text(xsignText(item.arabicSubtitle)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            if showsDownload {
                AppStore2026DownloadButton(app: item.app, provenance: item.downloadProvenance(), usesGlass: false)
            }
        }
        .padding(.vertical, 10)
    }
}

struct AppStore2026FeaturedBanner: View {
    let item: AppStoreAppItem
    @AppStorage("Feather.userTintColor") private var userTintHex = "#005BBB"

    private var artwork: URL? {
        [item.app.artworkURL, item.screenshots.first].compactMap { $0 }
            .first { XSignManagedSource.httpsURL($0.absoluteString) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                AppStore2026DetailView(item: item)
            } label: {
                GeometryReader { proxy in
                    ZStack {
                        let tint = item.app.tintColor ?? Color(hex: userTintHex)
                        LinearGradient(colors: [AppStoreTheme.deepOcean, tint.opacity(0.7)],
                                       startPoint: .bottomLeading, endPoint: .topTrailing)
                        if let artwork {
                            LazyImage(request: xsignImageRequest(artwork)) { state in
                                if let image = state.image {
                                    image.resizable().scaledToFill()
                                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                                } else {
                                    icon
                                }
                            }
                            .processors([.resize(size: CGSize(width: 840, height: 520))])
                        } else {
                            icon
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }
                .frame(height: 156)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.app.currentName)

            AppStore2026AppRow(item: item).padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity)
        .background(AppStoreTheme.controlSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var icon: some View {
        AppStoreIconView(url: item.app.iconURL, bundleID: item.app.id, appName: item.app.currentName, size: 78)
            .shadow(color: .black.opacity(0.26), radius: 13, y: 7)
    }
}

struct AppStoreIconView: View {
	let url: URL?
	var bundleID: String? = nil
	var appName: String = ""
	let size: CGFloat
    var looksUpMissingArtwork = true
	@State private var appleIconURL: URL? = nil

    private var isFallbackGitHubIcon: Bool {
		guard let u = url?.absoluteString.lowercased() else { return true }
		return u.contains("github.com/ipa-black.png") || u.hasSuffix("/assets/icon.png")
	}

	var body: some View {
		Group {
			let effectiveURL = isFallbackGitHubIcon ? (appleIconURL ?? url) : url
			if let effectiveURL {
				LazyImage(request: xsignImageRequest(effectiveURL)) { state in
					if let image = state.image {
						image
							.resizable()
							.scaledToFill()
					} else {
						placeholder
					}
				}
				.processors([.resize(size: CGSize(width: size * 2, height: size * 2))])
			} else {
				placeholder
			}
		}
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
				.stroke(Color.primary.opacity(0.14), lineWidth: 0.6)
		)
		.task {
			if looksUpMissingArtwork && isFallbackGitHubIcon && !appName.isEmpty && !AppStoreLiveMetadataBridge.hasExtractedGitHubIcon(url) && !AppStoreCacheManager.shared.shouldSkipStoreLookup(bundleID) {
				if let meta = await AppStoreLiveMetadataBridge.shared.fetchMetadata(
					bundleID: bundleID,
					appName: appName,
					iconURL: url
				) {
					appleIconURL = meta.artworkURL
				}
			}
		}
	}

	private var placeholder: some View {
		RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
			.fill(AppStoreTheme.controlSurface)
	}
}

func xsignImageRequest(_ url: URL) -> ImageRequest? {
    guard XSignManagedSource.httpsURL(url.absoluteString) != nil else { return nil }
    return ImageRequest(url: url)
}

struct AppStore2026EmptyState: View {
    let isLoading: Bool
    var emptyMessage: String = "لا توجد تطبيقات في المصادر المفعّلة."
    var retry: (() -> Void)? = nil
	@AppStorage("Feather.userTintColor") private var userTintHex: String = "#005BBB"

	var body: some View {
		VStack(spacing: 16) {
            if isLoading {
                ProgressView().tint(Color(hex: userTintHex)).scaleEffect(1.3)
            } else {
                Image(systemName: "square.stack").font(.largeTitle).foregroundStyle(.secondary)
            }
            Text(xsignText(isLoading ? "جاري تحديث المصادر…" : emptyMessage))
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(.primary)
            if !isLoading, let retry {
                Button("إعادة المحاولة", action: retry)
            }
		}
		.frame(maxWidth: .infinity)
		.padding(36)
		.background(
			RoundedRectangle(cornerRadius: 26, style: .continuous)
				.fill(AppStoreTheme.cardSurface)
		)
	}
}

// MARK: - XSign Inline Description Translation
struct XSignTranslatableDescription: View {
    let text: String
    let accentColor: Color

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                XSignInlineTranslation(text: text, accentColor: accentColor)
                    .id(text)
            } else {
                XSignLegacyTranslation(text: text, accentColor: accentColor)
                    .id(text)
            }
        }
    }
}

private struct XSignDescriptionContent: View {
    let text: String
    let translated: String?
    let accentColor: Color
    let isBusy: Bool
    let canTranslate: Bool
    let translate: () -> Void
    let restore: () -> Void
    @State private var expanded = false

    private var visibleText: String { translated ?? text }

    private var isArabic: Bool {
        NLLanguageRecognizer.dominantLanguage(for: visibleText) == .arabic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("الوصف").font(.title2.bold())
                translationButton
            }

            Text(verbatim: visibleText)
                .font(.body)
                .foregroundStyle(Color.primary.opacity(0.88))
                .lineSpacing(5)
                .lineLimit(expanded ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
                .textSelection(.enabled)

            Button(expanded ? "عرض أقل" : "المزيد") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.toggle()
                }
            }
            .font(.subheadline.bold())
            .foregroundStyle(accentColor)
        }
        .buttonStyle(.plain)
        .onChange(of: translated) { _ in
            expanded = true
        }
    }

    @ViewBuilder private var translationButton: some View {
        if translated != nil {
            Button("عرض الأصل", action: restore)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentColor)
        } else if canTranslate && NLLanguageRecognizer.dominantLanguage(for: text) != .arabic {
            Button(action: translate) {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView().tint(accentColor)
                    }
                    Label(
                        isBusy ? "جارٍ الترجمة…" : "ترجمة للعربية",
                        systemImage: "translate"
                    )
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(accentColor.opacity(0.12), in: Capsule())
            }
            .disabled(
                isBusy ||
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }
}

@available(iOS 18.0, *)
private struct XSignInlineTranslation: View {
    let text: String
    let accentColor: Color

    @State private var configuration: TranslationSession.Configuration?
    @State private var translated: String?
    @State private var isBusy = false
    @State private var showError = false

    var body: some View {
        XSignDescriptionContent(
            text: text,
            translated: translated,
            accentColor: accentColor,
            isBusy: isBusy,
            canTranslate: true,
            translate: {
                isBusy = true
                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: nil,
                        target: Locale.Language(identifier: "ar")
                    )
                } else {
                    configuration?.invalidate()
                }
            },
            restore: {
                translated = nil
            }
        )
        .translationTask(configuration) { session in
            do {
                let response = try await session.translate(text)
                try Task.checkCancellation()

                await MainActor.run {
                    translated = response.targetText
                    isBusy = false
                }
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                await MainActor.run {
                    isBusy = false
                    if !cancelled {
                        showError = true
                    }
                }
            }
        }
        .alert("تعذّرت الترجمة", isPresented: $showError) {
            Button("حسنًا", role: .cancel) {}
        } message: {
            Text("تأكد من توفر لغات الترجمة واتصال الإنترنت عند تنزيلها، ثم أعد المحاولة.")
        }
    }
}

private struct XSignLegacyTranslation: View {
    let text: String
    let accentColor: Color

    @State private var presented = false
    @State private var translated: String?

    private var content: some View {
        XSignDescriptionContent(
            text: text,
            translated: translated,
            accentColor: accentColor,
            isBusy: false,
            canTranslate: supportsTranslation,
            translate: {
                presented = true
            },
            restore: {
                translated = nil
            }
        )
    }

    private var supportsTranslation: Bool {
        if #available(iOS 17.4, *) {
            return true
        }
        return false
    }

    var body: some View {
        Group {
            if #available(iOS 17.4, *) {
                content.translationPresentation(
                    isPresented: $presented,
                    text: text
                ) { result in
                    translated = result
                    presented = false
                }
            } else {
                content
            }
        }
    }
}
// MARK: - End XSign Inline Description Translation

// MARK: - Configured source identity, taxonomy and announcements
private struct XSignCatalogCategories: View {
    @ObservedObject var cache: AppStoreCacheManager
    @ScaledMetric(relativeTo: .body) private var tileHeight: CGFloat = 112
    @State private var scope: Scope = .all

    private enum Scope: String, CaseIterable, Identifiable {
        case all = "search"
        case apps
        case games

        var id: Self { self }
        var title: String {
            switch self {
            case .all: return "الكل"
            case .apps: return "التطبيقات"
            case .games: return "الألعاب"
            }
        }
        var symbol: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .apps: return "square.stack.fill"
            case .games: return "gamecontroller.fill"
            }
        }
    }

    private static let colors: [(UInt64, UInt64)] = [
        (0x235C9D, 0x123669), (0x6741A5, 0x40257C),
        (0x13798E, 0x10566C), (0x2B825F, 0x185345),
        (0xA35939, 0x713A28), (0xA64378, 0x742E59)
    ]

    var body: some View {
        let groups = cache.categories(for: scope.rawValue).filter { !$0.items.isEmpty }
        if !cache.allCombinedItems.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                XSignStoreCategoryBar(title: "التصنيفات") {
                    ForEach(Scope.allCases) { option in
                        Button { scope = option } label: {
                            XSignStoreCategoryPill(title: option.title, symbol: option.symbol, isSelected: option == scope)
                        }.buttonStyle(.plain)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    if scope != .games && !cache.pureAppsOnly.isEmpty {
                        tile(title: "التطبيقات", items: cache.pureAppsOnly, svg: nil, symbol: "square.stack.fill", at: 0)
                    }
                    if scope != .apps && !cache.pureGamesOnly.isEmpty {
                        tile(title: "الألعاب", items: cache.pureGamesOnly, svg: nil, symbol: "gamecontroller.fill", at: 1)
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        tile(title: group.title, items: group.items, svg: group.iconSVG, symbol: group.symbol, at: index + 2)
                    }
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private func tile(title: String, items: [AppStoreAppItem], svg: String?, symbol: String, at index: Int) -> some View {
        let pair = Self.colors[index % Self.colors.count]
        return NavigationLink {
            XSignClassicCatalogueList(title: title, items: items)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Spacer()
                    if let svg {
                        XSignCategoryIcon(svg: svg, symbol: symbol, size: 42)
                    } else {
                        let icons = Array(items.lazy.compactMap { $0.app.iconURL }.prefix(2))
                        if icons.isEmpty {
                            Image(systemName: symbol).font(.system(size: 28, weight: .semibold))
                        } else {
                            HStack(spacing: -9) {
                                ForEach(icons.indices, id: \.self) { index in
                                    AppStoreIconView(url: icons[index], size: 36, looksUpMissingArtwork: false)
                                        .rotationEffect(.degrees(index == 0 ? 8 : -8))
                                }
                            }
                        }
                    }
                }
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(xsignText(title)).font(.subheadline.weight(.bold)).lineLimit(2).multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: tileHeight, alignment: .leading)
            .foregroundStyle(.white)
            .background(LinearGradient(colors: [Color(hex: String(format: "#%06llX", pair.0)),
                                                Color(hex: String(format: "#%06llX", pair.1))],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
    }
}

struct XSignAnnouncementCard: View {
    let instruction: TodayEditorialInstruction
    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let badge = instruction.badge { Text(xsignText(badge)).font(.caption.bold()).foregroundStyle(Color.accentColor) }
            Text(instruction.title).font(.title3.bold())
            Text(instruction.caption).font(.subheadline).foregroundStyle(.secondary)
            if instruction.targetURL != nil { Image(systemName: "arrow.up.left.square").foregroundStyle(Color.accentColor) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .xsignSurface()
    }
    var body: some View {
        if let url = instruction.targetURL { Link(destination: url) { content }.buttonStyle(.plain) }
        else if let app = instruction.associatedApp {
            NavigationLink { AppStore2026DetailView(item: app) } label: { content }.buttonStyle(.plain)
        } else { content }
    }
}
