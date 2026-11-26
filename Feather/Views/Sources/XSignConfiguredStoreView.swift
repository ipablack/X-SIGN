import SwiftUI
import CoreData
import UIKit
import WebKit

// Use the published section layout with XSign's native storefront cards.
struct XSignClassicStoreContent: View {
    let page: String
    var completeItems: [AppStoreAppItem]? = nil
    var showsCategories = true
    var categoryID: String? = nil
    @ObservedObject private var cache = AppStoreCacheManager.shared
    @ObservedObject private var remote = XSignRemoteManager.shared
    @State private var rendered: XSignStoreLayoutCache.Entry?

    fileprivate struct Request: Equatable, Sendable {
        let revision: UInt64
        let scope: Scope
    }

    fileprivate struct Scope: Equatable, Sendable {
        let page: String
        let categoryID: String?
        let hasCompleteList: Bool
        let sections: [XSignStoreSection]
        let showsDownload: Bool
        let hidesGeneralList: Bool
        let sources: [XSignManagedSource]?
        let todaySources: [String]?
    }

    private var scopedItems: [AppStoreAppItem] {
        switch page {
        case "apps": return completeItems ?? cache.pureAppsOnly
        case "games": return completeItems ?? cache.pureGamesOnly
        default: return completeItems ?? cache.todayItems
        }
    }

    var body: some View {
        let sections = (remote.config?.dashboard?.sections(for: page)
            ?? XSignDashboardConfig.defaultSections.filter { $0.page == page })
            .filter { (showsCategories || $0.kind != "categories") &&
                (page != "today" || !["يحدث الآن", "يحدث الان"].contains($0.title.trimmingCharacters(in: .whitespacesAndNewlines))) }
        let scope = Scope(page: page, categoryID: categoryID,
            hasCompleteList: completeItems != nil, sections: sections,
            showsDownload: page != "today" || remote.config?.dashboard?.today_show_download_buttons != false,
            hidesGeneralList: remote.config?.dashboard?.sections?.contains {
                $0.page == page && $0.isGeneralList && $0.enabled == false
            } == true, sources: remote.config?.dashboard?.sources,
            todaySources: page == "today" ? remote.config?.dashboard?.today_source_ids : nil)
        let request = Request(revision: cache.catalogRevision, scope: scope)
        let remembered = XSignStoreLayoutCache.shared.layout(for: request)
        let visibleLayout = remembered ?? (rendered?.request.scope == scope ? rendered?.layout : nil)
        LazyVStack(alignment: .leading, spacing: 24) {
            if let layout = visibleLayout {
                ForEach(layout.shelves) { shelf in
                    XSignClassicStoreSection(shelf: shelf, cache: cache)
                }
                if let fallback = layout.fallback {
                    let title = page == "games" ? "جميع الألعاب" : "جميع التطبيقات"
                    NavigationLink {
                        XSignClassicCatalogueList(title: title, items: fallback)
                    } label: {
                        Label(xsignText(title), systemImage: "chevron.backward").font(.headline)
                    }.buttonStyle(.plain)
                }
                if !layout.remaining.isEmpty {
                    XSignCatalogueFeed(items: layout.remaining, showsDownload: scope.showsDownload)
                }
            } else if !scope.hidesGeneralList,
                      let section = sections.first(where: { $0.isGeneralList }),
                      section.sort != "name", section.sort != "reverse" {
                let items = scopedItems
                let preview = Array(items.prefix(min(page == "today" ? 5 : 6, section.boundedLimit)))
                if !preview.isEmpty {
                    if page == "today" {
                        XSignTodayListCard(items: preview, showsDownload: scope.showsDownload, caption: nil)
                    } else {
                        Text(xsignText(section.title)).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        XSignCatalogueShelf(items: preview, showsDownload: scope.showsDownload)
                    }
                }
            }
        }
        .frame(minHeight: 1)
        .task(id: request) {
            guard rendered?.request != request else { return }
            if let remembered {
                rendered = .init(request: request, layout: remembered)
                return
            }
            let items = scopedItems
            let news = page == "today" ? cache.todayEditorialNews : cache.ipablackEditorialNews
            let featuredIDs = cache.featuredCatalogIDs
            let todayFeatured = cache.todayFeaturedBySource
            let worker = Task.detached(priority: .utility) {
                XSignStoreLayout.make(sections: scope.sections, page: scope.page, items: items, news: news,
                    featuredIDs: featuredIDs, todayFeatured: todayFeatured, showsDownload: scope.showsDownload,
                    hasCompleteList: scope.hasCompleteList, hidesGeneralList: scope.hidesGeneralList)
            }
            let prepared = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, request.revision == cache.catalogRevision, let prepared else { return }
            let entry = XSignStoreLayoutCache.Entry(request: request, layout: prepared)
            XSignStoreLayoutCache.shared.remember(entry)
            rendered = entry
        }
    }
}

