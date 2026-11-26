//
//  Repository.swift
//  Feather
//
//  Created by Lakhan Lothiyi on 19/04/2025.
//

import Foundation
import SwiftUI

// Evidently, every repo is silly, they all have slightly different formats :c
// only altstore repo (ofc) has the correct format.
// we're going to use a defensive approach and try to parse many repos.

private extension KeyedDecodingContainer {
    func categoryText(_ key: Key) -> String? {
        let raw = (try? decode(String.self, forKey: key)) ??
            (try? decode(Int.self, forKey: key)).map(String.init)
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    func flexibleBool(_ key: Key) -> Bool? {
        if let flag = try? decode(Bool.self, forKey: key) { return flag }
        switch categoryText(key)?.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }
}

private struct ASCategoryReference: Decodable {
    let value: String?
    enum CodingKeys: String, CodingKey { case id, value, categoryId, category_id, slug, name, label, title }
    init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let text = try? single.decode(String.self) { value = text; return }
        if let number = try? single.decode(Int.self) { value = String(number); return }
        let fields = try? decoder.container(keyedBy: CodingKeys.self)
        let keys: [CodingKeys] = [.id, .value, .categoryId, .category_id, .slug, .name, .label, .title]
        value = keys.lazy.compactMap { fields?.categoryText($0) }.first
    }
}

private struct ASOptionalRecord<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Repository

public struct ASRepository: Sendable, Decodable, Hashable, Identifiable {
	// Core data
	public var id: String?
	public var name: String?

	// descriptive fields
	public var subtitle: String?
	public var description: String?
	public var website: URL?
	public var iconURL: URL?
	public var headerURL: URL?
	public var tintColor: Color?

	// special fields
	public var patreonURL: URL?
	public var userInfo: UserInfo?

	// apps, news etc.
	public var apps: [App]
	public var featuredApps: [App.ID]?
	public var news: [News]?
    public var categories: [CatalogCategory]?
    public struct CatalogCategory: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var isGame: Bool?
        public var aliases: [String]?
        public var iconSVG: String?

        public init(id: String, name: String, isGame: Bool? = nil, aliases: [String]? = nil, iconSVG: String? = nil) {
            self.id = id
            self.name = name
            self.isGame = isGame
            self.aliases = aliases
            self.iconSVG = iconSVG
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, isGame, aliases, iconSVG, icon_svg, value, label, title, slug, categoryId, category_id, is_game
        }

