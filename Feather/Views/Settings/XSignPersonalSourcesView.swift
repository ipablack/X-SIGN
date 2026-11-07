import SwiftUI
import CoreData

struct XSignPersonalSourcesView: View {
    @ObservedObject private var model = SourcesViewModel.shared
    @ObservedObject private var remote = XSignRemoteManager.shared
    @State private var adding = false
    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)])
    private var sources: FetchedResults<AltSource>
    private var personalSources: [AltSource] {
        sources.filter { source in
            guard !source.isDeleted, let url = source.sourceURL else { return false }
            return XSignDashboardSources.isUserSource(url) && !ProtectedSourcesVault.isRetiredSource(url)
        }
    }
    var body: some View {
        List {
            Section {
                Button { adding = true } label: { Label("إضافة مصدر", systemImage: "plus.circle.fill") }
                    .disabled(remote.config?.dashboard?.userSourcesEnabled == false)
            } footer: {
                Text("تظهر تطبيقات المصدر وألعابه تلقائياً في المتجر والبحث بعد إضافته.")
            }
            Section("مصادرك") {
                if personalSources.isEmpty { Text("لم تضف مصادر بعد.").foregroundStyle(.secondary) }
                ForEach(personalSources, id: \.objectID) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            AppStoreIconView(url: source.iconURL, size: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name ?? "مصدر").font(.headline)
                                if let count = model.sources[source]?.apps.count {
                                    Text("\(count) تطبيق").font(.caption).foregroundStyle(.secondary)
                                } else { Text("جارٍ التحديث…").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if let error = model.errors[source] { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                    .swipeActions {
                        Button(role: .destructive) { Storage.shared.deleteSource(for: source) } label: { Label("حذف", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("المصادر")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { CustomSafeAddSourceSheet() }
        .refreshable { await AppStoreCacheManager.shared.forceRefresh(sources: sources, viewModel: model) }
        .task(id: sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            await AppStoreCacheManager.shared.ensureFetched(sources: sources, viewModel: model)
        }
    }
}