@MainActor
private final class XSignStoreLayoutCache {
    static let shared = XSignStoreLayoutCache()

    struct Entry {
        let request: XSignClassicStoreContent.Request
        let layout: XSignStoreLayout
    }

    private var entries: [Entry] = []

    func layout(for request: XSignClassicStoreContent.Request) -> XSignStoreLayout? {
        entries.first { $0.request == request }?.layout
    }

    func remember(_ entry: Entry) {
        entries.removeAll { $0.request.revision != entry.request.revision || $0.request == entry.request }
        entries.insert(entry, at: 0)
        if entries.count > 6 { entries.removeLast() }
    }
}

private struct XSignStoreLayout: Sendable {
    let shelves: [XSignStoreShelf]
    let remaining: [AppStoreAppItem]
    let fallback: [AppStoreAppItem]?

    nonisolated static func make(sections: [XSignStoreSection], page: String, items: [AppStoreAppItem],
                                 news: [TodayEditorialInstruction], featuredIDs: [String], todayFeatured: [URL: [String]],
                                 showsDownload: Bool, hasCompleteList: Bool, hidesGeneralList: Bool) -> Self? {
        let items = items.filter { XSignCatalogKindPolicy.showsInPage(page, isGame: $0.isGame) }
        let completeSectionID = sections.first(where: \.isGeneralList)?.id
        let seeds = sections.map { section in
            XSignStoreSectionSelection(section: section, page: page, pageItems: items, news: news,
                featuredIDs: featuredIDs, todayFeatured: todayFeatured,
                completeItems: hasCompleteList && section.id == completeSectionID ? items : nil)
        }
        var reserved = Set<String>()
        var reservedBySection: [String: Set<String>] = [:]
        if page != "today" {
            let featured = seeds.filter { $0.section.kind == "featured" }
            let ordered = featured.filter { $0.section.app_ids?.isEmpty == false }
                + featured.filter { $0.section.app_ids?.isEmpty != false }
            for seed in ordered {
                guard !Task.isCancelled else { return nil }
                let ids = Set(seed.items(excluding: reserved).prefix(seed.section.previewLimit).map(\.id))
                reservedBySection[seed.section.id] = ids
                reserved.formUnion(ids)
            }
        }
        var used = Set<String>()
        var shelves: [XSignStoreShelf] = []
        for seed in seeds {
            guard !Task.isCancelled else { return nil }
            let excluded = used.union(reserved.subtracting(reservedBySection[seed.section.id] ?? []))
            let entries = seed.items(excluding: excluded)
            var acceptedNews = Set<String>()
            let news = seed.newsEntries.map { entry in
                let app = entry.associatedApp.flatMap {
                    !excluded.contains($0.id) && acceptedNews.insert($0.id).inserted ? $0 : nil
                }
                return XSignStoreNews(entry: entry, app: app)
            }
            used.formUnion(entries.prefix(seed.section.previewLimit).map(\.id))
            used.formUnion(acceptedNews)
            shelves.append(XSignStoreShelf(section: seed.section, page: page, showsDownload: showsDownload,
                completeItems: seed.completeItems, entries: entries, news: news))
        }
        let fallback = hasCompleteList && !items.isEmpty && !hidesGeneralList && completeSectionID == nil ? items : nil
        let feed = shelves.first { shelf in
            page == "today" ? shelf.section.continuesTodayFeed : shelf.completeItems != nil
        }?.entries ?? fallback ?? []
        return Self(shelves: shelves, remaining: feed.filter { !used.contains($0.id) }, fallback: fallback)
    }
}

