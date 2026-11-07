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
    nonisolated static let background = Color(uiColor: .systemGroupedBackground)
    nonisolated static let pureBlack = background
    nonisolated static let cardSurface = Color(uiColor: .secondarySystemGroupedBackground)
    nonisolated static let controlSurface = Color(uiColor: .tertiarySystemFill)

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
    nonisolated static let primaryURLString = "https://appiraq.com/source.php?action=getAll"
    nonisolated static let secondaryURLString = "https://appiraq.com/han.json"
    nonisolated static let defaultOwnedURLString = "https://raw.githubusercontent.com/ipablack/repo/main/repo.json"
    nonisolated static let defaultOwnedGitHubRawURLString = "https://github.com/ipablack/repo/raw/refs/heads/main/repo.json"
    nonisolated static let ownedIdentifier = "xsign.core.owned"
    nonisolated static let ownedURLKey = "xsign.ownedSourceURL.v1"
    nonisolated static let legacyURLs = [
        "https://raw.githubusercontent.com/ipa-black/IPABLACK/main/repo.json",
        "https://raw.githubusercontent.com/ipa-black/store-api/main/public/repo.json",
        "https://raw.githubusercontent.com/ipa-black/X-SIGN/main/Feather/Resources/XSignCatalogReference.json",
        "https://supapi.trystore.net/rest/v1/plus_library_apps",
        "https://raw.githubusercontent.com/ipa-black/X-SIGN/main/public/sources/ipaomtk.json"
    ]

    nonisolated static func validOwnedURL(_ text: String?) -> URL? {
        guard let text, let raw = URL(string: text), raw.scheme?.lowercased() == "https",
              raw.host != nil, raw.user == nil, raw.password == nil, raw.fragment == nil else { return nil }
        let url = XSignCatalogIO.canonicalURL(raw)
        guard url.absoluteString != primaryURLString,
              !legacyURLs.contains(where: { URL(string: $0).map(XSignCatalogIO.canonicalURL) == url }) else { return nil }
        return url
    }

    nonisolated static var ownedURL: URL? { validOwnedURL(defaultOwnedURLString) }
    nonisolated static var coreURLs: [String] { (ownedURL.map { [$0.absoluteString] } ?? []) + [primaryURLString, secondaryURLString] + XSignDashboardSources.iosboomSources.filter { $0.enabled != false }.map(\.url) }

    nonisolated static func isRetiredSource(_ sourceURL: URL?, identifier: String? = nil) -> Bool {
        guard let sourceURL else { return true }
        guard XSignManagedSource.httpsURL(sourceURL.absoluteString) != nil else { return true }
        let legacy=legacyURLs.contains { URL(string:$0).map(XSignCatalogIO.canonicalURL) == XSignCatalogIO.canonicalURL(sourceURL) }
        // An explicit dashboard source may reuse any valid HTTPS endpoint. Old
        // cached sources alone cannot re-enable a provider that the owner removed.
        return legacy && XSignDashboardSources.configuration(for:sourceURL) == nil && !XSignDashboardSources.isExplicitUserSource(sourceURL)
    }
    nonisolated static func isIPABlackSource(_ sourceURL: URL?, identifier: String? = nil) -> Bool {
        sourceURL.map(XSignCatalogIO.canonicalURL) == ownedURL.map(XSignCatalogIO.canonicalURL)
    }
    nonisolated static func isHiddenCoreSource(_ source: AltSource) -> Bool {
        source.sourceURL.map(XSignCatalogIO.canonicalURL).map { coreURLs.contains($0.absoluteString) } ?? false
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

		let cacheKey = "\(bundleID ?? "")_\(appName)".lowercased()
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

			if let found = await Self.queryiTunes(
				urlString: "https://itunes.apple.com/lookup?bundleId=\(encodedID)&country=SA"
			) {
				return found
			}

			if let foundUS = await Self.queryiTunes(
				urlString: "https://itunes.apple.com/lookup?bundleId=\(encodedID)&country=US"
			) {
				return foundUS
			}

			// التطبيق محذوف من متجر أبل -> لا نجلب أي صور من أبل
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

	private nonisolated static func queryiTunes(urlString: String) async -> AppleStoreRichMetadata? {
		guard let url = URL(string: urlString) else { return nil }
		do {
			var request = URLRequest(url: url)
			request.timeoutInterval = 6
			request.setValue("ar-SA,ar;q=0.9", forHTTPHeaderField: "Accept-Language")
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
	let id: String
	let sourceURL: URL?
    let sourceName: String
    let sourceCategories: [ASRepository.CatalogCategory]
	let app: ASRepository.App
	let category: AppStore2026Category
	let isGame: Bool
    let declaredGame: Bool?
	let arabicSubtitle: String
	let searchIndexTokens: String
    let searchDocument: XSignSearchDocument
	let screenshots: [URL]

	init(id: String, sourceURL: URL?, repository: ASRepository, app: ASRepository.App) {
		self.id = id
		self.sourceURL = sourceURL
        self.sourceName = repository.name ?? "المصدر"
        self.sourceCategories = repository.categories ?? []
		self.app = app

		let inferred = AppStore2026Category.strictlyClassify(app: app)
        let declaredGame = app.isGame ?? repository.categories?.first(where: { $0.id == app.category })?.isGame
        self.declaredGame = declaredGame
        let classified: AppStore2026Category = declaredGame == true && !inferred.isGameCategory ? .casualGames
            : declaredGame == false && inferred.isGameCategory ? .productivity : inferred
		self.category = classified
		self.isGame = declaredGame ?? classified.isGameCategory
		self.arabicSubtitle = AppStoreBilingualEngine.localizedSubtitle(for: app, category: classified)
        self.searchDocument = XSignSearchDocument(name: app.currentName, bundleID: app.id ?? "", aliasIndex: AppStoreBilingualEngine.preparedAliasIndex)
        self.searchIndexTokens = ([searchDocument.name, searchDocument.bundle] + searchDocument.aliases).joined(separator: " ")

		if let urls = app.screenshotURLs, !urls.isEmpty {
			self.screenshots = urls
		} else if let iphone = app.screenshots?.iPhone, !iphone.isEmpty {
			self.screenshots = iphone
		} else {
			self.screenshots = []
		}
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

    func showMore() { visible = Array(ranked.prefix(visible.count + 40)) }
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
}

enum AppStore2026Category: String, CaseIterable, Identifiable, Sendable {
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

	nonisolated static func strictlyClassify(app: ASRepository.App) -> AppStore2026Category {
		let catRaw = (app.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["games", "game", "6014", "ألعاب", "العاب", "الألعاب"].contains(catRaw) || catRaw.hasPrefix("games.") {
            return .casualGames
        }
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

		let pvpKeywords = ["pubg", "8ball", "8 ball", "pool", "cod", "callofduty", "call of duty", "freefire", "free fire", "brawl", "fortnite", "fifa", "efootball", "pes", "mobilelegends", "mobile legends", "wildrift", "wild rift", "standoff", "bullet", "pvp", "multiplayer", "ark", "ببجي", "بلياردو", "فري فاير", "كود", "فيفا", "بيس"]
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

// MARK: - Cached catalog shown before background refresh
private struct XSignCatalogSnapshot: Sendable {
    var ipablackItems: [AppStoreAppItem] = []
    var ipablackEditorialNews: [TodayEditorialInstruction] = []
    var allCombinedItems: [AppStoreAppItem] = []
    var pureAppsOnly: [AppStoreAppItem] = []
    var pureGamesOnly: [AppStoreAppItem] = []
    var itemsByCategory: [AppStore2026Category: [AppStoreAppItem]] = [:]
    var includesIPABlack = false
    var sourceName = "IPA BLACK"
    var sourceSubtitle = ""
    var sourceIconURL: URL? = nil
    var sourceCategories: [ASRepository.CatalogCategory] = []
    var skippedLookupBundleIDs: Set<String> = []
    var todayItems: [AppStoreAppItem] = []
    var todayNews: [TodayEditorialInstruction] = []
    var todayCategories: [ASRepository.CatalogCategory] = []
    var todayFeaturedIDs: [String] = []
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
    var itemsByCategory: [AppStore2026Category: [AppStoreAppItem]] { catalog.itemsByCategory }
    var todayItems: [AppStoreAppItem] { catalog.todayItems }
    var todayEditorialNews: [TodayEditorialInstruction] { catalog.todayNews }
    var todayCategories: [ASRepository.CatalogCategory] { catalog.todayCategories }
    var todayFeaturedIDs: [String] { catalog.todayFeaturedIDs }

    var sourceName: String { catalog.sourceName }
    var sourceSubtitle: String { catalog.sourceSubtitle }
    var sourceIconURL: URL? { catalog.sourceIconURL }
    var sourceCategories: [ASRepository.CatalogCategory] { catalog.sourceCategories }
    var storeSources: [XSignStoreSource] {
        var entries: [(String, ASRepository)] = Self.coreTargets.compactMap { target in
            directLoadedRepos[target.urlStr].map { (target.urlStr, $0) }
        }
        entries += customSnapshot.compactMap { entry in entry.0.map { ($0.absoluteString, entry.2) } }
        var seen=Set<String>()
        return entries.compactMap { url, repo in
            guard seen.insert(url).inserted else { return nil }
            let config=URL(string:url).flatMap { XSignDashboardSources.configuration(for:$0) }
            return XSignStoreSource(id:url,name:config?.name ?? repo.name ?? "المصدر",
                icon:XSignManagedSource.httpsURL(config?.icon_url) ?? repo.currentIconURL,count:repo.apps.count)
        }
    }

    var featuredCatalogIDs: [String] {
        Self.coreTargets.flatMap { directLoadedRepos[$0.urlStr]?.featuredApps ?? [] }.compactMap { $0 }
    }

    var hasLoadedCatalog: Bool { !catalog.allCombinedItems.isEmpty || finishedInitialLoad }
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPreparing = false
    @Published private(set) var catalogErrorMessage: String? = nil
    @Published private(set) var catalogRevision: UInt64 = 0
    private var finishedInitialLoad = false
    private var publicationTask: Task<Void, Never>?
    private var sourceSubscription: AnyCancellable?
    private var requestedSources: [AltSource] = []
    private var customFingerprints: [String: Data] = [:]
    private let catalogIO: XSignCatalogIO
    private let bundledResources: URL?

    func shouldSkipStoreLookup(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return catalog.skippedLookupBundleIDs.contains(bundleID)
    }

    private var directLoadedRepos: [String: ASRepository] = [:]
    private var repoFingerprints: [String: Data] = [:]
    private var customSnapshot: [(URL?, String?, ASRepository)] = []
    private var diskSnapshotTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var nextRefreshAllowed = Date.distantPast
    private var indexGeneration: UInt64 = 0
    private var indexTask: Task<XSignCatalogSnapshot?, Never>?

    private nonisolated static let defaultCoreTargets: [(urlStr: String, id: String, file: String, seed: String)] = [
        (ProtectedSourcesVault.primaryURLString, "xsign.core.primary", "zsign_soon_cache.json", ""),
        (ProtectedSourcesVault.secondaryURLString, "xsign.core.zsign", "zsign_official_cache.json", "")
    ]

    nonisolated static func resolvedManagedSources(_ configured: [XSignCoreSourceItem]?) -> [XSignCoreSourceItem] {
        if let configured = XSignDashboardSources.configured {
            return configured.map { XSignCoreSourceItem(name:$0.name,id:$0.id,url:$0.url) }
        }
        var result=[XSignCoreSourceItem(name:"IPA BLACK",id:ProtectedSourcesVault.ownedIdentifier,url:ProtectedSourcesVault.defaultOwnedURLString)]
        result.append(XSignCoreSourceItem(name:"ipasoon",id:"xsign.core.primary",url:ProtectedSourcesVault.primaryURLString))
        result.append(XSignCoreSourceItem(name:"متجر Zsign الرسمي",id:"xsign.core.zsign",url:ProtectedSourcesVault.secondaryURLString))
        result += XSignDashboardSources.iosboomSources.filter { $0.enabled != false }.map { XSignCoreSourceItem(name:$0.name,id:$0.id,url:$0.url) }
        return result
    }

    private nonisolated static var coreTargets: [(urlStr: String, id: String, file: String, seed: String)] {
        let configured = UserDefaults.standard.data(forKey: "xsign.managedSources")
            .flatMap { try? JSONDecoder().decode([XSignCoreSourceItem].self, from: $0) }
        return resolvedManagedSources(configured).map { source in
            let known = defaultCoreTargets.first { $0.id == source.id }
            let file = known?.file ?? "managed_" + SHA256.hash(data: Data(source.url.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + ".json"
            return (source.url, source.id, file, known?.seed ?? "")
        }
    }

    @discardableResult
    func configureManagedSources(_ sources: [XSignCoreSourceItem]?) -> Bool {
        let valid = Self.resolvedManagedSources(sources)
        guard let encoded = try? JSONEncoder().encode(valid) else { return false }
        let prior = UserDefaults.standard.data(forKey: "xsign.managedSources")
        if let prior, (try? JSONDecoder().decode([XSignCoreSourceItem].self, from: prior)) == valid { return false }
        UserDefaults.standard.set(encoded, forKey: "xsign.managedSources")
        let allowed = Set(valid.map { $0.url })
        directLoadedRepos = directLoadedRepos.filter { allowed.contains($0.key) }
        repoFingerprints = repoFingerprints.filter { allowed.contains($0.key) }
        customFingerprints.removeAll()
        nextRefreshAllowed = .distantPast
        restoreBoundedLaunchPreviews()
        scheduleSnapshot(priority: .userInitiated)
        loadInstantDiskSnapshot()
        return true
    }

    func invalidateNetworkCache() {
        repoFingerprints.removeAll()
        nextRefreshAllowed = .distantPast
        for target in Self.coreTargets { UserDefaults.standard.removeObject(forKey: "XSign.catalog.etag." + target.file) }
        // Keep the visible snapshot and last good disk catalog until a valid response replaces them.
        Task { await AppStoreLiveMetadataBridge.shared.invalidateCache() }
    }

    private nonisolated static var diskCacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XSignApprovedStoreCache_v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func restoreBoundedLaunchPreviews() {
        for target in Self.coreTargets where directLoadedRepos[target.urlStr] == nil {
            let disk = Self.diskCacheDirectory.appendingPathComponent("preview_" + target.file)
            let bundle = bundledResources?.appendingPathComponent(target.seed + ".json") ?? Bundle.main.url(forResource: target.seed, withExtension: "json")
            for path in [Optional(disk), bundle].compactMap({ $0 }) {
                guard let size = (try? path.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                      size <= 131_072, let data = try? Data(contentsOf: path),
                      let record = try? XSignCatalogIO.decode(data), record.repository.apps.count <= 24 else { continue }
                directLoadedRepos[target.urlStr] = record.repository
                break
            }
        }
    }

    // Only a small first screen is prepared synchronously. The full bundled catalog is decoded off-main.
    init(catalogIO: XSignCatalogIO = .shared, bundledResources: URL? = nil) {
        ProtectedSourcesVault.migrateOldSourceCaches()
        self.catalogIO = catalogIO
        self.bundledResources = bundledResources
        restoreBoundedLaunchPreviews()
        let preview = Self.coreTargets.compactMap { target -> (URL?, String?, ASRepository)? in
            guard let repo = directLoadedRepos[target.urlStr] else { return nil }
            return (URL(string: target.urlStr).map(XSignCatalogIO.canonicalURL), target.id, repo)
        }
        if let snapshot = Self.buildSnapshot(snapshot: preview, previousItems: []) { catalog = snapshot }
        loadInstantDiskSnapshot()
    }

    private func loadInstantDiskSnapshot() {
        diskSnapshotTask?.cancel()
        let targets = Self.coreTargets
        diskSnapshotTask = Task { @MainActor [weak self] in
            for target in targets {
                guard !Task.isCancelled, let url = URL(string: target.urlStr),
                      let self, let record = await self.catalogIO.cached(url) else { continue }
                guard !Task.isCancelled, Self.coreTargets.contains(where: { $0.urlStr == target.urlStr }) else { continue }
                self.acceptRepository(record, from: url)
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
        directLoadedRepos[target.urlStr] = record.repository
        repoFingerprints[target.urlStr] = record.fingerprint
        scheduleSnapshot(priority: .userInitiated)
        let repo = record.repository
        let path = Self.diskCacheDirectory.appendingPathComponent("preview_" + target.file)
        Task.detached(priority: .utility) {
            if let preview = Self.makeLaunchPreview(repo) { try? preview.write(to: path, options: .atomic) }
        }
    }

    private func customSources(_ sources: [AltSource]) -> [AltSource] {
        let managed = Set(Self.coreTargets.compactMap { URL(string: $0.urlStr) }.map(XSignCatalogIO.canonicalURL))
        return sources.filter { source in
            guard let url = source.sourceURL.map(XSignCatalogIO.canonicalURL),
                  !ProtectedSourcesVault.isRetiredSource(url, identifier: source.identifier) else { return false }
            return !managed.contains(url) && XSignDashboardSources.isUserSource(url)
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
            await self.diskSnapshotTask?.value
            repeat {
                self.refreshAgain = false
                let custom = self.customSources(self.requestedSources)
                async let coreSucceeded = self.fetchCoreRepositories()
                // This path already passed the refresh deadline. Refresh custom URLs too,
                // even when a previous response is visible; otherwise they never update automatically.
                await viewModel.fetchSources(custom, refresh: true, batchSize: 1)
                let succeeded = await coreSucceeded
                self.rebuildCacheIfNeeded(sources: self.requestedSources, repositoriesMap: viewModel.sources)
                await self.publicationTask?.value
                if self.catalogErrorMessage == nil, !viewModel.errors.isEmpty {
                    self.catalogErrorMessage = "تعذّر تحديث أحد المصادر. البيانات المحفوظة ما زالت متاحة؛ اسحب لأسفل للمحاولة مجددًا."
                }
                self.nextRefreshAllowed = Date().addingTimeInterval(succeeded ? 300 : 15)
            } while self.refreshAgain && !Task.isCancelled
        }
        refreshTask = task
        await task.value
    }

    private func fetchCoreRepositories() async -> Bool {
        let urls = Self.coreTargets.compactMap { URL(string: $0.urlStr) }
        let revision = XSignRemoteManager.shared.currentRevisionID
        let ownerRevision: Int? = revision > 0 ? revision : nil
        var failures: [String] = []
        var successes = 0
        await withTaskGroup(of: (URL, XSignRepositoryRecord?, String?).self) { group in
            var next = 0
            for url in urls.prefix(2) {
                next += 1
                let io = catalogIO
                group.addTask {
                    do { return (url, try await io.fetch(url, ownerRevision: ownerRevision), nil) }
                    catch { return (url, nil, error.localizedDescription) }
                }
            }
            for await (url, record, message) in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let record { acceptRepository(record, from: url); successes += 1 }
                else { failures.append(message ?? "تعذّر تحديث المصدر.") }
                if next < urls.count {
                    let url = urls[next]
                    next += 1
                    let io = catalogIO
                    group.addTask {
                        do { return (url, try await io.fetch(url, ownerRevision: ownerRevision), nil) }
                        catch { return (url, nil, error.localizedDescription) }
                    }
                }
            }
        }
        catalogErrorMessage = failures.first
        return successes > 0 && failures.isEmpty
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
        guard !entries.isEmpty else {
            catalog = XSignCatalogSnapshot(); indexTask = nil; isPreparing = false
            catalogRevision &+= 1
            return
        }
        let input = entries
        let previous = allCombinedItems
        isPreparing = true
        let worker = Task.detached(priority: priority) {
            Self.buildSnapshot(snapshot: input, previousItems: previous)
        }
        indexTask = worker
        publicationTask = Task { @MainActor [weak self] in
            guard let next = await worker.value, !Task.isCancelled, let self, self.indexGeneration == generation else { return }
            self.catalog = next
            self.catalogRevision &+= 1
            self.isPreparing = false
            self.indexTask = nil
        }
    }

    private nonisolated static func makeLaunchPreview(_ repo: ASRepository) -> Data? {
        var games: [ASRepository.App] = []
        var apps: [ASRepository.App] = []
        for app in repo.apps {
            let isGame = app.isGame ?? repo.categories?.first(where: { $0.id == app.category })?.isGame
                ?? AppStore2026Category.strictlyClassify(app: app).isGameCategory
            if isGame {
                if games.count < 12 { games.append(app) }
            } else if apps.count < 12 { apps.append(app) }
            if apps.count == 12 && games.count == 12 { break }
        }
        var selected = apps + games
        if selected.count < 24 {
            let used = Set(selected.map { $0.stableCatalogIdentifier })
            selected += repo.apps.lazy.filter { !used.contains($0.stableCatalogIdentifier) }.prefix(24 - selected.count)
        }
        let page = selected.map { app -> [String: Any] in
            var item: [String: Any] = ["name": app.currentName]
            item["bundleIdentifier"] = app.id
            item["catalogID"] = app.catalogID
            item["downloadURL"] = app.currentDownloadUrl?.absoluteString
            item["iconURL"] = app.iconURL?.absoluteString
            item["version"] = app.currentVersion
            item["size"] = app.size
            item["category"] = app.category
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
        if let categories = repo.categories, let encoded = try? JSONEncoder().encode(categories) {
            root["categories"] = try? JSONSerialization.jsonObject(with: encoded)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root), data.count <= 131_072 else { return nil }
        return data
    }

    private nonisolated static func sameAppContent(_ first: ASRepository.App, _ second: ASRepository.App) -> Bool {
        var comparable = second
        comparable.uuid = first.uuid
        return first == comparable
    }

    private nonisolated static func buildSnapshot(snapshot: [(URL?, String?, ASRepository)], previousItems: [AppStoreAppItem]) -> XSignCatalogSnapshot? {
		if Task.isCancelled { return nil }
        let previousByID = Dictionary(previousItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		let totalCount = snapshot.reduce(0) { $0 + $1.2.apps.count }
		var allItems: [AppStoreAppItem] = []
		var ipaBlackOnly: [AppStoreAppItem] = []
		var ipaBlackNews: [TodayEditorialInstruction] = []
		var didIncludeIPABlackRepo = false
        var todayItems: [AppStoreAppItem] = []
        var todayNews: [TodayEditorialInstruction] = []
        var todayCategories: [ASRepository.CatalogCategory] = []
        var todayCategoryIDs = Set<String>()
        var todayFeaturedIDs: [String] = []

		allItems.reserveCapacity(totalCount)
		var seenKeys = Set<String>()
        var seenBundleNames = Set<String>()
        var seenDownloadURLs = Set<String>()

		for (sourceURL, sourceID, repo) in snapshot {
            let earlierBundleNames = seenBundleNames
            let earlierDownloadURLs = seenDownloadURLs
			let isIPABlack = ProtectedSourcesVault.isIPABlackSource(sourceURL, identifier: sourceID)
            let isTodaySource = XSignTodaySourcePolicy.allows(sourceURL)
			if isIPABlack {
				didIncludeIPABlackRepo = true
			}
			let sourceURLString = sourceURL?.absoluteString ?? ""

			var currentRepoItems: [AppStoreAppItem] = []
			currentRepoItems.reserveCapacity(repo.apps.count)

			for (index, app) in repo.apps.enumerated() {
                if index.isMultiple(of: 64) && Task.isCancelled { return nil }
				let bundleName = (app.id ?? "").lowercased() + "\u{1F}" + app.currentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let download = app.currentDownloadUrl?.absoluteString
                if sourceID?.hasPrefix("xsign.iosboom.") == true,
                   let download, earlierDownloadURLs.contains(download) { continue }
                // Prefer existing primary/store rows; only the new snapshot is filtered across sources.
                if sourceID == "xsign.core.reference",
                   earlierBundleNames.contains(bundleName) || download.map({ earlierDownloadURLs.contains($0) }) == true { continue }
                if sourceID == "xsign.core.soon.live" || sourceID == "xsign.core.ipaomtk.live",
                   earlierBundleNames.contains(bundleName) { continue }
                seenBundleNames.insert(bundleName)
                if let download { seenDownloadURLs.insert(download) }
                let uniqueKey = "\(app.stableCatalogIdentifier)_\(sourceURLString)"
				let item: AppStoreAppItem
                if let existing = previousByID[uniqueKey], Self.sameAppContent(existing.app, app),
                   existing.sourceName == (repo.name ?? "المصدر"), existing.sourceCategories == (repo.categories ?? []) {
                    item = existing
                } else {
                    item = AppStoreAppItem(
					id: uniqueKey,
					sourceURL: sourceURL,
					repository: repo,
					app: app
				)
                }
				if isIPABlack || isTodaySource {
					currentRepoItems.append(item)
				}
				if seenKeys.insert(uniqueKey).inserted {
					allItems.append(item)
				}
			}

			if isIPABlack { ipaBlackOnly.append(contentsOf: currentRepoItems) }
            if isTodaySource {
                todayItems += currentRepoItems
                todayFeaturedIDs += (repo.featuredApps ?? []).compactMap { $0 }
                for category in repo.categories ?? [] where todayCategoryIDs.insert(category.id).inserted { todayCategories.append(category) }

                let newsStart = todayNews.count
                if let newsList = repo.news {
					for newsItem in newsList {
						let matchedApp = currentRepoItems.first {
							$0.app.id == newsItem.appID
						}

						todayNews.append(
							TodayEditorialInstruction(
								id: sourceURLString + "#" + newsItem.id,
								badge: newsItem.notify ? "تنبيه" : nil,
								title: newsItem.title,
								caption: newsItem.caption,
								imageURL: newsItem.imageURL,
								tintColor: newsItem.tintColor ?? AppStoreTheme.oceanBlue,
								associatedApp: matchedApp,
                                targetURL: xsignSafeURL(newsItem.url?.absoluteString)
							)
						)
					}
				}
                if isIPABlack { ipaBlackNews += todayNews.dropFirst(newsStart) }
			}
		}

        // A conflicting copy from another source must not put the same bundle in both tabs.
        // Prefer explicit type metadata, then the configured source order.
        var bundleKinds: [String: (game: Bool, declared: Bool)] = [:]
        for item in allItems {
            guard let bundle = item.app.id?.lowercased(), !bundle.isEmpty else { continue }
            let existing = bundleKinds[bundle]
            if existing == nil || (existing?.declared == false && item.declaredGame != nil) {
                bundleKinds[bundle] = (item.isGame, item.declaredGame != nil)
            }
        }
        let categorized = allItems.filter { item in
            guard let bundle = item.app.id?.lowercased(), let kind = bundleKinds[bundle] else { return true }
            return item.isGame == kind.game
        }
        let onlyApps = categorized.filter { !$0.isGame }
        let onlyGames = categorized.filter { $0.isGame }

        let grouped = Dictionary(grouping: categorized, by: { $0.category })
		var categoryDict: [AppStore2026Category: [AppStoreAppItem]] = [:]
		for category in AppStore2026Category.allCases {
			switch category {
			case .topApps:
				categoryDict[category] = onlyApps
			case .bestSellingApps:
				categoryDict[category] = Array(onlyApps.reversed())
			case .topGames:
				categoryDict[category] = onlyGames
			case .bestSellingGames:
				categoryDict[category] = Array(onlyGames.reversed())
			case .timePass:
				let casual = onlyGames.filter { $0.category == .casualGames || $0.category == .puzzleGames }
				categoryDict[category] = casual
			default:
				let exactMatches = grouped[category] ?? []
				if !exactMatches.isEmpty {
					categoryDict[category] = exactMatches
                } else {
                    categoryDict[category] = []
                }
			}
		}

		// حصر صفحة اليوم بسورس IPABLACK فقط وعدم خلطها مع السورسات الأخرى
		let finalIPABlack = ipaBlackOnly
		let finalIPABlackNews = ipaBlackNews
		let finalAll = allItems
		let finalApps = onlyApps
		let finalGames = onlyGames
		let finalCats = categoryDict
		let shouldUpdateIPABlack = didIncludeIPABlackRepo

        if Task.isCancelled { return nil }
        return XSignCatalogSnapshot(
            ipablackItems: finalIPABlack,
            ipablackEditorialNews: finalIPABlackNews,
            allCombinedItems: finalAll,
            pureAppsOnly: finalApps,
            pureGamesOnly: finalGames,
            itemsByCategory: finalCats,
            includesIPABlack: shouldUpdateIPABlack,
            sourceName: snapshot.first(where: { ProtectedSourcesVault.isIPABlackSource($0.0, identifier: $0.1) })?.2.name ?? "IPA BLACK",
            sourceSubtitle: snapshot.first(where: { ProtectedSourcesVault.isIPABlackSource($0.0, identifier: $0.1) })?.2.subtitle ?? "",
            sourceIconURL: snapshot.first(where: { ProtectedSourcesVault.isIPABlackSource($0.0, identifier: $0.1) })?.2.iconURL,
            sourceCategories: snapshot.first(where: { ProtectedSourcesVault.isIPABlackSource($0.0, identifier: $0.1) })?.2.categories ?? [],
            skippedLookupBundleIDs: Set(finalAll.filter { $0.app.skipAppStoreLookup == true }.compactMap { $0.app.id }),
            todayItems: todayItems, todayNews: todayNews, todayCategories: todayCategories, todayFeaturedIDs: todayFeaturedIDs
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
    var pendingCount: Int { waiting.count - head }

    init() {}

    mutating func enqueue(key: String, value: Element) -> Bool {
        guard registered.insert(key).inserted else { return false }
        waiting.append(Entry(key: key, value: value))
        return true
    }

    mutating func next() -> Entry? {
        guard case nil = active else { return nil }
        guard head < waiting.count, let entry = waiting[head] else { return nil }
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
    func shouldPublish(_ percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard percent > greatest else { return false }
        greatest = percent
        return true
    }
}

// MARK: - Universal IPABlack & KhoIPA Payload Extractor + Instant ZSign
@MainActor
final class AutoSignPipelineManager: ObservableObject {
	static let shared = AutoSignPipelineManager()

	@Published var activeStates: [String: Stage] = [:]
	@Published var downloadProgress: [String: Int] = [:]
    @Published var showCertificateSetup = false
    private var pendingCertificateDownloads: [ASRepository.App] = []
    private var packagePipeline = XSignBoundedPipeline<ASRepository.App, URL>()
    private var activeNetworkTask: URLSessionDownloadTask?
    private var isCheckingDownloadPolicy = false
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
		return URLSession(configuration: config)
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

    func downloadAndAutoSign(app: ASRepository.App) {
        if let reason = XSignRemoteManager.shared.blockingReason {
            UIAlertController.showAlertWithOk(title: "تنبيه", message: reason)
            return
        }
        guard Self.fetchActiveCertificate() != nil else {
            if !pendingCertificateDownloads.contains(where: { $0.stableCatalogIdentifier == app.stableCatalogIdentifier }) {
                pendingCertificateDownloads.append(app)
            }
            showCertificateSetup = true
            return
        }
        downloadPreflightBlocked = false
        let key = app.stableCatalogIdentifier
        if let state = activeStates[key] {
            switch state {
            case .failed: activeStates.removeValue(forKey: key)
            default: return
            }
        }
        guard let url = app.currentDownloadUrl ?? app.versions?.first?.downloadURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            activeStates[key] = .failed("رابط التنزيل غير صالح.")
            return
        }
        guard packagePipeline.enqueue(key: key, job: app) else { return }
        activeStates[key] = .queued
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        startNextDownload()
    }

    func resumeAfterCertificateSetup() {
        let pending = pendingCertificateDownloads
        pendingCertificateDownloads = []
        refreshCertificateCache()
        guard cachedCertificate != nil else { return }
        for app in pending { downloadAndAutoSign(app: app) }
    }

    func applyRemotePolicy() {
        if XSignRemoteManager.shared.blockingReason != nil {
            activeNetworkTask?.cancel()
        } else {
            downloadPreflightBlocked = false
            startNextProcessing()
            startNextDownload()
        }
    }

    private func startNextDownload() {
        guard packagePipeline.canStartDownload, !isCheckingDownloadPolicy, !downloadPreflightBlocked,
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
        guard XSignRemoteManager.shared.blockingReason == nil,
              let entry = packagePipeline.takeDownload() else { return }
        let app = entry.value
        let key = entry.key
        guard let url = app.currentDownloadUrl ?? app.versions?.first?.downloadURL else {
            failNetworkDownload(key: key, message: "رابط التنزيل غير صالح.")
            return
        }
        activeStates[key] = .downloading
        downloadProgress[key] = 0
        var request = URLRequest(url: url)
        request.setValue("X-SIGN/2.0", forHTTPHeaderField: "User-Agent")
        let task = turboSession.downloadTask(with: request) { [weak self] location, response, error in
            guard let self else { return }
            guard error == nil, let location,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Task { @MainActor in
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
                try FileManager.default.moveItem(at: location, to: file)
            } catch {
                try? FileManager.default.removeItem(at: file)
                Task { @MainActor in self.failNetworkDownload(key: key, message: error.localizedDescription) }
                return
            }
            Task { @MainActor in self.receivedPackage(file, key: key) }
        }
        let progressGate = XSignDownloadProgressGate()
        progressObservations[key] = task.progress.observe(\Progress.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            guard fraction.isFinite else { return }
            let percent = Int(max(0, min(99, fraction * 100)))
            guard progressGate.shouldPublish(percent) else { return }
            Task { @MainActor in
                guard let self, self.activeStates[key] == .downloading else { return }
                // At most 100 progress publications per download, regardless of chunk count.
                if self.downloadProgress[key] != percent { self.downloadProgress[key] = percent }
            }
        }
        activeNetworkTask = task
        task.priority = URLSessionTask.highPriority
        task.resume()
    }

    private func receivedPackage(_ file: URL, key: String) {
        guard packagePipeline.activeDownload?.key == key else {
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
        progressObservations.removeValue(forKey: key)
        downloadProgress.removeValue(forKey: key)
        activeStates[key] = .preparing
        // These two lanes overlap without opening a second simultaneous download.
        startNextProcessing()
        startNextDownload()
    }

    private func startNextProcessing() {
        guard XSignRemoteManager.shared.blockingReason == nil,
              let entry = packagePipeline.takeProcessing() else { return }
        let key = entry.key
        let file = entry.file
        activeStates[key] = .preparing
        refreshCertificateCache()
        FR.importPackageFile(file, consumeTemporaryFile: true) { [weak self] result in
            try? FileManager.default.removeItem(at: file)
            guard let self else { return }
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
        progressObservations.removeValue(forKey: key)
        downloadProgress.removeValue(forKey: key)
        activeStates[key] = .failed(message)
        startNextProcessing()
        startNextDownload()
    }

    private func finishDownload(key: String, error: String?) {
        guard packagePipeline.finishProcessing(key: key) else { return }
        if let error { activeStates[key] = .failed(error) }
        startNextProcessing()
        startNextDownload()
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
			Text(topTitle)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(.secondary)
			Text(mainValue)
				.font(.system(size: 20, weight: .heavy, design: .rounded))
				.foregroundStyle(Color.primary.opacity(0.9))
			Text(bottomText)
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
				Text(label)
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

// MARK: - 1. TODAY VIEW (Exclusively from IPA BLACK Source)
struct AppStoreTodayView: View {
    @StateObject private var viewModel = SourcesViewModel.shared
    @StateObject private var cache = AppStoreCacheManager.shared
    @State private var showSettingsSheet = false
    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)])
    private var sources: FetchedResults<AltSource>

    private var todayApps: [AppStoreAppItem] { cache.todayItems }

    var body: some View {
        XSignNavigationView {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text("اليوم").font(.largeTitle.bold())
                        }
                        Spacer()
                        AppStoreAccountAppIconButton { showSettingsSheet = true }
                    }.padding(.top, 12)

                    XSignClassicStoreContent(page: "today")
                    if todayApps.isEmpty {
                        AppStore2026EmptyState(isLoading: cache.isRefreshing || cache.isPreparing,
                            emptyMessage: "لا توجد تطبيقات متاحة الآن.",
                            retry: { Task { await cache.forceRefresh(sources: sources, viewModel: viewModel) } })
                    }
                }.padding(.horizontal, 20).padding(.bottom, 110)
            }
            .background(AppStoreTheme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await cache.forceRefresh(sources: sources, viewModel: viewModel) }
            .sheet(isPresented: $showSettingsSheet, onDismiss: { XSignInstallation.shared.resumeIfPossible() }) {
                AppStore2026SettingsPopup(sources: sources, viewModel: viewModel)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task(id: sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            await cache.ensureFetched(sources: sources, viewModel: viewModel)
        }
    }
}

struct XSignTodayFeatureCard: View {
    let item: AppStoreAppItem
    let sourceName: String
    var body: some View {
        VStack(spacing: 0) {
            NavigationLink { AppStore2026DetailView(item: item) } label: {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [.init(red: 0.01, green: 0.10, blue: 0.25), .init(red: 0.02, green: 0.28, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let artwork = item.screenshots.first {
                        LazyImage(url: artwork) { state in
                            if let image = state.image { image.resizable().scaledToFill().opacity(0.5) }
                        }.processors([.resize(size: CGSize(width: 700, height: 700))])
                    } else {
                        VStack {
                            Spacer(minLength: 16)
                            AppStoreIconView(url: item.app.iconURL, bundleID: item.app.id, appName: item.app.currentName, size: 132)
                                .rotationEffect(.degrees(-9)).shadow(color: .black.opacity(0.3), radius: 18, y: 12)
                            Spacer(minLength: 120)
                        }.frame(maxWidth: .infinity)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("اختيار XSIGN").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.white.opacity(0.8))
                        Text(item.app.currentName).font(.system(.largeTitle, design: .rounded).bold()).lineLimit(2)
                        Text(item.arabicSubtitle).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.white.opacity(0.85))
                    }.foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }.frame(height: 350).clipped()
            }.buttonStyle(.plain)
            HStack(spacing: 12) {
                NavigationLink { AppStore2026DetailView(item: item) } label: {
                    HStack(spacing: 12) {
                        AppStoreIconView(url: item.app.iconURL, size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.app.currentName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text("توقيع عبر XSign").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                AppStore2026DownloadButton(app: item.app)
            }.padding(16).background(AppStoreTheme.cardSurface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 7)
    }
}

struct XSignTodaySmallCard: View {
    let item: AppStoreAppItem
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AppStoreIconView(url: item.app.iconURL, size: 64)
                Spacer(minLength: 0)
            }
            Text(item.category.rawValue).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).lineLimit(1)
            Text(item.app.currentName).font(.headline).foregroundStyle(.primary).lineLimit(2)
            Text(item.arabicSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .padding(16).background(AppStoreTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - 2. APPS VIEW
struct SourcesView: View {
	@StateObject var viewModel = SourcesViewModel.shared
	@StateObject private var cache = AppStoreCacheManager.shared
	@AppStorage("Feather.userTintColor") private var userTintHex: String = "#005BBB"
	@State private var _isSettingsPresenting = false
	@State private var _selectedAppCategory: AppStore2026Category? = nil

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>

	private let appOnlyCategories: [AppStore2026Category] = [
		.social,
		.photoVideo,
		.mediaReaders,
		.devTools,
		.visualArts,
		.productivity
	]

	private var filteredPureApps: [AppStoreAppItem] {
		guard let selected = _selectedAppCategory else {
			return cache.pureAppsOnly
		}
		return cache.itemsByCategory[selected] ?? []
	}

	private var accentColor: Color {
		Color(hex: userTintHex)
	}

	var body: some View {
		XSignNavigationView {
			ScrollView(.vertical, showsIndicators: false) {
				LazyVStack(alignment: .leading, spacing: 24) {
					AppStore2026TopHeader(
						title: "التطبيقات",
						onSettingsTap: { _isSettingsPresenting = true }
					)

					if cache.pureAppsOnly.isEmpty {
                        AppStore2026EmptyState(isLoading: cache.isRefreshing || cache.isPreparing,
                            emptyMessage: "لا توجد تطبيقات متاحة الآن.",
                            retry: { Task { await cache.forceRefresh(sources: _sources, viewModel: viewModel) } })
							.padding(.horizontal, 18)
							.padding(.top, 30)
					} else {
						ScrollView(.horizontal, showsIndicators: false) {
							HStack(spacing: 10) {
								Button {
									_selectedAppCategory = nil
								} label: {
									Text("الكل")
										.font(.subheadline.weight(.bold))
										.foregroundStyle(_selectedAppCategory == nil ? AppStoreTheme.contrastingText(forHex: userTintHex) : Color.primary)
										.padding(.horizontal, 18)
										.padding(.vertical, 9)
										.background(
											Capsule(style: .continuous)
												.fill(_selectedAppCategory == nil ? accentColor : AppStoreTheme.controlSurface)
										)
								}
								.buttonStyle(.plain)

								ForEach(appOnlyCategories.filter { !(cache.itemsByCategory[$0] ?? []).isEmpty }) { cat in
									Button {
										_selectedAppCategory = cat
									} label: {
										HStack(spacing: 6) {
											Image(systemName: cat.sfSymbol)
												.font(.caption)
											Text(cat.rawValue)
												.font(.subheadline.weight(.bold))
										}
										.foregroundStyle(_selectedAppCategory == cat ? AppStoreTheme.contrastingText(forHex: userTintHex) : Color.primary)
										.padding(.horizontal, 16)
										.padding(.vertical, 9)
										.background(
											Capsule(style: .continuous)
												.fill(_selectedAppCategory == cat ? accentColor : AppStoreTheme.controlSurface)
										)
									}
									.buttonStyle(.plain)
								}
							}
							.padding(.horizontal, 18)
						}

                        XSignClassicStoreContent(page: "apps", category: _selectedAppCategory).padding(.horizontal, 18)
					}
				}
				.padding(.bottom, 100)
			}
			.background(AppStoreTheme.background.ignoresSafeArea())
			.navigationBarHidden(true)
			.refreshable {
				await cache.forceRefresh(sources: _sources, viewModel: viewModel)
			}
			.sheet(isPresented: $_isSettingsPresenting, onDismiss: { XSignInstallation.shared.resumeIfPossible() }) {
				AppStore2026SettingsPopup(sources: _sources, viewModel: viewModel)
			}
		}
		.environment(\.layoutDirection, .rightToLeft)
        .task(id: _sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            await cache.ensureFetched(sources: _sources, viewModel: viewModel)
        }
	}
}

// MARK: - 3. GAMES VIEW
struct AppStoreGamesView: View {
	@StateObject private var viewModel = SourcesViewModel.shared
	@StateObject private var cache = AppStoreCacheManager.shared
	@AppStorage("Feather.userTintColor") private var userTintHex: String = "#005BBB"
	@State private var showSettingsSheet = false
	@State private var selectedGameCategory: AppStore2026Category? = nil

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>

	private let gameOnlyCategories: [AppStore2026Category] = [
		.pvpGames,
		.simulationGames,
		.strategyGames,
		.puzzleGames,
		.casualGames
	]

	private var displayedGames: [AppStoreAppItem] {
		guard let selected = selectedGameCategory else {
			return cache.pureGamesOnly
		}
		return cache.itemsByCategory[selected] ?? []
	}

	private var accentColor: Color {
		Color(hex: userTintHex)
	}

	var body: some View {
		XSignNavigationView {
			ScrollView(.vertical, showsIndicators: false) {
				LazyVStack(alignment: .leading, spacing: 24) {
					AppStore2026TopHeader(
						title: "الألعاب",
						onSettingsTap: { showSettingsSheet = true }
					)

					if cache.pureGamesOnly.isEmpty {
                        AppStore2026EmptyState(isLoading: cache.isRefreshing || cache.isPreparing,
                            emptyMessage: "لا توجد تطبيقات متاحة الآن.",
                            retry: { Task { await cache.forceRefresh(sources: _sources, viewModel: viewModel) } })
							.padding(.horizontal, 18)
							.padding(.top, 20)
					} else {
						ScrollView(.horizontal, showsIndicators: false) {
							HStack(spacing: 10) {
								Button {
									selectedGameCategory = nil
								} label: {
									Text("كل الألعاب")
										.font(.subheadline.weight(.bold))
										.foregroundStyle(selectedGameCategory == nil ? AppStoreTheme.contrastingText(forHex: userTintHex) : Color.primary)
										.padding(.horizontal, 18)
										.padding(.vertical, 9)
										.background(
											Capsule(style: .continuous)
												.fill(selectedGameCategory == nil ? accentColor : AppStoreTheme.controlSurface)
										)
								}
								.buttonStyle(.plain)

								ForEach(gameOnlyCategories.filter { !(cache.itemsByCategory[$0] ?? []).isEmpty }) { cat in
									Button {
										selectedGameCategory = cat
									} label: {
										HStack(spacing: 6) {
											Image(systemName: cat.sfSymbol)
												.font(.caption)
											Text(cat.rawValue)
												.font(.subheadline.weight(.bold))
										}
										.foregroundStyle(selectedGameCategory == cat ? AppStoreTheme.contrastingText(forHex: userTintHex) : Color.primary)
										.padding(.horizontal, 16)
										.padding(.vertical, 9)
										.background(
											Capsule(style: .continuous)
												.fill(selectedGameCategory == cat ? accentColor : AppStoreTheme.controlSurface)
										)
									}
									.buttonStyle(.plain)
								}
							}
							.padding(.horizontal, 18)
						}

                        XSignClassicStoreContent(page: "games", category: selectedGameCategory).padding(.horizontal, 18)
					}
				}
				.padding(.bottom, 100)
			}
			.background(AppStoreTheme.background.ignoresSafeArea())
			.navigationBarHidden(true)
			.refreshable {
				await cache.forceRefresh(sources: _sources, viewModel: viewModel)
			}
			.sheet(isPresented: $showSettingsSheet, onDismiss: { XSignInstallation.shared.resumeIfPossible() }) {
				AppStore2026SettingsPopup(sources: _sources, viewModel: viewModel)
			}
		}
		.environment(\.layoutDirection, .rightToLeft)
        .task(id: _sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            await cache.ensureFetched(sources: _sources, viewModel: viewModel)
        }
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
                        }.padding(12).background(AppStoreTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 18)
                    }
					if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        XSignCatalogCategories(cache: cache)
						VStack(alignment: .leading, spacing: 14) {
							HStack(spacing: 6) {
								Text("تصفح")
									.font(.system(size: 22, weight: .bold))
									.foregroundStyle(.primary)
								Image(systemName: "chevron.left")
									.font(.system(size: 16, weight: .bold))
									.foregroundStyle(.secondary)
								Spacer()
							}
							.padding(.horizontal, 18)

							LazyVGrid(
								columns: [
									GridItem(.flexible(), spacing: 12),
									GridItem(.flexible(), spacing: 12)
								],
								spacing: 12
							) {
								ForEach(AppStore2026Category.allCases.filter { !(cache.itemsByCategory[$0] ?? []).isEmpty }) { category in
									let catApps = cache.itemsByCategory[category] ?? []
									NavigationLink {
										AppStore2026CategoryListView(
											category: category,
											items: catApps
										)
									} label: {
										AppStore2026BrowseCategoryTile(
											category: category,
											previewApps: Array(catApps.prefix(2))
										)
									}
									.buttonStyle(.plain)
								}
							}
							.padding(.horizontal, 18)
						}
					} else {
                        HStack {
                            if results.isSearching { ProgressView().controlSize(.small); Text("جاري البحث…") }
                            else { Text("\(results.total) نتيجة") }
                            Spacer()
                        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18)
						LazyVStack(spacing: 14) {
							if results.visible.isEmpty && !results.isSearching {
								VStack(spacing: 12) {
									Image(systemName: "magnifyingglass")
										.font(.system(size: 42))
										.foregroundStyle(.secondary)
									Text("لا توجد نتائج لـ \"\(searchText)\"")
										.font(.headline)
										.foregroundStyle(.primary)
								}
								.frame(maxWidth: .infinity)
								.padding(.top, 60)
							} else {
								ForEach(results.visible) { item in
                                    AppStore2026AppRow(item: item)
								}
							}
                            if results.visible.count < results.total && !results.isSearching {
                                Color.clear.frame(height: 1).accessibilityHidden(true)
                                    .id(results.visible.count)
                                    .onAppear { results.showMore() }
                            }
						}
						.padding(.horizontal, 18)
					}
				}
				.padding(.bottom, 110)
			}
			.background(AppStoreTheme.background.ignoresSafeArea())
			.navigationBarHidden(true)
			.onChange(of: searchText) { newQuery in
				triggerBackgroundSearch(query: newQuery)
			}
            .onChange(of: cache.catalogRevision) { _ in triggerBackgroundSearch(query: searchText) }
            .onDisappear { results.cancel() }
			.sheet(isPresented: $showSettingsSheet, onDismiss: { XSignInstallation.shared.resumeIfPossible() }) {
				AppStore2026SettingsPopup(sources: _sources, viewModel: viewModel)
			}
		}
		.environment(\.layoutDirection, .rightToLeft)
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

	var body: some View {
		HStack(alignment: .center) {
			Text(title)
				.font(.system(size: 34, weight: .heavy))
				.foregroundStyle(.primary)

			Spacer()

			AppStoreAccountAppIconButton(action: onSettingsTap)
		}
		.padding(.horizontal, 18)
		.padding(.top, 10)
	}
}

struct AppStoreAccountAppIconButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FRAppIconView(size: 38)
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.28), lineWidth: 1.1)
                }
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
					Text(outerTitle)
						.font(.system(size: 22, weight: .heavy))
						.foregroundStyle(.primary)
					if let outerSubtitle {
						Text(outerSubtitle)
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
								LazyImage(url: bannerURL) { state in
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
									Text(eventTag)
										.font(.system(size: 13, weight: .bold))
										.foregroundStyle(.white.opacity(0.9))

									Text(headline)
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

					Text(cornerBadge)
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
						Text(item.arabicSubtitle)
							.font(.system(size: 13))
							.foregroundStyle(.white.opacity(0.8))
							.lineLimit(1)
					}

					Spacer(minLength: 8)

					AppStore2026DownloadButton(app: item.app, isLightPill: true)
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
						Text(outerTitle)
							.font(.system(size: 22, weight: .heavy))
							.foregroundStyle(.primary)
					}
					if let outerSubtitle {
						Text(outerSubtitle)
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
							Text(caption)
								.font(.system(size: 13, weight: .bold))
								.foregroundStyle(.white.opacity(0.88))

							Text(headline)
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

struct TodayFourAppsListCard: View {
	let outerTitle: String?
	let outerSubtitle: String?
	let innerCaption: String
	let innerTitle: String
	let items: [AppStoreAppItem]

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			if let outerTitle {
				VStack(alignment: .leading, spacing: 3) {
					Text(outerTitle)
						.font(.system(size: 22, weight: .heavy))
						.foregroundStyle(.primary)
					if let outerSubtitle {
						Text(outerSubtitle)
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
				.padding(.horizontal, 4)
			}

			VStack(alignment: .leading, spacing: 18) {
				VStack(alignment: .leading, spacing: 4) {
					Text(innerCaption)
						.font(.system(size: 13, weight: .bold))
						.foregroundStyle(.secondary)
					Text(innerTitle)
						.font(.system(size: 26, weight: .heavy))
						.foregroundStyle(.primary)
						.lineLimit(2)
						.multilineTextAlignment(.leading)
				}

				VStack(spacing: 14) {
					ForEach(Array(items.prefix(4).enumerated()), id: \.element.id) { index, item in
                        AppStore2026AppRow(item: item)

						if index < min(items.count, 4) - 1 {
							Divider()
								.background(Color.primary.opacity(0.08))
								.padding(.leading, 70)
						}
					}
				}
			}
			.padding(20)
			.frame(maxWidth: .infinity)
			.background(
				RoundedRectangle(cornerRadius: 28, style: .continuous)
					.fill(AppStoreTheme.cardSurface)
			)
			.overlay(
				RoundedRectangle(cornerRadius: 28, style: .continuous)
					.stroke(Color.primary.opacity(0.07), lineWidth: 0.6)
			)
		}
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
						LazyImage(url: firstScreen) { state in
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
						Circle()
							.fill(.ultraThinMaterial)
							.frame(width: 58, height: 58)
							.overlay {
								Image(systemName: "play.fill")
									.font(.system(size: 22))
									.foregroundStyle(.white)
									.offset(x: 2)
							}
							.offset(y: -30)
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
							Text(categoryTag)
								.font(.system(size: 13, weight: .bold))
								.foregroundStyle(.white.opacity(0.88))
							Text(headline)
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
					Text(item.category.rawValue)
						.font(.caption)
						.foregroundStyle(.white.opacity(0.75))
						.lineLimit(1)
				}

				Spacer(minLength: 8)

				AppStore2026DownloadButton(app: item.app, isLightPill: true)
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
	let sources: FetchedResults<AltSource>
	@ObservedObject var viewModel: SourcesViewModel
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
							Text("الإعدادات والشهادات")
								.font(.caption)
								.foregroundStyle(.secondary)
						}

						Spacer()

						Button("تم") {
							dismiss()
						}
						.font(.body.weight(.bold))
					}

					Picker("", selection: $selectedSection) {
						Text("الإعدادات").tag(0)
						Text("الشهادات").tag(1)
					}
					.pickerStyle(.segmented)
				}
				.padding(.horizontal, 18)
				.padding(.vertical, 12)
				.background(AppStoreTheme.cardSurface)

				if selectedSection == 0 {
					SettingsView()
				} else {
					CertificatesView()
				}
			}
			.navigationBarHidden(true)
		}
		.environment(\.layoutDirection, .rightToLeft)
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
					TextField("https://example.com/repo.json", text: $sourceURLText)
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
                if let errorMessage { Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) } }
			}
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
		.environment(\.layoutDirection, .rightToLeft)
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
	var isLightPill: Bool = false
    var showsFootnote: Bool = true
	@ObservedObject private var pipeline = AutoSignPipelineManager.shared
	@AppStorage("Feather.userTintColor") private var userTintHex: String = "#005BBB"

	private var accentColor: Color {
		Color(hex: userTintHex)
	}

	private var appKey: String {
		app.stableCatalogIdentifier
	}

    private var canDownload: Bool {
        app.currentDownloadUrl.flatMap { XSignManagedSource.httpsURL($0.absoluteString) } != nil
    }

	private var currentStage: AutoSignPipelineManager.Stage? {
		pipeline.activeStates[appKey]
	}

	private var progressPercent: Int {
		pipeline.downloadProgress[appKey] ?? 0
	}

	var body: some View {
		Button {
			pipeline.downloadAndAutoSign(app: app)
		} label: {
			switch currentStage {
            case .queued:
                Label("بالانتظار", systemImage: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 82, height: 32)
                    .background(AppStoreTheme.controlSurface, in: Capsule())
            case .failed(let message):
                VStack(spacing: 3) {
                    Label("أعد المحاولة", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 82, height: 32)
                        .background(AppStoreTheme.controlSurface, in: Capsule())
                    Text(message)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(width: 100)
                }
                .accessibilityHint(message)
			case .downloading:
				HStack(spacing: 5) {
					ProgressView()
						.tint(AppStoreTheme.contrastingText(forHex: userTintHex))
						.scaleEffect(0.72)
					Text("\(progressPercent)%")
						.font(.system(size: 12, weight: .heavy, design: .rounded))
						.monospacedDigit()
						.foregroundStyle(AppStoreTheme.contrastingText(forHex: userTintHex))
				}
				.frame(width: 82, height: 32)
				.background(Capsule().fill(accentColor))

			case .preparing, .signing:
				HStack(spacing: 4) {
					Image(systemName: "bolt.fill")
						.font(.system(size: 11, weight: .bold))
					Text(currentStage == .preparing ? "تجهيز..." : "توقيع...")
						.font(.system(size: 11, weight: .bold))
				}
				.foregroundStyle(AppStoreTheme.contrastingText(forHex: userTintHex))
				.frame(width: 82, height: 32)
				.background(Capsule().fill(accentColor))

			case .ready:
				HStack(spacing: 4) {
					Image(systemName: "checkmark")
						.font(.system(size: 11, weight: .bold))
					Text("تم التوقيع")
						.font(.system(size: 11, weight: .bold))
				}
				.foregroundStyle(.white)
				.frame(width: 78, height: 32)
				.background(Capsule().fill(Color.green))

			case nil:
				VStack(spacing: 3) {
					Text(canDownload ? "تنزيل" : "غير متاح")
						.font(.system(size: 15, weight: .bold))
						.foregroundStyle(canDownload ? AppStoreTheme.contrastingText(forHex: userTintHex) : Color.secondary)
						.frame(width: 78, height: 32)
						.background(
							Capsule(style: .continuous)
								.fill(canDownload ? accentColor : AppStoreTheme.controlSurface)
						)

                    if showsFootnote {
					Text(canDownload ? "توقيع عبر XSign" : "لا يتوفر ملف IPA")
						.font(.system(size: 7.5, weight: .medium))
						.foregroundStyle(isLightPill ? .white.opacity(0.75) : .secondary)
						.lineLimit(1)
                    }
				}
			}
		}
		.buttonStyle(.plain)
		.disabled(currentStage == .ready || (currentStage == nil && !canDownload))
	}
}

struct AppStore2026AppRow: View {
    let item: AppStoreAppItem

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                AppStore2026DetailView(item: item)
            } label: {
                HStack(spacing: 12) {
                    AppStoreIconView(url: item.app.iconURL, bundleID: item.app.id,
                                     appName: item.app.currentName, size: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.app.currentName).font(.subheadline.bold()).lineLimit(1)
                        if let version = item.app.currentVersion, !version.isEmpty {
                            Text("الإصدار \(version)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(item.arabicSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            AppStore2026DownloadButton(app: item.app, showsFootnote: false)
        }
        .padding(10)
        .xsignSurface(radius: 16)
    }
}

struct AppStore2026BrowseCategoryTile: View {
	let category: AppStore2026Category
	let previewApps: [AppStoreAppItem]

	var body: some View {
		ZStack {
            AppStoreTheme.cardSurface

			Group {
				if previewApps.count >= 2 {
					ZStack {
						AppStoreIconView(
							url: previewApps[1].app.iconURL,
							bundleID: previewApps[1].app.id,
							appName: previewApps[1].app.currentName,
							size: 40
						)
						.rotationEffect(.degrees(12))
						.offset(x: -14, y: 8)

						AppStoreIconView(
							url: previewApps[0].app.iconURL,
							bundleID: previewApps[0].app.id,
							appName: previewApps[0].app.currentName,
							size: 44
						)
						.rotationEffect(.degrees(-10))
						.offset(x: 10, y: -4)
					}
				} else {
					Image(systemName: category.sfSymbol)
						.font(.system(size: 38, weight: .bold))
						.foregroundStyle(Color.accentColor)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
			.padding(.top, 14)
			.padding(.trailing, 18)

			Text(category.rawValue)
				.font(.system(size: 16, weight: .bold))
				.foregroundStyle(.primary)
				.multilineTextAlignment(.leading)
				.lineLimit(2)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
				.padding(14)
		}
		.frame(height: 102)
		.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
	}
}

struct AppStore2026CategoryListView: View {
    let category: AppStore2026Category
    let items: [AppStoreAppItem]
    var customTitle: String? = nil

    var body: some View {
        ScrollView(showsIndicators: false) {
            XSignCatalogueFeed(items: items).padding(18)
        }
        .background(AppStoreTheme.background.ignoresSafeArea())
        .navigationTitle(customTitle ?? category.rawValue)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

struct AppStoreIconView: View {
	let url: URL?
	var bundleID: String? = nil
	var appName: String = ""
	let size: CGFloat
	@State private var appleIconURL: URL? = nil

	private var isFallbackGitHubIcon: Bool {
		guard let u = url?.absoluteString.lowercased() else { return true }
		return u.contains("github.com/ipa-black.png") || u.hasSuffix("/assets/icon.png")
	}

	var body: some View {
		Group {
			let effectiveURL = url ?? appleIconURL
			if let effectiveURL {
				LazyImage(url: effectiveURL) { state in
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
			if (url == nil || isFallbackGitHubIcon) && !appName.isEmpty && !AppStoreLiveMetadataBridge.hasExtractedGitHubIcon(url) && !AppStoreCacheManager.shared.shouldSkipStoreLookup(bundleID) {
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
            Text(isLoading ? "جاري تحديث المصادر…" : emptyMessage)
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(.primary)
            if !isLoading, let retry { Button("إعادة المحاولة", action: retry) }
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
private struct XSignSourceIdentity: View {
    @ObservedObject var cache: AppStoreCacheManager
    var body: some View {
        HStack(spacing: 12) {
            AppStoreIconView(url: cache.sourceIconURL, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(cache.sourceName).font(.headline)
                if !cache.sourceSubtitle.isEmpty { Text(cache.sourceSubtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }.padding(.horizontal, 18)
    }
}

private struct XSignCatalogCategories: View {
    @ObservedObject var cache: AppStoreCacheManager
    var body: some View {
        if !cache.sourceCategories.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("تصنيفات \(cache.sourceName)")
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 18)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(cache.sourceCategories) { category in
                            NavigationLink {
                                AppStore2026CategoryListView(category: .topApps,
                                    items: cache.ipablackItems.filter { $0.app.category == category.id },
                                    customTitle: category.name)
                            } label: {
                                Text(category.name).font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(AppStoreTheme.controlSurface, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 18)
                }
            }
        }
    }
}

struct XSignAnnouncementCard: View {
    let instruction: TodayEditorialInstruction
    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let badge = instruction.badge { Text(badge).font(.caption.bold()).foregroundStyle(Color.accentColor) }
            Text(instruction.title).font(.title3.bold())
            Text(instruction.caption).font(.subheadline).foregroundStyle(.secondary)
            if instruction.targetURL != nil { Image(systemName: "arrow.up.left.square").foregroundStyle(Color.accentColor) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(AppStoreTheme.cardSurface, in: RoundedRectangle(cornerRadius: 18))
    }
    var body: some View {
        if let url = instruction.targetURL { Link(destination: url) { content }.buttonStyle(.plain) }
        else if let app = instruction.associatedApp {
            NavigationLink { AppStore2026DetailView(item: app) } label: { content }.buttonStyle(.plain)
        } else { content }
    }
}