        public init(from decoder: any Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let raw = try? single.decode(String.self), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.init(id: raw.trimmingCharacters(in: .whitespacesAndNewlines), name: raw.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            if let number = try? single.decode(Int.self) {
                self.init(id: String(number), name: String(number))
                return
            }
            let row = try decoder.container(keyedBy: CodingKeys.self)
            let nameKeys: [CodingKeys] = [.name, .label, .title]
            let idKeys: [CodingKeys] = [.id, .value, .categoryId, .category_id, .slug]
            let title = nameKeys.lazy.compactMap { row.categoryText($0) }.first
            guard let id = idKeys.lazy.compactMap({ row.categoryText($0) }).first ?? title else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: row, debugDescription: "Missing category identity.")
            }
            let alternatives = (try? row.decode([ASCategoryReference].self, forKey: .aliases))?.compactMap(\.value)
            self.init(id: id, name: title ?? id, isGame: row.flexibleBool(.isGame) ?? row.flexibleBool(.is_game), aliases: alternatives,
                      iconSVG: (try? row.decode(String.self, forKey: .icon_svg)) ?? (try? row.decode(String.self, forKey: .iconSVG)))
        }

        public func encode(to encoder: any Encoder) throws {
            var row = encoder.container(keyedBy: CodingKeys.self)
            try row.encode(id, forKey: .id)
            try row.encode(name, forKey: .name)
            try row.encodeIfPresent(isGame, forKey: .isGame)
            try row.encodeIfPresent(aliases, forKey: .aliases)
            try row.encodeIfPresent(iconSVG, forKey: .icon_svg)
        }
    }

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try container.decodeIfPresent(String.self, forKey: .id)
		self.name = try container.decodeIfPresent(String.self, forKey: .name)

		self.subtitle = try container.decodeIfPresent(
			String.self,
			forKey: .subtitle
		)
		self.description = try container.decodeIfPresent(
			String.self,
			forKey: .description
		)
		self.website = try container.decodeIfPresent(URL.self, forKey: .website)
		self.iconURL = try container.decodeIfPresent(
			URL.self,
			forKey: .iconURL
		)
		self.headerURL = try container.decodeIfPresent(
			URL.self,
			forKey: .headerURL
		)
		self.tintColor =
			try container.decodeIfPresent(Color.self, forKey: .tintColor)

		let patreonString = try container.decodeIfPresent(String.self, forKey: .patreonURL)
		
		// another case of inconsistent altstore stuff
		if
			let string = patreonString,
			!string.isEmpty,
			let url = URL(string: string)
		{
			self.patreonURL = url
		} else {
			self.patreonURL = nil
		}

		self.userInfo = try container.decodeIfPresent(
			UserInfo.self,
			forKey: .userInfo
		)

		let decodedApps = try container.decodeIfPresent([App].self, forKey: .apps)
		let decodedGames = try? container.decodeIfPresent([App].self, forKey: .games)
		guard
			decodedApps != nil || decodedGames != nil
		else {
			throw NSError(
				domain: "FeatherSources",
				code: 44521,
				userInfo: [
					NSLocalizedDescriptionKey: "This source does not contain any apps."
				]
			)
		}
		
        func decodeCategories(_ key: CodingKeys) -> [CatalogCategory] {
            if let rows = try? container.decode([ASOptionalRecord<CatalogCategory>].self, forKey: key) {
                return rows.compactMap(\.value)
            }
            if let rows = try? container.decode([String: String].self, forKey: key) {
                return rows.keys.sorted().compactMap { id in rows[id].map { CatalogCategory(id: id, name: $0) } }
            }
            return []
        }
        var categories = decodeCategories(.categories)
        for var game in decodeCategories(.gameCategories) {
            game.isGame = true
            if let index = categories.firstIndex(where: { $0.id.caseInsensitiveCompare(game.id) == .orderedSame }) {
                categories[index].isGame = true
                if categories[index].name == categories[index].id { categories[index].name = game.name }
                if let aliases = game.aliases { categories[index].aliases = (categories[index].aliases ?? []) + aliases }
            } else {
                categories.append(game)
            }
        }
        self.categories = categories.isEmpty ? nil : categories
        let games = (decodedGames ?? []).map { entry -> App in
            var game = entry
            game.isGame = true
            return game
        }
        let gameKeys = Set(games.map(\.catalogRowKey))
        self.apps = (decodedApps ?? []).filter { !gameKeys.contains($0.catalogRowKey) } + games
		self.featuredApps =
			try container.decodeIfPresent([App.ID].self, forKey: .featuredApps) ?? []
		self.news = (try? container.decode([ASOptionalRecord<News>].self, forKey: .news))?.compactMap(\.value) ?? []
	}

	public enum CodingKeys: String, CodingKey {
		case id = "identifier"
		case categories, gameCategories, games
        case name,
		     subtitle,
		     description,
		     website,
		     patreonURL,
		     userInfo,
		     iconURL,
		     headerURL,
		     tintColor,
		     apps,
		     featuredApps,
		     news
	}
	
	public var currentIconURL: URL? {
		iconURL ?? apps.first?.iconURL
	}
}

// MARK: - App

extension ASRepository {
	public struct App: Sendable, Decodable, Hashable, Identifiable {
		public var uuid = UUID()
		
		public var id: String?
		public var name: String?

        // A catalog row may be a mod variant of the same real bundle identifier.
        // Keep the actual bundle ID unchanged for Apple lookups and signing.
        public var catalogID: String?
        public var stableCatalogIdentifier: String { catalogID ?? id ?? currentName }
        public var catalogRowKey: String {
            if let catalogID, !catalogID.isEmpty { return "id:" + catalogID }
            return [id ?? "", currentName, currentDownloadUrl?.absoluteString ?? currentVersion ?? ""].joined(separator: "\u{1F}")
        }
        public var downloadKey: String {
            catalogRowKey + "\u{1F}" + (currentDownloadUrl?.absoluteString ?? "")
        }

		public var subtitle: String?
		public var description: String?

		public var developer: String?

		public var versions: [Version]?

		public var version: String?

		public var versionDate: DateParsed?
		
		public var date: DateParsed?

		public var versionDescription: String?

		public var downloadURL: URL?

		public var localizedDescription: String?

		public var iconURL: URL?

		public var tintColor: Color?

		public var size: Int64?