private struct XSignStoreNews: Sendable {
    let entry: TodayEditorialInstruction
    let app: AppStoreAppItem?
}

private struct XSignStoreShelf: Sendable, Identifiable {
    let section: XSignStoreSection
    let page: String
    let showsDownload: Bool
    let completeItems: [AppStoreAppItem]?
    let entries: [AppStoreAppItem]
    let news: [XSignStoreNews]
    var id: String { section.id }
}

private struct XSignStoreSectionSelection {
    let section: XSignStoreSection
    let page: String
    let pageItems: [AppStoreAppItem]
    let news: [TodayEditorialInstruction]
    let featuredIDs: [String]
    let todayFeatured: [URL: [String]]
    let completeItems: [AppStoreAppItem]?

    private var sectionSource: URL? {
        XSignDashboardSources.sectionSource(section.source_url)
    }

    private var sourceItems: [AppStoreAppItem] {
        guard let sectionSource else { return pageItems }
        return pageItems.filter { $0.sourceURLs.contains(sectionSource) }
    }

    func items(excluding ids: Set<String>) -> [AppStoreAppItem] {
        guard section.kind == "featured" || section.kind == "apps" else { return [] }
        var result = (completeItems ?? sourceItems).filter { !ids.contains($0.id) }
        if let key = XSignCatalogKindPolicy.categoryKey(section.category_id) {
            result = result.filter { $0.categoryKeys.contains(key) }
        }
        let explicit = section.app_ids.flatMap { $0.isEmpty ? nil : $0 }
        if let explicit {
            result = ordered(result, by: explicit)
        } else if section.kind == "featured" {
            if page == "today" {
                var groupOrder: [URL] = []
                var grouped: [URL: [AppStoreAppItem]] = [:]
                for item in result {
                    for url in item.sourceURLs.sorted(by: { $0.absoluteString < $1.absoluteString }) {
                        if grouped[url] == nil { groupOrder.append(url) }
                        grouped[url, default: []].append(item)
                    }
                }
                let groups = groupOrder.compactMap { url -> [AppStoreAppItem]? in
                    guard sectionSource == nil || sectionSource == url, let group = grouped[url] else { return nil }
                    let matches = ordered(group, by: todayFeatured[url] ?? [])
                    return matches.isEmpty ? group : matches
                }
                var seen = Set<String>()
                result = XSignTodaySourcePolicy.interleave(groups).filter { seen.insert($0.id).inserted }
            } else if sectionSource == nil {
                let matches = ordered(result, by: featuredIDs)
                if !matches.isEmpty { result = matches }
            }
        }
        if section.sort == "name" { result.sort { $0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending } }
        if section.sort == "reverse" { result.reverse() }
        return result
    }

    private func ordered(_ items: [AppStoreAppItem], by ids: [String]) -> [AppStoreAppItem] {
        let key: (String) -> String = { $0.lowercased() }
        let requested = Set(ids.map(key))
        var byID: [String: [AppStoreAppItem]] = [:]
        for item in items {
            let keys = Set(item.sourceCatalogIDs.map(key))
            for match in keys where requested.contains(match) {
                byID[match, default: []].append(item)
            }
        }
        var seen = Set<String>()
        return ids.flatMap { byID[key($0)] ?? [] }.filter { seen.insert($0.id).inserted }
    }
    var newsEntries: [TodayEditorialInstruction] {
        guard section.kind == "news" else { return [] }
        let source = sectionSource
        let visibleIDs = page == "today" ? [] : Set(pageItems.map(\.id))
        return Array(news.lazy.filter { item in
            (source == nil || item.sourceURL == source) &&
                (page == "today" || item.associatedApp.map { visibleIDs.contains($0.id) } == true)
        }.prefix(section.boundedLimit))
    }
}

