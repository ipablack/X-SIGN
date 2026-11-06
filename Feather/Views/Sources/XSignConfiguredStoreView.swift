import SwiftUI
import CoreData
import NukeUI

struct XSignStoreSource: Identifiable {
    let id: String
    let name: String
    let icon: URL?
    let count: Int
}

struct XSignConfiguredStorePage: View {
    let page: String
    let title: String
    @ObservedObject private var cache = AppStoreCacheManager.shared
    @ObservedObject private var remote = XSignRemoteManager.shared
    @ObservedObject private var viewModel = SourcesViewModel.shared
    @State private var settings = false
    @FetchRequest(entity:AltSource.entity(),sortDescriptors:[NSSortDescriptor(keyPath:\AltSource.name,ascending:true)])
    private var sources: FetchedResults<AltSource>
    private var sections: [XSignStoreSection] {
        if let dashboard=remote.config?.dashboard { return dashboard.sections(for:page) }
        return XSignDashboardConfig.defaultSections.filter { $0.page == page }
    }
    var body: some View {
        XSignNavigationView {
            ScrollView {
                LazyVStack(alignment:.leading,spacing:24) {
                    AppStore2026TopHeader(title:title,onSettingsTap:{ settings=true })
                    if page == "today" {
                        Text(Date(),format:.dateTime.weekday(.wide).day().month(.wide)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(sections) { section in
                        XSignConfiguredStoreSection(section:section,page:page,cache:cache)
                    }
                    if cache.allCombinedItems.isEmpty {
                        AppStore2026EmptyState(isLoading:cache.isRefreshing || cache.isPreparing,
                            emptyMessage:cache.catalogErrorMessage ?? "لا توجد تطبيقات بعد. يمكنك إضافة مصدر من الإعدادات.",
                            retry:{ Task { await cache.forceRefresh(sources:sources,viewModel:viewModel) } })
                    }
                }.padding(.horizontal,18).padding(.bottom,110)
            }
            .background(AppStoreTheme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await cache.forceRefresh(sources:sources,viewModel:viewModel) }
            .sheet(isPresented:$settings,onDismiss:{ AutoSignPipelineManager.shared.presentNextReadyApp() }) {
                AppStore2026SettingsPopup(sources:sources,viewModel:viewModel)
            }
        }
        .environment(\.layoutDirection,.rightToLeft)
        .task(id:sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            await cache.ensureFetched(sources:sources,viewModel:viewModel)
        }
    }
}

private struct XSignConfiguredStoreSection: View {
    let section: XSignStoreSection
    let page: String
    @ObservedObject var cache: AppStoreCacheManager
    @State private var visible = 60
    private var items: [AppStoreAppItem] {
        var result=page == "games" ? cache.pureGamesOnly : page == "apps" ? cache.pureAppsOnly : cache.allCombinedItems
        if let source=section.source_url, let url=URL(string:source) {
            result=result.filter { $0.sourceURL.map(XSignCatalogIO.canonicalURL) == XSignCatalogIO.canonicalURL(url) }
        }
        if let category=section.category_id, !category.isEmpty { result=result.filter { $0.app.category == category } }
        let selectedIDs=section.app_ids ?? (section.kind == "featured" ? cache.featuredCatalogIDs : nil)
        if let ids=selectedIDs, !ids.isEmpty || section.kind == "featured" {
            result=ids.flatMap { id in result.filter { $0.app.id == id || $0.app.catalogID == id } }
        }
        if section.sort == "name" { result.sort { $0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending } }
        if section.sort == "reverse" { result.reverse() }
        return result
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if !section.title.isEmpty { Text(section.title).font(.title2.bold()) }
            switch section.kind {
            case "news":
                ForEach(Array(cache.ipablackEditorialNews.prefix(section.boundedLimit))) { item in XSignAnnouncementCard(instruction:item) }
            case "sources":
                ForEach(Array(cache.storeSources.prefix(section.boundedLimit))) { source in
                    NavigationLink { XSignSourceStoreDetail(source:source) } label: { XSignStoreSourceRow(source:source) }.buttonStyle(.plain)
                }
            case "categories":
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack {
                        ForEach(Array(cache.sourceCategories.filter { page == "today" || ($0.isGame ?? false) == (page == "games") }.prefix(section.boundedLimit)),id:\.id) { category in
                            NavigationLink {
                                XSignCatalogList(title:category.name,category:category.id,source:nil,onlyGames:page == "games")
                            } label: { Text(category.name).font(.subheadline.bold()).padding(12).background(AppStoreTheme.cardSurface,in:Capsule()) }
                        }
                    }
                }
            case "featured":
                ScrollView(.horizontal,showsIndicators:false) {
                    LazyHStack(spacing:14) {
                        ForEach(Array(items.prefix(min(12,section.boundedLimit)))) { item in
                            NavigationLink { AppStore2026DetailView(item:item) } label: { AppStore2026FeaturedBanner(item:item) }.buttonStyle(.plain)
                        }
                    }
                }
            default:
                ForEach(Array(items.prefix(min(visible,section.boundedLimit)))) { item in
                    NavigationLink { AppStore2026DetailView(item:item) } label: { AppStore2026AppRow(item:item) }.buttonStyle(.plain)
                    Divider()
                }
                if items.count > min(visible,section.boundedLimit) {
                    NavigationLink("عرض الكل (\(items.count))") {
                        XSignCatalogList(title:section.title,category:section.category_id,source:section.source_url,onlyGames:page == "games",appIDs:section.app_ids)
                    }
                }
            }
        }
    }
}

