//
//  SourcesViewModel.swift
//  Feather
//
import Foundation
import AltSourceKit
import SwiftUI
import CryptoKit

// XSIGN_CATALOG_LOADING_V1
@MainActor
final class SourcesViewModel: ObservableObject {
    static let shared = SourcesViewModel()
    typealias RepositoryDataHandler = Result<ASRepository, Error>
    private(set) var isFinished = true
    @Published var sources: [AltSource: ASRepository] = [:]
    @Published private(set) var errors: [AltSource: String] = [:]
    private var fingerprints: [AltSource: Data] = [:]
    private var running: Task<Void, Never>?

    func fingerprint(for source: AltSource) -> Data? { fingerprints[source] }

    func seed(_ record: XSignRepositoryRecord, for source: AltSource) {
        guard !ProtectedSourcesVault.isRetiredSource(source.sourceURL, identifier: source.identifier) else { return }
        errors[source] = nil
        guard fingerprints[source] != record.fingerprint else { return }
        fingerprints[source] = record.fingerprint
        sources[source] = record.repository
        errors[source] = nil
    }

    func fetchSources<S: Collection>(_ requested: S, refresh: Bool = false, batchSize: Int = 1) async where S.Element == AltSource {
        while let running { await running.value }
        let targets = requested.filter { !ProtectedSourcesVault.isRetiredSource($0.sourceURL, identifier: $0.identifier) }
        let allowed = Set(targets)
        sources = sources.filter { allowed.contains($0.key) }
        fingerprints = fingerprints.filter { allowed.contains($0.key) }
        errors = errors.filter { allowed.contains($0.key) }
        let pending = targets.filter { refresh || sources[$0] == nil }
        guard !pending.isEmpty else { return }
        let task = Task { @MainActor in
            self.isFinished = false
            defer { self.isFinished = true; self.running = nil }
            let candidates = pending.compactMap { source in source.sourceURL.map { (source, $0) } }
            await withTaskGroup(of: (Int, XSignRepositoryRecord?, String?).self) { group in
                let urls = candidates.map { $0.1 }
                let publishCached: @MainActor @Sendable (Int, XSignRepositoryRecord) -> Void = { index, record in
                    let source = candidates[index].0
                    if !Task.isCancelled, !source.isDeleted, self.sources[source] == nil {
                        self.seed(record, for: source)
                    }
                }
                let load: @Sendable (Int) async -> (Int, XSignRepositoryRecord?, String?) = { index in
                    let url = urls[index]
                    if let cached = await XSignCatalogIO.shared.cached(url) {
                        await publishCached(index, cached)
                    }
                    do { return (index, try await XSignCatalogIO.shared.fetch(url), nil) }
                    catch { return (index, nil, error.localizedDescription) }
                }
                let count = min(max(1, batchSize), candidates.count)
                for index in 0..<count { group.addTask { await load(index) } }
                var next = count
                for await (index, record, failure) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    let source = candidates[index].0
                    if !source.isDeleted {
                        if let record { self.seed(record, for: source) }
                        self.errors[source] = failure
                    }
                    if next < candidates.count {
                        let index = next
                        next += 1
                        group.addTask { await load(index) }
                    }
                }
            }
        }
        running = task
        await task.value
    }
}

// MARK: - Shared catalog transport; disk and decoding never run on the main actor
struct XSignRepositoryRecord: Sendable {
    let repository: ASRepository
    let fingerprint: Data
    let revision: Int?
}

enum XSignCatalogError: LocalizedError {
    case invalidURL, invalidResponse, http(Int), tooLarge, invalidJSON
    case awaitingOwnerRevision
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "رابط السورس غير صالح."
        case .invalidResponse: return "الخادم لم يُرجع بيانات سورس JSON."
        case .http(let status): return "تعذّر جلب السورس (HTTP \(status))."
        case .tooLarge: return "حجم السورس يتجاوز الحد المسموح."
        case .invalidJSON: return "بيانات السورس ليست بصيغة AltStore صالحة."
        case .awaitingOwnerRevision: return "تحديث كتالوج IPA BLACK قيد الوصول؛ تظهر الآن النسخة المحفوظة."
        }
    }
}