private struct XSignClassicStoreSection: View {
    let shelf: XSignStoreShelf
    let cache: AppStoreCacheManager
    private var section: XSignStoreSection { shelf.section }
    private var page: String { shelf.page }
    private var showsDownload: Bool { shelf.showsDownload }
    private var completeItems: [AppStoreAppItem]? { shelf.completeItems }

    var body: some View {
        if section.kind == "news" {
            if page == "today", !shelf.news.isEmpty {
                if !isGenericNewsTitle { todayHeading(section.title) }
                ForEach(shelf.news, id: \.entry.id) { news in
                    let entry = news.entry
                    XSignTodayFeatureCard(item: news.app, title: entry.title, caption: entry.caption,
                        badge: entry.badge, artwork: entry.imageURL, tint: entry.tintColor,
                        targetURL: entry.targetURL, showsDownload: showsDownload)
                }
            } else {
                ForEach(shelf.news.filter { $0.app != nil || $0.entry.associatedApp == nil }, id: \.entry.id) { news in
                    XSignAnnouncementCard(instruction: news.entry)
                }
            }
        } else if section.kind == "categories" {
            let groups = cache.categories(for: page, section: section)
            if !groups.isEmpty {
                XSignStoreCategoryBar(title: section.title) {
                    ForEach(groups) { group in
                        NavigationLink {
                            XSignClassicCatalogueList(title: group.title, items: group.items, showsDownload: showsDownload)
                        } label: {
                            XSignStoreCategoryPill(title: group.title, symbol: group.symbol, svg: group.iconSVG)
                        }.buttonStyle(.plain)
                    }
                }
            }
        } else {
            let entries = shelf.entries
            if !entries.isEmpty || completeItems?.isEmpty == false {
                if section.kind == "featured" {
                    featuredCards(Array(entries.prefix(section.previewLimit)))
                } else if page == "today" {
                    todayHeading(section.title)
                    let visible = Array(entries.prefix(section.boundedLimit))
                    ForEach(Array(stride(from: 0, to: visible.count, by: 5)), id: \.self) { start in
                        XSignTodayListCard(items: Array(visible.dropFirst(start).prefix(5)), showsDownload: showsDownload, caption: nil)
                    }
                } else {
                    shelfHeading(items: completeItems ?? entries)
                    XSignCatalogueShelf(items: Array(entries.prefix(section.boundedLimit)), showsDownload: showsDownload)
                }
            }
        }
    }

    private var isGenericNewsTitle: Bool {
        ["الأخبار", "آخر الأخبار"].contains(section.title)
    }

    private func todayHeading(_ title: String) -> some View {
        Text(xsignText(title)).font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func featuredCards(_ entries: [AppStoreAppItem]) -> some View {
        if let first = entries.first {
            if page == "today" {
                if section.id != "today-featured" { todayHeading(section.title) }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                    XSignTodayFeatureCard(item: item, title: item.app.currentName, caption: xsignText(xsignText(item.arabicSubtitle)),
                        badge: index == 0 && section.id == "today-featured" ? section.title : nil,
                        artwork: nil, tint: item.app.tintColor,
                        showsDownload: showsDownload, compact: section.id == "today-featured" && index == 1)
                }
            } else {
                shelfHeading(items: entries)
                if section.app_ids?.isEmpty == false && entries.count > 1 {
                    XSignFeaturedGallery(items: entries)
                } else {
                    AppStore2026FeaturedBanner(item: first)
                    if entries.count > 1 {
                        XSignCatalogueShelf(items: Array(entries.dropFirst()), showsDownload: showsDownload)
                    }
                }
            }
        }
    }