struct XSignStoreSourceRow: View {
    let source: XSignStoreSource
    var body: some View {
        HStack(spacing:12) {
            LazyImage(url:source.icon) { state in
                if let image=state.image { image.resizable().scaledToFit() }
                else { Image(systemName:"shippingbox.fill").resizable().scaledToFit().padding(10).foregroundStyle(Color.accentColor) }
            }.frame(width:52,height:52).background(AppStoreTheme.cardSurface).clipShape(RoundedRectangle(cornerRadius:12))
            VStack(alignment:.leading,spacing:4) {
                Text(source.name).font(.headline)
                Text("\(source.count) تطبيق").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName:"chevron.left").font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(AppStoreTheme.cardSurface,in:RoundedRectangle(cornerRadius:16))
    }
}

private struct XSignSourceStoreDetail: View {
    let source: XSignStoreSource
    var body: some View { XSignCatalogList(title:source.name,category:nil,source:source.id,onlyGames:nil) }
}

private struct XSignCatalogList: View {
    let title: String
    let category: String?
    let source: String?
    let onlyGames: Bool?
    var appIDs: [String]? = nil
    @ObservedObject private var cache=AppStoreCacheManager.shared
    @State private var limit=60
    private var items: [AppStoreAppItem] {
        cache.allCombinedItems.filter { item in
            (onlyGames.map { item.isGame == $0 } ?? true) &&
            (category == nil || item.app.category == category) &&
            (source == nil || item.sourceURL.map(XSignCatalogIO.canonicalURL) == source.flatMap(URL.init(string:)).map(XSignCatalogIO.canonicalURL)) &&
            (appIDs?.isEmpty != false || appIDs!.contains(item.app.id ?? "") || appIDs!.contains(item.app.catalogID ?? ""))
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(spacing:12) {
                ForEach(Array(items.prefix(limit))) { item in
                    NavigationLink { AppStore2026DetailView(item:item) } label: { AppStore2026AppRow(item:item) }.buttonStyle(.plain)
                }
                if limit < items.count { Button("عرض المزيد") { limit += 60 } }
            }.padding(18)
        }.navigationTitle(title).background(AppStoreTheme.background)
    }
}
