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
    private var items: [AppStoreAppItem] {
        var result = page == "games" ? cache.pureGamesOnly : page == "apps" ? cache.pureAppsOnly : cache.todayItems
        if let category { result = result.filter { $0.category == category } }
        if let source = section.source_url.flatMap(URL.init(string:)) {
            result = result.filter { $0.sourceURL.map(XSignCatalogIO.canonicalURL) == XSignCatalogIO.canonicalURL(source) }
        }
        if let id = section.category_id, !id.isEmpty { result = result.filter { $0.app.category == id } }
        let featured = page == "today" ? cache.todayFeaturedIDs : cache.featuredCatalogIDs
        let ids = section.app_ids ?? (section.kind == "featured" && !featured.isEmpty ? featured : nil)
        if let ids { result = ids.flatMap { id in result.filter { $0.app.id == id || $0.app.catalogID == id } } }
        if section.sort == "name" { result.sort { $0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending } }
        if section.sort == "reverse" { result.reverse() }
        return result
    }
    var body: some View {
        Group {
            if section.kind == "news" {
                ForEach(Array((page == "today" ? cache.todayEditorialNews : cache.ipablackEditorialNews).prefix(section.boundedLimit))) { XSignAnnouncementCard(instruction: $0) }
            } else if section.kind == "categories" {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array((page == "today" ? cache.todayCategories : cache.sourceCategories).filter { page == "today" || ($0.isGame ?? false) == (page == "games") }.prefix(section.boundedLimit)), id: \.id) { item in
                            NavigationLink {
                                XSignClassicCatalogueList(title: item.name, items: (page == "today" ? cache.todayItems : cache.allCombinedItems).filter { $0.app.category == item.id })
                            } label: {
                                Text(item.name).font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 9)
                                    .background(AppStoreTheme.controlSurface, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } else if !items.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    if section.kind == "featured", category == nil {
                        if page == "today", let first = items.first {
                            XSignTodayFeatureCard(item: first, sourceName: "XSign")
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(Array(items.dropFirst().prefix(2))) { item in
                                    NavigationLink { AppStore2026DetailView(item: item) } label: { XSignTodaySmallCard(item: item) }.buttonStyle(.plain)
                                }
                            }
                        } else if page == "games", let first = items.first {
                            NavigationLink { AppStore2026DetailView(item: first) } label: {
                                TodayLiveEventHeroCard(outerTitle: nil, outerSubtitle: nil, cornerBadge: "يحدث الآن", eventTag: "رائج الآن",
                                    headline: "العب مواجهة \(first.app.currentName)", descriptionText: first.arabicSubtitle,
                                    bannerImageURL: first.screenshots.first, cardColor: Color.accentColor, item: first)
                            }.buttonStyle(.plain)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 16) {
                                    ForEach(Array(items.prefix(min(6, section.boundedLimit)))) { item in
                                        NavigationLink { AppStore2026DetailView(item: item) } label: { AppStore2026FeaturedBanner(item: item) }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        AppStore2026ThreeRowSection(title: section.title, subtitle: page == "games" ? "أقوى الألعاب المختارة لك" : "أفضل التطبيقات المختارة لك", items: Array(items.prefix(min(18, section.boundedLimit)))).padding(.horizontal, -18)
                    } else {
                        HStack { Text(section.title).font(.system(size: 22, weight: .bold)); Spacer() }
                        if page == "today" {
                            TodayFourAppsListCard(outerTitle: nil, outerSubtitle: nil, innerCaption: "اكتشف تطبيقك القادم", innerTitle: section.title, items: Array(items.prefix(min(8, section.boundedLimit))))
                        } else {
                            ForEach(Array(items.prefix(section.boundedLimit))) { item in
                                NavigationLink { AppStore2026DetailView(item: item) } label: { AppStore2026AppRow(item: item) }.buttonStyle(.plain)
                                Divider().padding(.leading, 64)
                            }
                            if items.count > section.boundedLimit {
                                NavigationLink("عرض الكل (\(items.count))") { XSignClassicCatalogueList(title: section.title, items: items) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct XSignClassicCatalogueList: View {
    let title: String
    let items: [AppStoreAppItem]
    @State private var limit = 60
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(items.prefix(limit))) { item in
                    NavigationLink { AppStore2026DetailView(item: item) } label: { AppStore2026AppRow(item: item) }.buttonStyle(.plain)
                }
                if limit < items.count { Button("عرض المزيد") { limit += 60 } }
            }.padding(18)
        }.navigationTitle(title).background(AppStoreTheme.background)
    }
}
