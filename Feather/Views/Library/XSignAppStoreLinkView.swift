import SwiftUI
import Foundation

struct XSignAppleApp: Decodable, Sendable {
    let trackId: Int64
    let trackName: String
    let bundleId: String
    let artworkUrl512: URL?
}

actor XSignAppleAppLookup {
    static let shared = XSignAppleAppLookup()
    private var cache: [String: XSignAppleApp] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        session = URLSession(configuration: config)
    }

    func lookup(_ reference: XSignAppStoreReference) async throws -> XSignAppleApp {
        let key = reference.id + ":" + (reference.country ?? "us")
        if let app = cache[key] { return app }
        struct Response: Decodable { let results: [XSignAppleApp] }
        var tried = Set<String>()
        for country in [reference.country, "us", "sa"].compactMap({ $0 }) where tried.insert(country).inserted {
            try Task.checkCancellation()
            var parts = URLComponents(string: "https://itunes.apple.com/lookup")!
            parts.queryItems = [URLQueryItem(name: "id", value: reference.id), URLQueryItem(name: "country", value: country), URLQueryItem(name: "entity", value: "software")]
            guard let url = parts.url else { continue }
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 2_097_152 else {
                throw URLError(.badServerResponse)
            }
            let value = try JSONDecoder().decode(Response.self, from: data)
            if let app = value.results.first(where: { String($0.trackId) == reference.id && !$0.bundleId.isEmpty }) {
                if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
                cache[key] = app
                return app
            }
        }
        throw NSError(domain: "XSign.AppStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "التطبيق غير متاح في بلد الرابط أو المتاجر التي تم فحصها."])
    }
}

@MainActor
final class XSignAppStoreLinkModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isRequestingIPA = false
    @Published private(set) var app: XSignAppleApp?
    @Published private(set) var message: String?
    @Published private(set) var reference: XSignAppStoreReference?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var requestedAppID: Int64?

    func resolve(_ text: String) {
        cancel()
        app = nil; message = nil; requestedAppID = nil
        guard let reference = XSignAppStoreReference.parse(text) else {
            self.reference = nil
            message = "ألصق رابطًا صحيحًا من apps.apple.com يحتوي على رقم التطبيق."
            return
        }
        self.reference = reference
        let current = generation
        isLoading = true
        task = Task { @MainActor [weak self] in
            do {
                let resolved = try await XSignAppleAppLookup.shared.lookup(reference)
                guard let self, !Task.isCancelled, current == self.generation else { return }
                self.app = resolved
                self.isLoading = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == current else { return }
                self.message = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func requestIPA() {
        guard let app, !isLoading, !isRequestingIPA, requestedAppID != app.trackId else { return }
        let current = generation
        isRequestingIPA = true; message = nil
        task = Task { @MainActor [weak self] in
            do {
                if let reason = await XSignRemoteManager.shared.prepareProtectedOperation() {
                    throw NSError(domain: "XSign.Policy", code: 403, userInfo: [NSLocalizedDescriptionKey: reason])
                }
                let url = try await XSignIPAProvider.shared.resolve(bundleID: app.bundleId, name: app.trackName, appStoreID: String(app.trackId))
                guard let self, !Task.isCancelled, current == self.generation else { return }
                _ = DownloadManager.shared.startDownload(from: url, id: "FeatherManualDownload_" + UUID().uuidString, requireUnencryptedBinary: true)
                self.requestedAppID = app.trackId
                self.message = "بدأ التنزيل. بعد فحص الملف واستيراده سيظهر في قسم التوقيع؛ يمكنك تعديل الاسم والبندل والإصدار قبل توقيعه."
                self.isRequestingIPA = false
            } catch {
                guard let self, !Task.isCancelled, current == self.generation else { return }
                self.message = error.localizedDescription
                self.isRequestingIPA = false
            }
        }
    }

    func cancel() { generation &+= 1; task?.cancel(); task = nil; isLoading = false; isRequestingIPA = false }
}

struct XSignAppStoreLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = XSignAppStoreLinkModel()
    @State private var link = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://apps.apple.com/app/id…", text: $link)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                        .submitLabel(.search).onSubmit { model.resolve(link) }
                    Button { model.resolve(link) } label: {
                        HStack { Text("عرض معلومات التطبيق"); Spacer(); if model.isLoading { ProgressView() } }
                    }.disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoading)
                } header: { Text("رابط App Store") } footer: {
                    Text("معلومات التطبيق من Apple. طلب ملف IPA مستقل عن مصادر المتجر، ويُرسل إلى مزود خارجي عند ضغط زر الطلب.")
                }
                if let app = model.app {
                    Section {
                        HStack(spacing: 12) {
                            AppStoreIconView(url: app.artworkUrl512, size: 54)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.trackName).font(.headline)
                                Text(app.bundleId).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button { model.requestIPA() } label: {
                            HStack {
                                Label("طلب IPA واستيراده", systemImage: "arrow.down.app")
                                Spacer()
                                if model.isRequestingIPA { ProgressView() }
                            }
                        }.disabled(model.isRequestingIPA || model.isLoading)
                    } header: { Text("التطبيق المرتبط بالرابط") } footer: {
                        Text("المزود: \(XSignIPAProvider.providerName). توفر الملف وصلاحية التنزيل يعتمدان على المزود. يتحقق XSign من تشفير التنفيذ بعد الاستيراد؛ السيرفر الداخلي يخدم ملفات التثبيت، والتوقيع يجري محليًا بواسطة Zsign.")
                    }
                }
                if let message = model.message { Section { Text(message).font(.subheadline) } }
                if let reference = model.reference {
                    Section { Link(destination: reference.url) { Label("فتح في App Store", systemImage: "arrow.up.right.square") } }
                }
            }
            .navigationTitle("رابط App Store").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .onDisappear { model.cancel() }
    }
}