    private func shelfHeading(items: [AppStoreAppItem]) -> some View {
        NavigationLink {
            XSignClassicCatalogueList(title: section.title, items: items, showsDownload: showsDownload)
        } label: {
            HStack(spacing: 8) {
                Text(xsignText(section.title)).font(.title3.bold())
                Spacer(minLength: 6)
                Image(systemName: "chevron.backward").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct XSignFeaturedGallery: View {
    let items: [AppStoreAppItem]
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    AppStore2026FeaturedBanner(item: item)
                        .frame(width: max(1, availableWidth - 22))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { availableWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { availableWidth = $0 }
        })
    }
}

private struct XSignCatalogueShelf: View {
    let items: [AppStoreAppItem]
    var showsDownload = true
    @ScaledMetric(relativeTo: .body) private var rowHeight = 72.0
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { start in
                    let group = items.dropFirst(start).prefix(3)
                    VStack(spacing: 0) {
                        ForEach(group) { item in
                            AppStore2026AppRow(item: item, showsDownload: showsDownload)
                                .frame(minHeight: rowHeight)
                            if item.id != group.last?.id {
                                Divider().padding(.leading, 62).accessibilityHidden(true)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(width: max(1, availableWidth - (items.count > 3 ? 22 : 0)))
                    .xsignSurface(radius: 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { availableWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { availableWidth = $0 }
        })
    }
}

struct XSignCatalogueFeed: View {
    let items: [AppStoreAppItem]
    var showsDownload = true

    @State private var visibleLimit = 36

    var body: some View {
        let slice = items.prefix(visibleLimit)
        XSignCatalogueRows(items: slice, hasMore: slice.count < items.count, showsDownload: showsDownload) {
            visibleLimit = min(items.count, visibleLimit + 36)
        }
    }
}

struct XSignCatalogueRows: View {
    let items: ArraySlice<AppStoreAppItem>
    var hasMore = false
    var showsDownload = true
    var loadMore: () -> Void = {}

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                VStack(spacing: 0) {
                    AppStore2026AppRow(item: item, showsDownload: showsDownload)
                    if item.id != items.last?.id {
                        Divider().padding(.leading, 62).accessibilityHidden(true)
                    }
                }
            }
            if hasMore {
                Color.clear.frame(height: 1)
                    .accessibilityHidden(true)
                    .id(items.endIndex)
                    .onAppear(perform: loadMore)
            }
        }
    }
}

struct XSignClassicCatalogueList: View {
    let title: String
    let items: [AppStoreAppItem]
    var showsDownload = true

    var body: some View {
        ScrollView {
            XSignCatalogueFeed(items: items, showsDownload: showsDownload).padding(18)
        }
        .navigationTitle(xsignText(title))
        .xsignPageBackground()
    }
}

struct XSignCategoryIcon: View {
    let svg: String?
    let symbol: String
    var size: CGFloat = 17

    var body: some View {
        Group {
            if let svg, XSignCategorySVG.accepts(svg) {
                XSignCategorySVG(svg: svg)
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.8, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct XSignCategorySVG: UIViewRepresentable {
    let svg: String

    static func accepts(_ value: String) -> Bool {
        guard value.utf8.count <= 8192, !value.isEmpty,
              value.range(of: #"<\s*[!?]"#, options: .regularExpression) == nil else { return false }
        let validator = Validator()
        let parser = XMLParser(data: Data(value.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = validator
        return parser.parse() && parser.parserError == nil && validator.hasRoot
    }

    final class Validator: NSObject, XMLParserDelegate {
        private static let elements: Set<String> = [
            "svg", "g", "path", "circle", "ellipse", "rect", "line", "polyline", "polygon",
            "title", "desc", "defs", "linearGradient", "radialGradient", "stop", "clipPath", "mask"
        ]
        var hasRoot = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attributeDict: [String: String]) {
            guard Self.elements.contains(elementName), hasRoot || elementName == "svg",
                  !attributeDict.keys.contains(where: { name in
                      let key = name.lowercased()
                      return key.hasPrefix("on") || key.hasPrefix("xlink:") ||
                          ["href", "src", "style", "xml:base"].contains(key)
                  }) else {
                parser.abortParsing()
                return
            }
            hasRoot = true
        }
    }

    final class Coordinator {
        var renderedSVG: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.renderedSVG != svg else { return }
        context.coordinator.renderedSVG = svg
        view.loadHTMLString("""
        <!doctype html>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>html,body{margin:0;background:transparent;color-scheme:light dark}svg{display:block;width:100vw;height:100vh}</style>
        \(svg)
        """, baseURL: nil)
    }
}