		public var category: String?
        public var categoryReferences: [String]
        public var artworkURL: URL?
        public var isGame: Bool?
        public var skipAppStoreLookup: Bool?

		public var beta: Bool?

		public var permissions: [Permission]?

		public var appPermissions: AppPermissions?

		public var screenshots: Screenshots?

		public var screenshotURLs: [URL]?
		
		public var marketplaceID: String?

		public struct Screenshots: Decodable, Hashable, Sendable {
			public var iPhone: [URL]?
			public var iPad: [URL]?

			private struct FlexibleItem: Decodable {
				let url: URL?

				private enum ItemKeys: String, CodingKey {
					case url
				}

				init(from decoder: any Decoder) throws {
					if let single = try? decoder.singleValueContainer() {
						if let directURL = try? single.decode(URL.self) {
							self.url = directURL
							return
						}
						if let urlString = try? single.decode(String.self),
						   let parsedURL = URL(string: urlString) {
							self.url = parsedURL
							return
						}
					}
					if let container = try? decoder.container(keyedBy: ItemKeys.self) {
						if let directURL = try? container.decode(URL.self, forKey: .url) {
							self.url = directURL
							return
						}
						if let urlString = try? container.decode(String.self, forKey: .url),
						   let parsedURL = URL(string: urlString) {
							self.url = parsedURL
							return
						}
					}
					self.url = nil
				}
			}

			public init(from decoder: any Decoder) throws {
				// Cases 1, 2, 3: Array of URLs, objects, or a mix of both
				if let items = try? [FlexibleItem](from: decoder) {
					self.iPhone = items.compactMap(\.url)
					self.iPad = []
					return
				}

				// Case 4: Dictionary with iphone / ipad arrays
				if let container = try? decoder.container(keyedBy: CodingKeys.self) {
					let iphoneItems = (try? container.decodeIfPresent([FlexibleItem].self, forKey: .iPhone)) ?? []
					let ipadItems = (try? container.decodeIfPresent([FlexibleItem].self, forKey: .iPad)) ?? []
					self.iPhone = iphoneItems.compactMap(\.url)
					self.iPad = ipadItems.compactMap(\.url)
					return
				}

				self.iPhone = []
				self.iPad = []
			}

			public enum CodingKeys: String, CodingKey {
				case iPhone = "iphone"
				case iPad = "ipad"
				case url
			}
		}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			self.id = try container.decodeIfPresent(String.self, forKey: .id)
			self.name = try container.decodeIfPresent(String.self, forKey: .name)
            self.catalogID = try container.decodeIfPresent(String.self, forKey: .catalogID)

			self.subtitle = try container.decodeIfPresent(
				String.self,
				forKey: .subtitle
			)
			self.description = try container.decodeIfPresent(
				String.self,
				forKey: .description
			)

			self.developer = try container.decodeIfPresent(String.self, forKey: .developer)

			self.versions = try container.decodeIfPresent(
				[Version].self,
				forKey: .versions
			)

			self.version = try container.decodeIfPresent(
				String.self,
				forKey: .version
			)

			self.versionDate = try container.decodeIfPresent(
				DateParsed.self,
				forKey: .versionDate
			)
			
			self.date = try container.decodeIfPresent(
				DateParsed.self,
				forKey: .date
			)

			self.versionDescription = try container.decodeIfPresent(
				String.self,
				forKey: .versionDescription
			)

			self.downloadURL = try container.decodeIfPresent(URL.self, forKey: .downloadURL)

			self.localizedDescription =
				try container.decodeIfPresent(
					String.self,
					forKey: .localizedDescription
				)

			self.iconURL = try? container.decodeIfPresent(URL.self, forKey: .iconURL)

			self.tintColor =
				try container.decodeIfPresent(Color.self, forKey: .tintColor)

			self.size =
				(try? container.decodeIfPresent(Int64.self, forKey: .size))
					?? (try? container.decodeIfPresent(String.self, forKey: .size))
					.flatMap { Int64($0) }

