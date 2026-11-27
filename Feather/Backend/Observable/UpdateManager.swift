//
// UpdateManager.swift
// Feather
//
// Created by Dominic on 24.05.2026.
// Optimized with bounded parallel repository fetching for X-SIGN.
//

import AltSourceKit
import CoreData
import Foundation
import NimbleJSON

struct AppUpdate: Identifiable, Equatable {
	let id: String
	let localUUID: String
	let localVersion: String?
	let remoteVersion: String
	let appName: String
	let bundleIdentifier: String
	let downloadURL: URL
	let sourceURL: URL
	let sourceProvenance: SourceAppProvenance
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()

	typealias RepositoryDataHandler = Result<ASRepository, Error>

	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?

	private let _dataService = NBFetchService()

	private init() {}

	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid else { return nil }
		return updates[uuid]
	}

	func checkForUpdates(
		sources: [AltSource],
		localApps: [AppInfoPresentable]
	) async {
		guard !isChecking else { return }

		isChecking = true
		defer {
			isChecking = false
			lastCheckedDate = Date()
		}

		let repositories = await _fetchRepositories(from: sources)
		updates = _findUpdates(repositories: repositories, localApps: localApps)
	}

	private func _fetchRepositories(from sources: [AltSource]) async -> [(AltSource, ASRepository)] {
		let indexedSources: [(Int, AltSource, URL)] = sources.enumerated().compactMap { index, source in
			guard let url = source.sourceURL, !ProtectedSourcesVault.isRetiredSource(url) else {
				return nil
			}
			return (index, source, url)
		}

		guard !indexedSources.isEmpty else { return [] }

		let maxConcurrent = 5
		var fetched: [(Int, AltSource, ASRepository)] = []
		fetched.reserveCapacity(indexedSources.count)

		await withTaskGroup(of: (Int, AltSource, ASRepository?).self) { group in
			var iterator = indexedSources.makeIterator()

			for _ in 0..<min(maxConcurrent, indexedSources.count) {
				if let (index, source, url) = iterator.next() {
					group.addTask(priority: .userInitiated) {
						let repo = try? await XSignCatalogIO.shared.fetch(url).repository
						return (index, source, repo)
					}
				}
			}

			while let (index, source, repo) = await group.next() {
				if let repo {
					fetched.append((index, source, repo))
				}
				if let (nextIndex, nextSource, nextURL) = iterator.next() {
					group.addTask(priority: .userInitiated) {
						let repo = try? await XSignCatalogIO.shared.fetch(nextURL).repository
						return (nextIndex, nextSource, repo)
					}
				}
			}
		}

		return fetched
			.sorted { $0.0 < $1.0 }
			.map { ($0.1, $0.2) }
	}

	private func _fetchRepository(from url: URL) async -> ASRepository? {
		guard !ProtectedSourcesVault.isRetiredSource(url) else { return nil }
		return try? await XSignCatalogIO.shared.fetch(url).repository
	}

	private func _findUpdates(
		repositories: [(AltSource, ASRepository)],
		localApps: [AppInfoPresentable]
	) -> [String: AppUpdate] {
		var foundUpdates: [String: AppUpdate] = [:]
		let metadataByUUID = Storage.shared.getSourceMetadata().reduce(into: [String: AppSourceMetadata]()) {
			$0[$1.appUUID] = $1
		}
		let metadataCandidates = localApps.compactMap { app -> SourceMetadataCandidate? in
			guard
				let uuid = app.uuid,
				let metadata = metadataByUUID[uuid]
			else {
				return nil
			}
			return SourceMetadataCandidate(appUUID: uuid, app: app, metadata: metadata)
		}

		for localApp in localApps {
			guard let localUUID = localApp.uuid else {
				continue
			}

			let sourceAppIdentifier: String
			let sourceAppVersion: String?
			let sourceDownloadFingerprint: String?
			let sourceAppName: String?
			let storedSourceURL: URL
			let storedSourceID: String?
			if let directMetadata = metadataByUUID[localUUID] {
				guard
					let metadataSourceAppIdentifier = directMetadata.sourceAppIdentifier,
					let metadataSourceURL = directMetadata.sourceRepositoryURL
				else {
					continue
				}

				sourceAppIdentifier = metadataSourceAppIdentifier
				sourceAppVersion = directMetadata.sourceAppVersion
				sourceDownloadFingerprint = directMetadata.downloadFingerprint
				sourceAppName = directMetadata.sourceAppName
				storedSourceURL = metadataSourceURL
				storedSourceID = directMetadata.sourceRepositoryIdentifier
			} else if let fallback = _fallbackMetadataCandidate(
				for: localApp,
				localUUID: localUUID,
				candidates: metadataCandidates
			) {
				guard
					let metadataSourceAppIdentifier = fallback.metadata.sourceAppIdentifier,
					let metadataSourceURL = fallback.metadata.sourceRepositoryURL
				else {
					continue
				}

				sourceAppIdentifier = metadataSourceAppIdentifier
				sourceAppVersion = fallback.metadata.sourceAppVersion
				sourceDownloadFingerprint = fallback.metadata.downloadFingerprint
				sourceAppName = fallback.metadata.sourceAppName
				storedSourceURL = metadataSourceURL
				storedSourceID = fallback.metadata.sourceRepositoryIdentifier
				Storage.shared.copySourceMetadata(
					from: fallback.appUUID,
					to: localUUID,
					kind: localApp.isSigned ? .signed : .imported
				)
			} else if
				let localSourceURL = localApp.source,
				let localIdentifier = localApp.identifier
			{
				sourceAppIdentifier = localIdentifier
				sourceAppVersion = localApp.version
				sourceDownloadFingerprint = nil
				sourceAppName = localApp.name
				storedSourceURL = localSourceURL
				storedSourceID = nil
			} else {
				continue
			}

			for (source, repository) in repositories {
				guard let sourceURL = source.sourceURL else {
					continue
				}

				let migratedOwner = sourceURL == XSignCatalogueEndpoint.ownerURL &&
					storedSourceID == XSignCatalogueEndpoint.ownerID
				guard migratedOwner || _matchesStoredRepository(storedSourceURL: storedSourceURL, sourceURL: sourceURL) else {
					continue
				}

				let candidates = repository.apps.filter { $0.catalogID == sourceAppIdentifier || $0.id == sourceAppIdentifier }
				let named = candidates.filter { $0.currentName == (sourceAppName ?? localApp.name ?? "") }
				guard let remoteApp = candidates.count == 1 ? candidates.first : (named.count == 1 ? named.first : nil) else {
					continue
				}

				guard let remoteVersion = remoteApp.currentVersion, !remoteVersion.isEmpty else {
					continue
				}

				guard let downloadURL = remoteApp.currentDownloadUrl else {
					continue
				}
				guard XSignReleaseVersion.catalogNeedsUpdate(
					currentVersion: sourceAppVersion,
					targetVersion: remoteVersion,
					currentFingerprint: sourceDownloadFingerprint,
					targetURL: downloadURL,
					isProtectedPackage: false
				) else { continue }

				guard let provenance = SourceAppProvenance(
					sourceURL: sourceURL,
					repository: repository,
					app: remoteApp
				) else {
					continue
				}

				foundUpdates[localUUID] = AppUpdate(
					id: localUUID,
					localUUID: localUUID,
					localVersion: sourceAppVersion ?? localApp.version,
					remoteVersion: remoteVersion,
					appName: remoteApp.currentName,
					bundleIdentifier: remoteApp.id ?? localApp.identifier ?? sourceAppIdentifier,
					downloadURL: downloadURL,
					sourceURL: sourceURL,
					sourceProvenance: provenance
				)
				break
			}
		}

		return foundUpdates
	}

	private func _matchesStoredRepository(
		storedSourceURL: URL,
		sourceURL: URL
	) -> Bool {
		_normalizedSourceURL(storedSourceURL) == _normalizedSourceURL(sourceURL)
	}

	private func _normalizedSourceURL(_ url: URL) -> String {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let scheme = components?.scheme?.lowercased()
		let host = components?.host?.lowercased()
		components?.scheme = scheme
		components?.host = host
		components?.fragment = nil

		let normalized = components?.url ?? url
		let absoluteString = normalized.absoluteString
		return absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
	}

	private func _fallbackMetadataCandidate(
		for localApp: AppInfoPresentable,
		localUUID: String,
		candidates: [SourceMetadataCandidate]
	) -> SourceMetadataCandidate? {
		guard
			localApp.isSigned,
			let localIdentifier = localApp.identifier,
			let localVersion = localApp.version
		else {
			return nil
		}

		return candidates.first {
			$0.appUUID != localUUID &&
			!$0.app.isSigned &&
			$0.app.identifier == localIdentifier &&
			$0.app.version == localVersion
		}
	}
}

private struct SourceMetadataCandidate {
	let appUUID: String
	let app: AppInfoPresentable
	let metadata: AppSourceMetadata
}
