import SwiftUI
import CoreData
import NukeUI

struct XSignStoreSource: Identifiable {
    let id: String
    let name: String
    let icon: URL?
    let count: Int
}

// Keep the original App Store cards while applying published content and order.
// Source-management rows and owner diagnostics are not customer-facing sections.
struct XSignClassicStoreContent: View {
    let page: String
    var category: AppStore2026Category? = nil
    @ObservedObject private var cache = AppStoreCacheManager.shared
    @ObservedObject private var remote = XSignRemoteManager.shared
    private var sections: [XSignStoreSection] {
        (remote.config?.dashboard?.sections(for: page)
            ?? XSignDashboardConfig.defaultSections.filter { $0.page == page })
            .filter { $0.kind != "sources" }
    }
    var body: some View {
        ForEach(sections) { section in
            XSignClassicStoreSection(section: section, page: page, category: category, cache: cache)
        }
    }
}

private struct XSignClassicStoreSection: View {
    let section: XSignStoreSection
    let page: String
    let category: AppStore2026Category?
    @ObservedObject var cache: AppStoreCacheManager
    private var pageItems: [AppStoreAppItem] {
        switch page {
        case "games": return cache.pureGamesOnly
        case "apps": return cache.pureAppsOnly
        default: return cache.todayItems
        }
    }

    private var items: [AppStoreAppItem] {
        var result = pageItems
        if let category { result = result.filter { $0.category == category } }
        if let source = section.source_url.flatMap(URL.init(string:)) {
            result = result.filter { $0.sourceURL.map(XSignCatalogIO.canonicalURL) == XSignCatalogIO.canonicalURL(source) }
        }
        if let id = section.category_id, !id.isEmpty { result = result.filter { $0.app.category == id } }
        let featured = page == "today" ? cache.todayFeaturedIDs : cache.featuredCatalogIDs
        let ids = section.app_ids ?? (section.kind == "featured" && !featured.isEmpty ? featured : nil)
        if let ids {
            var seen = Set<String>()
            result = ids.flatMap { id in result.filter { $0.app.id == id || $0.app.catalogID == id } }
                .filter { seen.insert($0.id).inserted }
        }
        if section.sort == "name" { result.sort { $0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending } }
        if section.sort == "reverse" { result.reverse() }
        return result
    }
    var body: some View {
        let entries = items
        if section.kind == "news" {
            let news = page == "today" ? cache.todayEditorialNews : cache.ipablackEditorialNews
            let visibleIDs = Set(pageItems.map(\.id))
            ForEach(Array(news.filter { item in
                guard page != "today", let app = item.associatedApp else { return true }
                return visibleIDs.contains(app.id)
            }.prefix(section.boundedLimit))) { XSignAnnouncementCard(instruction: $0) }
        } else if section.kind == "categories" {
            let categories = page == "today" ? cache.todayCategories : cache.sourceCategories
            let groups = Dictionary(grouping: pageItems) { $0.app.category ?? "" }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(categories.filter { groups[$0.id] != nil }.prefix(section.boundedLimit)), id: \.id) { item in
                        NavigationLink {
                            XSignClassicCatalogueList(title: item.name, items: groups[item.id] ?? [])
                        } label: {
                            Text(item.name).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .xsignSurface(radius: 20)
                        }.buttonStyle(.plain)
                    }
                }
            }
        } else if !entries.isEmpty {
            if section.kind == "featured", page == "today", category == nil, let first = entries.first {
                XSignTodayFeatureCard(item: first, sourceName: "XSign")
            }
            Text(section.title).font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            XSignCatalogueFeed(items: section.kind == "featured" ? Array(entries.prefix(section.boundedLimit)) : entries)
                .id(category)
        }
    }
}

struct XSignCatalogueFeed: View {
    let items: [AppStoreAppItem]
    @State private var limit = 60

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(items.prefix(limit)) { item in
                AppStore2026AppRow(item: item)
            }
            if limit < items.count {
                Color.clear.frame(height: 1)
                    .accessibilityHidden(true)
                    .id(limit)
                    .onAppear {
                        limit = min(limit + 60, items.count)
                    }
            }
        }
    }
}

private struct XSignClassicCatalogueList: View {
    let title: String
    let items: [AppStoreAppItem]

    var body: some View {
        ScrollView {
            XSignCatalogueFeed(items: items).padding(18)
        }
        .navigationTitle(title)
        .background(AppStoreTheme.background.ignoresSafeArea())
    }
}