			self.skipAppStoreLookup = try container.decodeIfPresent(Bool.self, forKey: .skipAppStoreLookup)
            let categoryKeys: [CodingKeys] = [.category, .categoryId, .category_id, .primaryGenre, .primaryGenreName,
                .genre, .primaryGenreId, .genreId, .categories, .genres, .genreIds]
            var references: [String] = []
            var seen = Set<String>()
            for key in categoryKeys {
                let values: [String]
                if let list = try? container.decode([ASCategoryReference].self, forKey: key) {
                    values = list.compactMap(\.value)
                } else if let value = (try? container.decode(ASCategoryReference.self, forKey: key))?.value {
                    values = [value]
                } else { values = [] }
                for value in values {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted { references.append(trimmed) }
                }
            }
            self.categoryReferences = references
            self.category = references.first
            let artworkKeys: [CodingKeys] = [.artworkURL, .bannerURL, .headerURL, .banner_url, .header_url]
            self.artworkURL = artworkKeys.lazy.compactMap { key -> URL? in
                guard let raw = container.categoryText(key), let url = URL(string: raw),
                      url.scheme?.lowercased() == "https", url.host != nil,
                      url.user == nil, url.password == nil else { return nil }
                return url
            }.first
            let type = (container.categoryText(.type) ?? container.categoryText(.contentType))?.lowercased()
            let typed: Bool? = ["game", "games", "gaming"].contains(type ?? "") ? true :
                ["app", "apps", "application"].contains(type ?? "") ? false : nil
            self.isGame = container.flexibleBool(.isGame) ?? container.flexibleBool(.isGameSnakeCase) ?? typed

			self.beta =
				(try? container.decodeIfPresent(Bool.self, forKey: .beta)) ?? false

			self.permissions = try container.decodeIfPresent(
				[Permission].self,
				forKey: .permissions
			)
			self.appPermissions = try container.decodeIfPresent(
				AppPermissions.self,
				forKey: .appPermissions
			)

			self.screenshots = try? container.decodeIfPresent(
				Screenshots.self,
				forKey: .screenshots
			)

			let decodedScreenshotURLs = try? container.decodeIfPresent([URL].self, forKey: .screenshotURLs)
			if let decodedScreenshotURLs, !decodedScreenshotURLs.isEmpty {
				self.screenshotURLs = decodedScreenshotURLs
			} else {
				self.screenshotURLs = self.screenshots?.iPhone
			}
			
			if
				let marketplaceID = try container.decodeIfPresent(String.self, forKey: .marketplaceID),
				!marketplaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			{
				throw NSError(
					domain: "FeatherSources",
					code: 112789, userInfo: [NSLocalizedDescriptionKey: "AltStore PAL repositories aren't supported: \(id ?? "")"]
				)
			}
		}

		public enum CodingKeys: String, CodingKey {
			case id = "bundleIdentifier"
			case name, subtitle, description, catalogID
			case developer = "developerName"
			case versions, version, versionDate, date, versionDescription, downloadURL,
			     localizedDescription, iconURL, tintColor, size, category, beta, skipAppStoreLookup
			case isGame
			case isGameSnakeCase = "is_game"
            case categoryId, category_id, categories, primaryGenre, primaryGenreName, genre, primaryGenreId, genreId, genres, genreIds
            case type, contentType, artworkURL, bannerURL, headerURL, banner_url, header_url
			case permissions, appPermissions
			case screenshots, screenshotURLs
			case marketplaceID
		}
		
		public var currentAppVersion: Version? {
			versions?.first
		}
		
		public var currentName: String {
			var name = name ?? "Unknown"
			// additional check for blank names
			if name.isEmpty { name = "Unknown" }
			
			if let id, id.hasSuffix("Beta") {
				name += " (BETA)"
			}
			
			return name
		}
		
		public var currentVersion: String? {
			currentAppVersion?.version ?? version
		}
		
		public var currentDownloadUrl: URL? {
			currentAppVersion?.downloadURL ?? downloadURL
		}
		
		public var currentDate: DateParsed? {
			currentAppVersion?.date ?? versionDate ?? date
		}
		
		public var currentDescription: String? {
			subtitle ?? localizedDescription
		}
		
		// "UNIQUE" hahaha
		public var currentUniqueId: String {
			"\(id ?? uuid.uuidString).\(downloadURL?.absoluteString ?? uuid.uuidString)"
		}

		public struct Version: Decodable, Hashable, Identifiable, Comparable, Sendable {
			public var id: String { version + (build ?? "") }
			public var version: String
			public var build: String?
			public var date: DateParsed?
			public var localizedDescription: String?
			public var downloadURL: URL?
			public var size: UInt?
			public var minOSVersion: OSVersion?

            public init(version: String, date: DateParsed?, localizedDescription: String?, downloadURL: URL?, size: UInt?) {
                self.version = version
                self.date = date
                self.localizedDescription = localizedDescription
                self.downloadURL = downloadURL
                self.size = size
            }

