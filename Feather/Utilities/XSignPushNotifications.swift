import SwiftUI
import UIKit
import UserNotifications

enum XSignPushDestination: Hashable, Identifiable, Sendable {
    case app(String)
    case tweak(String)
    case link(URL)

    var id: Self { self }

    nonisolated init?(kind: String?, value: String?) {
        guard let value, !value.isEmpty else { return nil }
        switch kind {
        case "app":
            guard value.utf8.count <= 220, value.range(of: "[[:cntrl:]]", options: .regularExpression) == nil else { return nil }
            self = .app(value)
        case "tweak":
            guard value.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { return nil }
            self = .tweak(value)
        case "link":
            guard value.utf8.count <= 1000, let url = URL(string: value),
                  url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
                  url.user == nil, url.password == nil else { return nil }
            self = .link(url)
        default: return nil
        }
    }
}

@MainActor
final class XSignPushNotifications: ObservableObject {
    static let shared = XSignPushNotifications()
    nonisolated static let category = "XSIGN_STUDIO_NOTICE"
    @Published var pending: XSignPushDestination?
    private var deviceToken: String?
    private var registerTask: Task<Void, Never>?
    private var submitted: Registration?
    private var submittedAt = Date.distantPast

    private struct Registration: Equatable {
        let url: URL
        let language: String
        let token: String
    }

    func activate(endpoint: String?, language: XSignLanguage) async {
        guard Self.service(endpoint) != nil else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            guard (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) == true else { return }
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        guard !Task.isCancelled else { return }
        UIApplication.shared.registerForRemoteNotifications()
        register(endpoint: endpoint, language: language)
    }

    func receivedToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        register(endpoint: XSignRemoteManager.shared.config?.push_endpoint, language: .current)
    }

    private static func service(_ endpoint: String?) -> URL? {
        guard let url = XSignManagedSource.httpsURL(endpoint), url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }

    private func register(endpoint: String?, language: XSignLanguage) {
        guard let base = Self.service(endpoint), let token = deviceToken else { return }
        let registration = Registration(url: base.appendingPathComponent("register"), language: language.rawValue, token: token)
        guard submitted != registration || Date().timeIntervalSince(submittedAt) >= 86400 else { return }
        registerTask?.cancel()
        submitted = registration
        submittedAt = Date()
        registerTask = Task {
            var request = URLRequest(url: registration.url, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "token": registration.token, "language": registration.language,
                "bundle": Bundle.main.bundleIdentifier ?? ""
            ])
            let session = XSignBoundedHTTP.session()
            defer { session.invalidateAndCancel() }
            let response = try? await XSignBoundedHTTP.fetch(request, using: session, limit: 1024)
            if !Task.isCancelled, response?.1.statusCode != 204, submitted == registration {
                submitted = nil
            }
        }
    }
}

struct XSignNotificationDestinationView: View {
    let destination: XSignPushDestination
    @ObservedObject private var cache = AppStoreCacheManager.shared
    @ObservedObject private var remote = XSignRemoteManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true

    var body: some View {
        XSignNavigationView {
            Group {
                switch destination {
                case .app(let id):
                    if let item = matchingApp(id) {
                        XSignAppStoreProductPage(item: item)
                    } else {
                        unavailable
                    }
                case .tweak(let id):
                    if let tweak = remote.config?.dashboard?.signing_libraries?.first(where: { $0.id == id && $0.enabled }) {
                        List {
                            Label(tweak.name, systemImage: "puzzlepiece.extension")
                            Text(xsignText("اختر هذا التعديل من قائمة الدايلبات الجاهزة أثناء التوقيع."))
                            ForEach(tweak.bundles, id: \.self) { Text(verbatim: $0) }
                        }
                        .xsignListBackground()
                        .navigationTitle(tweak.name)
                    } else {
                        unavailable
                    }
                case .link: EmptyView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(xsignText("تم")) { dismiss() }
                }
            }
        }
        .task {
            if case .app = destination {
                await cache.waitForInitialCatalog()
                if case .app(let id) = destination, matchingApp(id) == nil {
                    await cache.forceRefresh(sources: Storage.shared.getSources(), viewModel: .shared)
                }
            } else {
                await remote.fetchRemoteConfig(force: true)
            }
            loading = false
        }
    }

    private func matchingApp(_ id: String) -> AppStoreAppItem? {
        let items = cache.allCombinedItems
        return items.first(where: { $0.sourceCatalogIDs.contains(id) })
            ?? items.first(where: { $0.app.id?.caseInsensitiveCompare(id) == .orderedSame })
    }

    @ViewBuilder private var unavailable: some View {
        if loading { ProgressView() }
        else { Text(xsignText("المحتوى المشار إليه غير متاح حالياً.")).padding() }
    }
}
