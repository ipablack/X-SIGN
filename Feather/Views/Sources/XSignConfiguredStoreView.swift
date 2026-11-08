import SwiftUI
import CoreData
import UIKit

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
    @ObservedObject private var cache = AppStoreCacheManager.shared
    @ObservedObject private var remote = XSignRemoteManager.shared
    private var sections: [XSignStoreSection] {
        (remote.config?.dashboard?.sections(for: page)
            ?? XSignDashboardConfig.defaultSections.filter { $0.page == page })
            .filter {
                $0.kind != "sources" && (page != "today" ||
                    !isLiveNowTitle($0.title))
            }
    }
    private func isLiveNowTitle(_ title: String) -> Bool {
        ["يحدث الآن", "يحدث الان"].contains(title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        ForEach(sections) { section in
            XSignClassicStoreSection(section: section, page: page, cache: cache)
        }
    }
}

private struct XSignClassicStoreSection: View {
    let section: XSignStoreSection
    let page: String
    let cache: AppStoreCacheManager
    private var pageItems: [AppStoreAppItem] {
        switch page {
        case "games": return cache.pureGamesOnly
        case "apps": return cache.pureAppsOnly
        default: return cache.todayItems
        }
    }

    private var sectionSource: URL? {
        section.source_url.flatMap(URL.init(string:)).map(XSignCatalogIO.canonicalURL)
    }

    private var sourceItems: [AppStoreAppItem] {
        guard let sectionSource else { return pageItems }
        return pageItems.filter { $0.sourceURL == sectionSource }
    }

    private var items: [AppStoreAppItem] {
        var result = sourceItems
        if let id = section.category_id, !id.isEmpty { result = result.filter { $0.app.category == id } }
        let featured = page == "today" ? cache.todayFeaturedIDs : cache.featuredCatalogIDs
        let ids = section.app_ids ?? (section.kind == "featured" && !featured.isEmpty ? featured : nil)
        if let ids {
            let requested = Set(ids)
            var byID: [String: [AppStoreAppItem]] = [:]
            for item in result {
                let keys = Set([item.app.id, item.app.catalogID].compactMap { $0 })
                for key in keys where requested.contains(key) {
                    byID[key, default: []].append(item)
                }
            }
            var seen = Set<String>()
            let matches = ids.flatMap { byID[$0] ?? [] }.filter { seen.insert($0.id).inserted }
            if section.app_ids != nil || !matches.isEmpty { result = matches }
        }
        if section.sort == "name" { result.sort { $0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending } }
        if section.sort == "reverse" { result.reverse() }
        return result
    }
    var body: some View {
        if section.kind == "news" {
            let news = page == "today" ? cache.todayEditorialNews : cache.ipablackEditorialNews
            let source = sectionSource
            let visibleIDs = page == "today" ? [] : Set(pageItems.map(\.id))
            ForEach(Array(news.lazy.filter { item in
                (source == nil || item.sourceURL == source) &&
                    (page == "today" || item.associatedApp.map { visibleIDs.contains($0.id) } == true)
            }.prefix(section.boundedLimit))) { XSignAnnouncementCard(instruction: $0) }
        } else if section.kind == "categories" {
            let categories = page == "today" ? cache.todayCategories : cache.sourceCategories
            let groups = Dictionary(grouping: sourceItems) { $0.app.category ?? "" }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(categories.filter { groups[$0.id] != nil }.prefix(section.boundedLimit)), id: \.id) { item in
                        NavigationLink {
                            XSignClassicCatalogueList(title: item.name, items: groups[item.id] ?? [])
                        } label: {
                            Text(item.name).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(AppStoreTheme.controlSurface, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        } else {
            let entries = items
            if !entries.isEmpty {
                if section.kind == "featured" {
                    featuredCards(Array(entries.prefix(section.boundedLimit)))
                } else {
                    Text(section.title).font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                    XSignCatalogueFeed(items: page == "today" ? Array(entries.prefix(section.boundedLimit)) : entries)
                }
            }
        }
    }

    @ViewBuilder
    private func featuredCards(_ entries: [AppStoreAppItem]) -> some View {
        if let first = entries.first {
            if page == "today" {
                XSignTodayFeatureCard(item: first)
                let compact = entries.dropFirst().prefix(2)
                if !compact.isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(compact) { item in
                            NavigationLink { AppStore2026DetailView(item: item) } label: {
                                XSignTodaySmallCard(item: item)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                let remaining = Array(entries.dropFirst(3).prefix(4))
                if !remaining.isEmpty {
                    TodayFourAppsListCard(outerTitle: nil, outerSubtitle: nil,
                        innerCaption: section.title, innerTitle: "اكتشف تطبيقك القادم", items: remaining)
                }
            } else {
                if page == "games" {
                    NavigationLink { AppStore2026DetailView(item: first) } label: {
                        TodayLiveEventHeroCard(outerTitle: nil, outerSubtitle: nil, cornerBadge: "مختارات",
                            eventTag: "رائج الآن", headline: "العب \(first.app.currentName)",
                            descriptionText: first.arabicSubtitle, bannerImageURL: first.screenshots.first,
                            cardColor: Color.accentColor, item: first)
                    }.buttonStyle(.plain)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
                            ForEach(entries.prefix(6)) { AppStore2026FeaturedBanner(item: $0) }
                        }
                    }
                }
                NavigationLink {
                    XSignClassicCatalogueList(title: section.title, items: entries)
                } label: {
                    HStack {
                        Text(section.title).font(.title3.bold())
                        Spacer()
                        Image(systemName: "chevron.backward").font(.caption.weight(.semibold))
                    }
                }.buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Self.featuredRows, spacing: 16) {
                        ForEach(entries.prefix(18)) { item in
                            AppStore2026AppRow(item: item).frame(width: min(UIScreen.main.bounds.width - 48, 320))
                        }
                    }
                }
            }
        }
    }

    private static let featuredRows = Array(repeating: GridItem(.fixed(72), spacing: 12), count: 3)

}

struct XSignCatalogueFeed: View {
    let items: [AppStoreAppItem]
    private static let pageSize = 40
    @State private var limit = XSignCatalogueFeed.pageSize

    var body: some View {
        let end = min(limit, items.count)
        XSignCatalogueRows(items: items.prefix(end), hasMore: end < items.count) {
            guard limit == end else { return }
            limit = min(end + Self.pageSize, items.count)
        }
    }
}

struct XSignCatalogueRows: View {
    let items: ArraySlice<AppStoreAppItem>
    let hasMore: Bool
    let loadMore: () -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                VStack(spacing: 0) {
                    AppStore2026AppRow(item: item)
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

private struct XSignClassicCatalogueList: View {
    let title: String
    let items: [AppStoreAppItem]

    var body: some View {
        ScrollView {
            XSignCatalogueFeed(items: items).padding(18)
        }
        .navigationTitle(title)
        .xsignPageBackground()
    }
}
