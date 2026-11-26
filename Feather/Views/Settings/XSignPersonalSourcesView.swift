import SwiftUI
import CoreData

struct XSignPersonalSourcesView: View {
    @ObservedObject private var model = SourcesViewModel.shared
    @ObservedObject private var remote = XSignRemoteManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    let showsClose: Bool
    @ObservedObject private var cache = AppStoreCacheManager.shared
    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)])
    private var sources: FetchedResults<AltSource>
    init(showsClose: Bool = false) {
        self.showsClose = showsClose
    }

    private var personalSources: [AltSource] {
        sources.filter { source in
            guard !source.isDeleted, let url = source.sourceURL else { return false }
            return XSignDashboardSources.isExplicitUserSource(url)
                && !XSignDashboardSources.isHidden(url.absoluteString)
                && !AppStoreCacheManager.availableManagedSources().contains { $0.safeURL.map(XSignDashboardSources.sourceKey) == XSignDashboardSources.sourceKey(url) } && !ProtectedSourcesVault.isRetiredSource(url)
        }
    }
    var body: some View {
        List {
            Section {
                NavigationLink {
                    XSignAllSourceAppsView()
                } label: {
                    Label(xsignText("كل تطبيقات المصادر"), systemImage: "square.stack")
                }
                Button { adding = true } label: { Label("إضافة مصدر", systemImage: "plus.circle.fill") }
                    .disabled(remote.config?.dashboard?.userSourcesEnabled == false)
            } footer: {
                Text(xsignText("تظهر التطبيقات المستوردة في قسم التوقيع."))
            }
            Section("مصادرك") {
                if personalSources.isEmpty { Text("لم تضف مصادر بعد.").foregroundStyle(.secondary) }
                ForEach(personalSources, id: \.objectID) { source in
                    NavigationLink {
                        SourceAppsView(object: [source], viewModel: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                AppStoreIconView(url: source.iconURL, size: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name ?? xsignText("مصدر")).font(.headline)
                                    if let count = model.sources[source]?.apps.count {
                                        Text("\(count) تطبيق").font(.caption).foregroundStyle(.secondary)
                                    } else if model.errors[source] == nil {
                                        Text("جارٍ التحديث…").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if let error = model.errors[source] {
                                Text(xsignText(error)).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            if let url = source.sourceURL { XSignDashboardSources.unregisterUser(url) }
                            Storage.shared.deleteSource(for: source)
                            cache.rebuildCacheIfNeeded(sources: sources.filter { $0.objectID != source.objectID },
                                                       repositoriesMap: model.sources)
                        } label: { Label("حذف", systemImage: "trash") }
                    }
                }
            }
        }
        .xsignListBackground()
        .navigationTitle("المصادر")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if showsClose { Button(xsignText("تم")) { dismiss() } }
            }
        }
        .sheet(isPresented: $adding) { CustomSafeAddSourceSheet() }
        .refreshable { await AppStoreCacheManager.shared.forceRefresh(sources: sources, viewModel: model) }
        .task(id: sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            await AppStoreCacheManager.shared.ensureFetched(sources: sources, viewModel: model)
        }
    }
}


private struct XSignAllSourceAppsView: View {
    @ObservedObject private var cache = AppStoreCacheManager.shared
    @State private var search = ""
    @State private var sort = SourceAppsView.SortOption.default
    @State private var matches: [AppStoreAppItem] = []
    @State private var displayedFilter: Filter?

    private struct Filter: Equatable, Sendable {
        let revision: UInt64
        let query: String
        let sort: SourceAppsView.SortOption
    }

    var body: some View {
        let query = AppStoreBilingualEngine.normalize(search)
        let needsFilter = !query.isEmpty || sort != .default
        let filter = Filter(revision: cache.catalogRevision, query: query, sort: sort)
        let isFiltering = needsFilter && displayedFilter != filter
        let apps = needsFilter ? matches : cache.allCombinedItems
        List {
            if isFiltering {
                ProgressView().frame(maxWidth: .infinity)
            } else if apps.isEmpty {
                if !cache.hasLoadedCatalog {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(xsignText(query.isEmpty ? "لا توجد تطبيقات في المصادر المفعّلة." : "لا توجد نتائج مطابقة."))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(apps) { item in
                    HStack(spacing: 10) {
                        NavigationLink {
                            XSignAppStoreProductPage(item: item, importsToLibrary: true)
                        } label: {
                            HStack(spacing: 10) {
                                AppStoreIconView(url: item.app.iconURL, size: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.app.currentName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(item.app.currentVersion ?? "—").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        DownloadButtonView(url: item.app.currentDownloadUrl, provenance: item.downloadProvenance())
                    }
                }
            }
        }
        .xsignListBackground()
        .navigationTitle(xsignText("كل تطبيقات المصادر"))
        .searchable(text: $search, prompt: Text(xsignText("بحث")))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker(xsignText("ترتيب"), selection: $sort) {
                        ForEach(SourceAppsView.SortOption.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .accessibilityLabel(Text(xsignText("ترتيب")))
                }
            }
        }
        .task(id: filter) {
            guard needsFilter else { matches = []; displayedFilter = nil; return }
            do { try await Task.sleep(nanoseconds: 170_000_000) } catch { return }
            let entries = cache.allCombinedItems
            let worker = Task.detached(priority: .userInitiated) {
                let selected = query.isEmpty ? entries : entries.filter {
                    !Task.isCancelled && $0.searchIndexTokens.contains(query)
                }
                switch filter.sort {
                case .default: return selected
                case .name: return selected.sorted { $0.app.currentName.localizedStandardCompare($1.app.currentName) == .orderedAscending }
                case .date: return selected.sorted { ($0.app.currentDate?.date ?? .distantPast) > ($1.app.currentDate?.date ?? .distantPast) }
                }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            matches = result
            displayedFilter = filter
        }
    }
}