			public init(from decoder: any Decoder) throws {
				let container = try decoder.container(keyedBy: CodingKeys.self)
				self.version = try container.decode(String.self, forKey: .version)
				self.build = try container.decodeIfPresent(
					String.self,
					forKey: .build
				)
				self.date = try? container.decodeIfPresent(
					DateParsed.self,
					forKey: .date
				)
				self.localizedDescription =
					try container.decodeIfPresent(
						String.self,
						forKey: .localizedDescription
					)
				self.downloadURL = try container.decodeIfPresent(
					URL.self,
					forKey: .downloadURL
				)
				self.size =
					(try? container.decodeIfPresent(UInt.self, forKey: .size))
						?? (try? container.decodeIfPresent(String.self, forKey: .size))
						.flatMap { UInt($0) }
				self.minOSVersion = try container.decodeIfPresent(
					OSVersion.self,
					forKey: .minOSVersion
				)
			}

			static public func < (lhs: Self, rhs: Self) -> Bool {
				// compare id
				lhs.id < rhs.id
			}

			public enum CodingKeys: String, CodingKey {
				case version
				case build = "buildVersion"
				case date, localizedDescription, downloadURL, size, minOSVersion
			}
		}
	}
}

// MARK: - News

extension ASRepository {
	public struct News: Sendable, Decodable, Hashable, Identifiable {
		public var id: String
		public var title: String
		public var caption: String
        public var badge: String?
		public var tintColor: Color?
		public var imageURL: URL?
		public var url: URL?
		public var appID: String?
		public var date: DateParsed?
		public var notify: Bool

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let title = container.categoryText(.title) else {
                throw DecodingError.dataCorruptedError(forKey: .title, in: container, debugDescription: "Missing news title.")
            }
            let appID = container.categoryText(.appID)
            let imageURL = container.categoryText(.imageURL).flatMap(URL.init(string:))
            self.id = container.categoryText(.id) ?? container.categoryText(.legacyID) ??
                ("news:" + [appID ?? "", title, imageURL?.absoluteString ?? ""].joined(separator: "\u{1F}"))
            self.title = title
            self.caption = container.categoryText(.caption) ?? ""
            self.badge = container.categoryText(.badge) ?? (container.flexibleBool(.showBadge) == false ? nil : container.categoryText(.badgeText))
            self.tintColor = try? container.decodeIfPresent(Color.self, forKey: .tintColor)
            self.imageURL = imageURL
            self.url = container.categoryText(.url).flatMap(URL.init(string:))
            self.appID = appID
            self.date = try? container.decodeIfPresent(DateParsed.self, forKey: .date)
            self.notify = container.flexibleBool(.notify) ?? false
		}

		public enum CodingKeys: String, CodingKey {
			case id = "identifier"
            case legacyID = "id"
			case title, caption, badge, badgeText, showBadge, tintColor, imageURL, url, appID, date, notify
		}
	}
}

extension ASRepository {
	public struct Permission: Decodable, Hashable, Sendable {
		public var type: String
		public var usageDescription: String
	}
}

extension ASRepository {
	public struct AppPermissions: Decodable, Hashable, Sendable {
		public var entitlements: [Entitlement]?
		public var privacy: [Privacy]?

		public struct Entitlement: Decodable, Hashable, Sendable {
			public var name: String

			public init(from decoder: any Decoder) throws {
				let container = try decoder.singleValueContainer()
				self.name = try container.decode(String.self)
			}
		}

		public struct Privacy: Decodable, Hashable, Sendable {
			public var name: String
			public var usageDescription: String
		}

		public struct PrivacyDictionary: Decodable, Hashable, Sendable {
			private var _permissions: [String: String]
			
			public var privacyArray: [Privacy] {
				_permissions.map { Privacy(name: $0.key, usageDescription: $0.value) }
			}
			
			public init(from decoder: any Decoder) throws {
				let container = try decoder.singleValueContainer()
				self._permissions = try container.decode([String: String].self)
			}
		}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			self.entitlements = try? container.decodeIfPresent(
				[Entitlement].self,
				forKey: .entitlements
			)
			// some people are silly and are using empty dictionaries instead of empty arrays so lets ignore decoding errors
			self.privacy = try? container.decodeIfPresent(
				[Privacy].self,
				forKey: .privacy
			)
			// lets not ignore the silly people
			if self.privacy == nil {
				if let privacyDict = try? container.decodeIfPresent(
					PrivacyDictionary.self,
					forKey: .privacy
				) {
					self.privacy = privacyDict.privacyArray
				}
			}
		}