actor XSignCatalogIO {
    private struct OwnerRevision: Decodable { let repo_revision_id: Int? }
    private struct CachedFeed {
        let identity: String
        let record: XSignRepositoryRecord
        var revalidateAt: Date = .distantPast
    }
    static let shared = XSignCatalogIO()
    nonisolated static let maximumBytes = 33_554_432
    private let directory: URL
    private let session: URLSession
    private var latestOwnerRevision = 0
    private var requests: [String: Task<XSignRepositoryRecord, Error>] = [:]
    private var cachedFeeds: [URL: CachedFeed] = [:]
    private var feedDiskReads: [String: Task<XSignRepositoryRecord?, Never>] = [:]
    private var mergedPublicCatalog: XSignRepositoryRecord?

    init(directory: URL? = nil, session: URLSession? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XSignApprovedCatalogs_v2", isDirectory: true)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpMaximumConnectionsPerHost = 2
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 90
            config.urlCache = nil
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config, delegate: XSignCatalogRedirects(), delegateQueue: nil)
        }
    }

    nonisolated static func canonicalURL(_ input: URL) -> URL {
        guard var parts = URLComponents(url: input, resolvingAgainstBaseURL: false) else { return input }
        let host = parts.host?.lowercased()
        parts.host = host
        if parts.scheme?.lowercased() == "https" {
            parts.scheme = "https"
            if parts.port == 443 { parts.port = nil }
        }
        var path = parts.percentEncodedPath
        if host == XSignCatalogueEndpoint.iosBoomFeeds[0].host, path.isEmpty { path = "/" }
        if host == "github.com" {
            let segments = path.split(separator: "/", omittingEmptySubsequences: true)
            if segments.count >= 5, segments[2] == "blob" || segments[2] == "raw" {
                parts.host = "raw.githubusercontent.com"
                path = "/" + ([String(segments[0]), String(segments[1])] + segments.dropFirst(3).map(String.init)).joined(separator: "/")
                let filtered = parts.queryItems?.filter { $0.name != "raw" }
                parts.queryItems = (filtered?.isEmpty == true) ? nil : filtered
            }
        }
        if parts.host?.lowercased() == "raw.githubusercontent.com" {
            path = path.replacingOccurrences(of: "/refs/heads/", with: "/")
            let segments = path.split(separator: "/")
            if segments.count == 6, segments[0].lowercased() == "ipablack",
               segments[1].lowercased() == "x-sign",
               segments.dropFirst(2).map(String.init) == ["main", "public", "sources", "ipasoon.json"],
               parts.scheme == "https", parts.user == nil, parts.password == nil,
               parts.port == nil, parts.query == nil, parts.fragment == nil {
                return XSignCatalogueEndpoint.soonSnapshot
            }
        }
        parts.percentEncodedPath = path
        return parts.url ?? input
    }

    nonisolated static func cacheIdentity(_ url: URL) -> String {
        let url = canonicalURL(url)
        if url == XSignCatalogueEndpoint.ownerURL {
            return XSignCatalogueEndpoint.ownerRequest(settings: false).url?.absoluteString ?? url.absoluteString
        }
        let key = url.absoluteString + (XSignCatalogueEndpoint.iosBoomFeeds.contains(url) ? "|public-feed-v1" : "")
        guard let config = XSignDashboardSources.configuration(for: url) else { return key }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return key + "|" + ((try? encoder.encode(config))?.base64EncodedString() ?? "")
    }

    func invalidateValidators() {
        for url in Array(cachedFeeds.keys) { cachedFeeds[url]?.revalidateAt = .distantPast }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "etag" { try? FileManager.default.removeItem(at: file) }
    }

    private func file(_ url: URL) -> URL {
        let key = SHA256.hash(data: Data(Self.cacheIdentity(url).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    nonisolated static func decode(_ data: Data, readRevision: Bool = false) throws -> XSignRepositoryRecord {
        guard data.count <= maximumBytes else { throw XSignCatalogError.tooLarge }
        let repository: ASRepository
        do {
            repository = try JSONDecoder().decode(ASRepository.self, from: data)
        } catch {
            // Some otherwise valid sources contain blank optional URL fields.
            guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
                throw XSignCatalogError.invalidJSON
            }
            func clean(_ value: Any) -> Any {
                if let dict = value as? [String: Any] {
                    let optionalURLs: Set<String> = ["iconURL", "website", "headerURL", "imageURL", "url", "date", "versionDate"]
                    return dict.reduce(into: [String: Any]()) { result, pair in
                        if optionalURLs.contains(pair.key), let text = pair.value as? String,
                           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                        result[pair.key] = clean(pair.value)
                    }
                }
                if let list = value as? [Any] { return list.map(clean) }
                return value
            }
            guard let sanitized = try? JSONSerialization.data(withJSONObject: clean(root)),
                  let parsed = try? JSONDecoder().decode(ASRepository.self, from: sanitized) else {
                throw XSignCatalogError.invalidJSON
            }
            repository = parsed
        }
        let revision = readRevision ? (try? JSONDecoder().decode(OwnerRevision.self, from: data).repo_revision_id) : nil
        return XSignRepositoryRecord(repository: repository, fingerprint: Data(SHA256.hash(data: data)), revision: revision)
    }

    private nonisolated static func read(_ path: URL, owner: Bool) -> XSignRepositoryRecord? {
        guard let size = (try? path.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= Self.maximumBytes,
              let data = try? Data(contentsOf: path, options: .mappedIfSafe) else { return nil }
        return try? Self.decode(data, readRevision: owner)
    }

    func cached(_ input: URL) async -> XSignRepositoryRecord? {
        let url = XSignDashboardSources.sectionSource(input.absoluteString) ?? input
        guard !ProtectedSourcesVault.isRetiredSource(url), !Task.isCancelled else { return nil }
        if url == XSignCatalogueEndpoint.iosBoomCatalogue {
            return await iosBoomRepository(refresh: false)
        }
        return await cachedFile(url)
    }

    private func cachedFile(_ url: URL) async -> XSignRepositoryRecord? {
        let identity = Self.cacheIdentity(url)
        let publicFeed = XSignCatalogueEndpoint.iosBoomFeeds.contains(url)
        if publicFeed {
            if let cached = cachedFeeds[url], cached.identity == identity { return cached.record }
            if let running = feedDiskReads[identity] { return await running.value }
        }
        let path = file(url)
        let owner = url == XSignCatalogueEndpoint.ownerURL
        let read = Task.detached(priority: publicFeed ? .utility : .userInitiated) { Self.read(path, owner: owner) }
        if publicFeed { feedDiskReads[identity] = read }
        let result = await read.value
        if publicFeed { feedDiskReads[identity] = nil }
        guard !Task.isCancelled, identity == Self.cacheIdentity(url) else { return nil }
        if publicFeed {
            if let existing = cachedFeeds[url], existing.identity == identity { return existing.record }
            if let result { cachedFeeds[url] = CachedFeed(identity: identity, record: result) }
        }
        return result
    }

    func fetch(_ input: URL, ownerRevision: Int? = nil) async throws -> XSignRepositoryRecord {
        let url = XSignDashboardSources.sectionSource(input.absoluteString) ?? input
        guard !ProtectedSourcesVault.isRetiredSource(url) else { throw XSignCatalogError.invalidURL }
        guard url == XSignCatalogueEndpoint.ownerURL || XSignManagedSource.httpsURL(url.absoluteString) != nil else {
            throw XSignCatalogError.invalidURL
        }
        let revision = url == XSignCatalogueEndpoint.ownerURL ? ownerRevision : nil
        let identity = Self.cacheIdentity(url)
        let publicFeed = XSignCatalogueEndpoint.iosBoomFeeds.contains(url)
        if publicFeed, let cached = cachedFeeds[url], cached.identity == identity, cached.revalidateAt > Date() {
            return cached.record
        }
        let key = identity + (revision.map { "|owner-revision:\($0)" } ?? "")
        if let running = requests[key] { return try await running.value }
        let task = Task(priority: publicFeed || url == XSignCatalogueEndpoint.iosBoomCatalogue ? .utility : nil) {
            if url == XSignCatalogueEndpoint.iosBoomCatalogue {
                guard let record = await self.iosBoomRepository(refresh: true) else { throw XSignCatalogError.invalidResponse }
                return record
            }
            do {
                let record = try await self.download(url, identity: identity, minimumRevision: revision)
                if publicFeed {
                    self.cachedFeeds[url] = CachedFeed(identity: identity, record: record, revalidateAt: Date().addingTimeInterval(300))
                }
                return record
            } catch {
                guard !(error is CancellationError), identity == Self.cacheIdentity(url),
                      let snapshot = XSignCatalogueEndpoint.archivedSoon(for: url,
                          sourceID: XSignDashboardSources.configuration(for: url)?.id) else { throw error }
                if let previous = await self.cached(url), !previous.repository.apps.isEmpty { return previous }
                let archive: XSignRepositoryRecord
                do {
                    archive = try await self.download(snapshot, identity: Self.cacheIdentity(snapshot),
                                                      minimumRevision: nil, archived: true)
                } catch {
                    guard !(error is CancellationError),
                          let cached = await self.cached(snapshot), !cached.repository.apps.isEmpty else { throw error }
                    archive = cached
                }
                guard identity == Self.cacheIdentity(url) else { throw CancellationError() }
                return archive
            }
        }
        requests[key] = task
        defer { requests.removeValue(forKey: key) }
        return try await task.value
    }

    private func iosBoomRepository(refresh: Bool) async -> XSignRepositoryRecord? {
        let feeds = XSignCatalogueEndpoint.iosBoomFeeds
        let records = await withTaskGroup(of: (Int, XSignRepositoryRecord?).self) { group in
            for (index, url) in feeds.enumerated() {
                group.addTask(priority: .utility) {
                    if refresh, let record = try? await self.fetch(url) { return (index, record) }
                    return (index, await self.cachedFile(url))
                }
            }
            var ordered = [XSignRepositoryRecord?](repeating: nil, count: feeds.count)
            for await (index, record) in group { ordered[index] = record }
            return ordered.compactMap { $0 }
        }
        guard !Task.isCancelled, var merged = records.first?.repository else { return nil }
        var hash = SHA256()
        for record in records { hash.update(data: record.fingerprint) }
        let fingerprint = Data(hash.finalize())
        if let previous = mergedPublicCatalog, previous.fingerprint == fingerprint { return previous }
        merged.id = XSignCatalogueEndpoint.iosBoomID
        merged.name = "iOSBoom Public"
        merged.categories = records.flatMap { $0.repository.categories ?? [] }
        merged.news = []
        merged.featuredApps = []
        var seen = Set<String>()
        merged.apps = records.flatMap { $0.repository.apps.filter { seen.insert($0.downloadKey).inserted } }
        let result = XSignRepositoryRecord(repository: merged, fingerprint: fingerprint, revision: nil)
        mergedPublicCatalog = result
        return result
    }

    private func download(_ url: URL, identity: String, minimumRevision: Int?, archived: Bool = false) async throws -> XSignRepositoryRecord {
        let destination = file(url)
        let configuration = archived ? nil : XSignDashboardSources.configuration(for: url)
        if let configuration, configuration.format == "rest" {
            let data = try await XSignRESTSource.fetch(url, session: session, maximumBytes: Self.maximumBytes, configuration: configuration)
            guard identity == Self.cacheIdentity(url) else { throw CancellationError() }
            guard !ProtectedSourcesVault.isRetiredSource(url) else { throw XSignCatalogError.invalidURL }
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw XSignCatalogError.invalidJSON }
            root["name"] = configuration.name
            root["identifier"] = configuration.id
            if let icon = configuration.icon_url { root["iconURL"] = icon }
            let normalized = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let result = try Self.decode(normalized)
            do {
                try XSignPrivateFiles.createDirectory(directory)
                try normalized.write(to: destination, options: .atomic)
                try XSignPrivateFiles.protect(destination)
            } catch {
                // A full/unavailable cache must not discard a valid in-memory catalogue.
            }
            return result
        }
        let tagFile = destination.appendingPathExtension("etag")
        let owner = url == XSignCatalogueEndpoint.ownerURL
        let initial = owner ? XSignCatalogueEndpoint.ownerRequest(settings: false)
            : URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let alternate = initial.url.flatMap(XSignCatalogueEndpoint.alternatePublicRequest)
        var lastError: Error = owner ? XSignCatalogError.awaitingOwnerRevision : XSignCatalogError.invalidResponse
        var requests = [initial, initial]
        if let alternate { requests.append(alternate) }
        var primaryUnavailable = false
        for (attempt, requestTemplate) in requests.enumerated() {
            var request = requestTemplate
            let isPrimary = attempt < 2
            if isPrimary && primaryUnavailable { continue }
            if XSignCatalogueEndpoint.iosBoomFeeds.contains(url) { request.timeoutInterval = 12 }
            if isPrimary { request.setValue("application/json", forHTTPHeaderField: "Accept") }
            request.setValue("XSign/1.0", forHTTPHeaderField: "User-Agent")
            if attempt == 0, FileManager.default.fileExists(atPath: destination.path),
               let tag = try? String(contentsOf: tagFile, encoding: .utf8), !tag.isEmpty {
                request.setValue(tag, forHTTPHeaderField: "If-None-Match")
            }
            let downloaded: (URL, URLResponse)
            do {
                downloaded = try await session.download(for: request)
            } catch {
                guard isPrimary, alternate != nil, !Task.isCancelled,
                      (error as? URLError)?.code != .cancelled else { throw error }
                lastError = error
                primaryUnavailable = true
                continue
            }
            let (temporary, response) = downloaded
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard identity == Self.cacheIdentity(url) else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw XSignCatalogError.invalidResponse }
            if http.statusCode == 304 {
                if let result = await cached(url),
                   !owner || (result.revision ?? 0) >= max(minimumRevision ?? 0, latestOwnerRevision) {
                    if owner { latestOwnerRevision = result.revision ?? 0 }
                    return result
                }
                continue // A purged/corrupt cache must never make a 304 look like an empty catalog.
            }
            guard (200..<300).contains(http.statusCode) else {
                let error = XSignCatalogError.http(http.statusCode)
                guard isPrimary, alternate != nil else { throw error }
                lastError = error
                primaryUnavailable = true
                continue
            }
            let length = (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard length > 0 else { throw XSignCatalogError.invalidResponse }
            guard length <= Self.maximumBytes else { throw XSignCatalogError.tooLarge }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            let normalized = archived ? data : try XSignSourceAdapter.normalize(data, from: url, configuration: configuration)
            let result = try Self.decode(normalized, readRevision: owner)
            if XSignCatalogueEndpoint.iosBoomFeeds.contains(url), result.repository.apps.isEmpty {
                throw XSignCatalogError.invalidJSON
            }
            if owner {
                let revision = result.revision ?? 0
                guard revision >= max(minimumRevision ?? 0, latestOwnerRevision) else { continue }
                latestOwnerRevision = revision
            }
            // Write only a validated source. Network/JSON failures retain the last good file.
            do {
                try XSignPrivateFiles.createDirectory(directory)
                try normalized.write(to: destination, options: .atomic)
                try XSignPrivateFiles.protect(destination)
                if isPrimary, let tag = http.value(forHTTPHeaderField: "ETag") {
                    try tag.write(to: tagFile, atomically: true, encoding: .utf8)
                } else {
                    try? FileManager.default.removeItem(at: tagFile)
                }
            } catch {
                // A temporary disk-write failure must not discard a valid in-memory response.
            }
            return result
        }
        throw lastError
    }
}