		public enum CodingKeys: String, CodingKey {
			case entitlements
			case privacy
		}
	}
}

extension ASRepository {
	public struct UserInfo: Decodable, Hashable, Sendable {
		public var patreonAccessToken: String?
	}
}

// MARK: - DateParsed

// everyone keeps using different formats for dates, even altstore

// taken from meret
public struct DateParsed: Codable, Equatable, Hashable, Comparable, Sendable {
	public let date: Date
	public let rawDate: RawDate
	
	public enum RawDate: Decodable, Hashable, Sendable {
		case number(Double)
		case string(String)
	}
	
    private static let parsedDateCache: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>()
        cache.countLimit = 4096
        return cache
    }()

	// ISO8601 formatters (more accurate for machine-generated dates)
	private static let isoFormatters: [ISO8601DateFormatter] = [
		{
			let formatter = ISO8601DateFormatter()
			formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
			return formatter
		}(),
		{
			let formatter = ISO8601DateFormatter()
			formatter.formatOptions = [.withInternetDateTime]
			return formatter
		}()
	]
	
	// legacy formatters
	private static let formatters: [DateFormatter] = {
		let locale = Locale(identifier: "en_US_POSIX")
		let tz = TimeZone(secondsFromGMT: 0)
		
		return [
			"yyyy-MM-dd'T'HH:mm:ss.SSSZ",
			"yyyy-MM-dd'T'HH:mm:ssZ",
			"yyyy-MM-dd'T'HH:mm:ss",
			"yyyy-MM-dd'T'HH:mm",            // AltStudio
			"yyyy-MM-dd",
			"EEE, dd MMM yyyy HH:mm:ss zzz", // RFC1123
			"EEE MMM dd HH:mm:ss Z yyyy",    // Twitter
			"yyyy-MM-dd HH:mm:ss",
		].map {
			let formatter = DateFormatter()
			formatter.dateFormat = $0
			formatter.locale = locale
			formatter.timeZone = tz
			return formatter
		}
	}()
	
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		
		// prevent nil
		if container.decodeNil() {
			throw DecodingError.valueNotFound(
				Date.self,
				.init(
					codingPath: decoder.codingPath,
					debugDescription: "Found nil for date. Mark the date optional."
				)
			)
		}
		
		// timestamp (e.g., 1699999999.0)
		if let timestamp = try? container.decode(Double.self) {
			self.date = Date(timeIntervalSince1970: timestamp)
			self.rawDate = .number(timestamp)
			return
		}
		
		// string formats
		let dateString = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
		self.rawDate = .string(dateString)
        if let cached = Self.parsedDateCache.object(forKey: dateString as NSString) {
            self.date = cached as Date
            return
        }
		
		// ISO8601 formatters
		for formatter in Self.isoFormatters {
			if let date = formatter.date(from: dateString) {
				self.date = date
                Self.parsedDateCache.setObject(date as NSDate, forKey: dateString as NSString)
				return
			}
		}
		
		// legacy formatters
		for formatter in Self.formatters {
			if let date = formatter.date(from: dateString) {
				self.date = date
                Self.parsedDateCache.setObject(date as NSDate, forKey: dateString as NSString)
				return
			}
		}
		
		// numeric timestamp string
		if let timestamp = Double(dateString) {
			self.date = Date(timeIntervalSince1970: timestamp)
			return
		}
		
		throw DecodingError.dataCorruptedError(
			in: container,
			debugDescription: "Failed to decode date from: \(dateString)"
		)
	}
	
	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(date)
	}
	
	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.date == rhs.date
	}
	
	public static func < (lhs: Self, rhs: Self) -> Bool {
		lhs.date < rhs.date
	}
}


public struct OSVersion: Decodable, Hashable, CustomStringConvertible, Sendable {
	public var description: String {
		return "\(majorVersion).\(minorVersion).\(patchVersion)"
	}

	public var majorVersion: UInt
	public var minorVersion: UInt
	public var patchVersion: UInt

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		let versionString = try container.decode(String.self)

		let components = versionString.split(separator: ".").compactMap { UInt($0) }

		self.majorVersion = components[safe: 0] ?? 0
		self.minorVersion = components[safe: 1] ?? 0
		self.patchVersion = components[safe: 2] ?? 0
	}
}
