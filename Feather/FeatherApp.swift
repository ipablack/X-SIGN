//
//  FeatherApp.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import CoreData
import Nuke
import IDeviceSwift
import OSLog
import WebKit
import Combine
import SystemConfiguration
import Network
import CryptoKit

// MARK: - نماذج إعدادات اللوحة (متوافقة مع Sendable في Xcode 26.3)
struct XSignRemoteRoot: Codable, Equatable, Sendable {
	let name: String?
    let subtitle: String?
    let iconURL: String?
    let categories: [XSignPanelCategory]?
	let tintColor: String?
	let repo_revision_id: Int?
	let xsign_config: XSignRemoteConfig?
}

struct XSignPanelCategory: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let isGame: Bool?
}

struct XSignRemoteConfig: Codable, Equatable, Sendable {
	let splash_screen: XSignSplashConfig?
	let theme: XSignThemeColors?
	let maintenance: XSignMaintenance?
	let force_update: XSignForceUpdate?
	let security_locks: XSignSecurityLocks?
	let app_control: XSignAppControl?
    let dashboard: XSignDashboardConfig?
}

struct XSignSplashConfig: Codable, Equatable, Hashable, Sendable {
	let engine: String?
	let animation_style: String?
	let show_sign_feather: Bool?
	let duration_seconds: Double?
	let custom_code: String?
    let size_px: Double?
    let stroke_width: Double?
    let glow_radius: Double?
    let subtitle: String?
}

struct XSignThemeColors: Codable, Equatable, Sendable {
	let app_tint_hex: String?
	let splash_bg_top_hex: String?
	let splash_bg_bottom_hex: String?
	let splash_logo_hex: String?
    let appearance: String?
}

struct XSignMaintenance: Codable, Equatable, Sendable {
	let enabled: Bool?
	let title: String?
	let message: String?
	let button_url: String?
}

struct XSignForceUpdate: Codable, Equatable, Sendable {
    let min_build_version: String?
	let enabled: Bool?
	let min_version: String?
	let update_url: String?
	let message: String?
}

struct XSignSecurityLocks: Codable, Equatable, Sendable {
	let allow_app_metadata_editing: Bool?
	let lock_bundle_rename: Bool?
	let lock_icon_change: Bool?
	let lock_dylib_injection: Bool?
	let anti_vpn_proxy: Bool?
	let require_online_handshake: Bool?
	let vpn_warning_message: String?

    var allowsAppMetadataEditing: Bool {
        XSignAppMetadata.editingAllowed(allow_app_metadata_editing)
    }
}

struct XSignCoreSourceItem: Codable, Equatable, Sendable {
	let name: String
	let id: String
	let url: String
}

struct XSignAppControl: Codable, Equatable, Sendable {
	let top_banner_enabled: Bool?
	let top_banner_text: String?
	let top_banner_url: String?
	let cache_flush_id: Int?
	let purge_sources_id: Int?
	let core_sources: [XSignCoreSourceItem]?
}

// MARK: - مدقق الحماية والأمان (بدون أي مؤقتات تسبب لاك أثناء البحث)
@MainActor
final class XSignSecurityEnforcer: ObservableObject {
	static let shared = XSignSecurityEnforcer()

	private let locksStorageKey = "xsign.persistedSecurityLocks_v4"
	private let pathMonitor = NWPathMonitor()
	private let monitorQueue = DispatchQueue(label: "com.ipablack.xsign.netguard", qos: .utility)

	@Published var locks: XSignSecurityLocks = XSignSecurityLocks(
        allow_app_metadata_editing: true,
		lock_bundle_rename: true,
		lock_icon_change: true,
		lock_dylib_injection: true,
		anti_vpn_proxy: true,
		require_online_handshake: true,
		vpn_warning_message: "عذراً، لا يمكن استخدام تطبيق X-Sign أو تحميل التطبيقات أثناء تشغيل VPN أو برامج مراقبة الشبكة (Proxy)."
	)
	@Published var isVPNOrProxyDetected: Bool = false
	@Published var didCompleteOnlineHandshake: Bool = false

	init() {
		if let data = UserDefaults.standard.data(forKey: locksStorageKey),
		   let saved = try? JSONDecoder().decode(XSignSecurityLocks.self, from: data) {
			self.locks = saved
		}
		evaluateNetworkSecurity()
		startEventDrivenNetworkMonitor()
	}

	func updateLocks(_ newLocks: XSignSecurityLocks?, verifiedOnline: Bool = false) {
		guard let newLocks = newLocks else { return }
		if self.locks != newLocks {
			self.locks = newLocks
		}
		self.didCompleteOnlineHandshake = verifiedOnline
		if let encoded = try? JSONEncoder().encode(newLocks) {
			UserDefaults.standard.set(encoded, forKey: locksStorageKey)
		}
		evaluateNetworkSecurity()
	}

	private func startEventDrivenNetworkMonitor() {
		pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
			let detected = Self.isVPNOrProxyActiveOnDevice()
			Task { @MainActor [weak self] in
				guard let self = self else { return }
				if !connected { self.didCompleteOnlineHandshake = false }
                let shouldBlock = false // A local installation tunnel must not lock the application.
				if self.isVPNOrProxyDetected != shouldBlock {
					self.isVPNOrProxyDetected = shouldBlock
                    NotificationCenter.default.post(name: .xsignPolicyChanged, object: nil)
				}
			}
		}
		pathMonitor.start(queue: monitorQueue)
	}

	func evaluateNetworkSecurity() {
		let antiVPNEnabled = false // Local installation requires a local tunnel.
		DispatchQueue.global(qos: .utility).async { [weak self] in
			let detected = antiVPNEnabled ? Self.isVPNOrProxyActiveOnDevice() : false
			DispatchQueue.main.async {
				guard let self = self else { return }
				if self.isVPNOrProxyDetected != detected {
					self.isVPNOrProxyDetected = detected
				}
			}
		}
	}

	nonisolated static func isVPNOrProxyActiveOnDevice() -> Bool {
		guard let cfSettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
			return false
		}
		guard let cfDict = cfSettings as NSDictionary as? [String: Any] else {
			return false
		}

		let proxyKeys = [
			"HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable",
			"HTTPProxy", "HTTPSProxy", "SOCKSProxy"
		]
		for key in proxyKeys {
			if let val = cfDict[key] as? Int, val == 1 { return true }
			if let str = cfDict[key] as? String, !str.isEmpty { return true }
		}

		if let scoped = cfDict["__SCOPED__"] as? [String: Any] {
			let vpnPrefixes = ["tap", "tun", "utun", "ppp", "ipsec", "wg", "pptp", "l2tp"]
			for iface in scoped.keys {
				let lower = iface.lowercased()
				if vpnPrefixes.contains(where: { lower.contains($0) }) {
					return true
				}
			}
		}
		return false
	}

	func validateSigningPermissions(
		originalName: String,
		newName: String,
		originalBundleID: String,
		newBundleID: String,
		didModifyIcon: Bool,
		injectedDylibCount: Int
	) -> (allowed: Bool, errorMessage: String?) {
		if !locks.allowsAppMetadataEditing && (originalName != newName || originalBundleID != newBundleID) {
			return (false, "غير مسموح بتعديل اسم التطبيق أو معرف الحزمة (Bundle ID).")
		}
		if (locks.lock_icon_change ?? true) && didModifyIcon {
			return (false, "غير مسموح بتغيير أو استبدال أيقونة التطبيق الأصلية.")
		}
		if (locks.lock_dylib_injection ?? true) && injectedDylibCount > 0 {
			return (false, "غير مسموح بحقن أدوات خارجية (.dylib / .deb) داخل التطبيق.")
		}
		return (true, nil)
	}
}

// MARK: - Remote panel transport
@MainActor
final class XSignRemoteManager: ObservableObject {
    static let shared = XSignRemoteManager()
    private let cacheKey = "xsign.cachedOwnerRemoteRoot_v1"
    @Published private(set) var config: XSignRemoteConfig?
    @Published private(set) var currentRevisionID = 0
    @Published private(set) var lastRemoteSync: Date?
    @Published private(set) var remoteSyncStatus = "بانتظار المزامنة"
    @Published private(set) var sourceName = "IPA BLACK"
    private var cachedRoot: XSignRemoteRoot?
    private var requestTask: Task<XSignRemoteRoot?, Never>?
    private var lastSuccess = Date.distantPast
    private var lastCatalogRefresh = Date.distantPast

    init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let root = try? JSONDecoder().decode(XSignRemoteRoot.self, from: data) {
            cachedRoot = root
            config = root.xsign_config
            XSignDashboardSources.apply(config?.dashboard)
            currentRevisionID = root.repo_revision_id ?? 0
            sourceName = root.name ?? sourceName
            remoteSyncStatus = "يُستخدم آخر تكوين محفوظ حتى اكتمال الاتصال"
            XSignSecurityEnforcer.shared.updateLocks(config?.security_locks, verifiedOnline: false)
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    var isMaintenanceActive: Bool { config?.maintenance?.enabled == true }
    var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    var isForceUpdateRequired: Bool {
        guard let update=config?.force_update,update.enabled == true else { return false }
        return XSignReleaseVersion.isNewer(currentVersion:currentVersion,currentBuild:currentBuild,
            targetVersion:update.min_version ?? currentVersion,targetBuild:update.min_build_version)
    }
    nonisolated static func versionIsOlder(_ current: String, than required: String) -> Bool {
        XSignVersion.older(current, than: required)
    }
    var blockingReason: String? {
        if isMaintenanceActive { return config?.maintenance?.message ?? "التطبيق قيد الصيانة." }
        if isForceUpdateRequired { return config?.force_update?.message ?? "يرجى تحديث التطبيق أولاً." }
        if config?.dashboard?.signing_enabled == false { return "التوقيع متوقف مؤقتاً بقرار إدارة XSign." }
        return nil
    }

    func prepareProtectedOperation() async -> String? {
        // Signing uses local credentials; panel connectivity is not authorization.
        // Keep cached owner maintenance/update policy, without a network round trip.
        return blockingReason
    }

    func fetchRemoteConfig(storeCache: AppStoreCacheManager? = nil, sourcesViewModel: SourcesViewModel? = nil) async {
        let root: XSignRemoteRoot?
        if let running = requestTask {
            root = await running.value
        } else if Date().timeIntervalSince(lastSuccess) < 5, XSignSecurityEnforcer.shared.didCompleteOnlineHandshake {
            root = cachedRoot
        } else {
            let cached = cachedRoot
            let task = Task.detached(priority: .utility) { await Self.downloadRoot(cached: cached) }
            requestTask = task
            root = await task.value
            if root != nil { lastSuccess = Date() }
            requestTask = nil
        }
        guard let root, let next = root.xsign_config else {
            XSignSecurityEnforcer.shared.didCompleteOnlineHandshake = false
            remoteSyncStatus = "تعذّر جلب التكوين؛ بقي آخر إعداد صالح"
            return
        }
        let changedRevision = root != cachedRoot
        let changedConfig = next != config
        cachedRoot = root
        if changedConfig { config = next }
        sourceName = root.name ?? sourceName
        currentRevisionID = root.repo_revision_id ?? currentRevisionID
        lastRemoteSync = lastSuccess == Date.distantPast ? nil : lastSuccess
        remoteSyncStatus = "تمت قراءة تكوين IPA BLACK بنجاح"
        if changedConfig || changedRevision,
           let data = try? JSONEncoder().encode(root) { UserDefaults.standard.set(data, forKey: cacheKey) }
        XSignSecurityEnforcer.shared.updateLocks(next.security_locks, verifiedOnline: true)
        let tint = next.theme?.app_tint_hex ?? root.tintColor
        if let tint, Self.validHex(tint),
           UserDefaults.standard.string(forKey: "xsign.lastAppliedRemoteTint") != tint.uppercased() {
            UserDefaults.standard.set(tint.uppercased(), forKey: "xsign.lastAppliedRemoteTint")
            UserDefaults.standard.set(tint, forKey: "Feather.userTintColor")
            UserDefaults.standard.set(false, forKey: "Feather.hasCustomTintColor")
        }
        if let appearance = next.theme?.appearance, ["system","light","dark"].contains(appearance),
           UserDefaults.standard.string(forKey:"xsign.lastRemoteAppearance") != appearance {
            UserDefaults.standard.set(appearance,forKey:"xsign.lastRemoteAppearance")
            UserDefaults.standard.set(appearance == "dark" ? 2 : appearance == "light" ? 1 : 0,forKey:"Feather.userInterfaceStyle")
        }
        let cache = storeCache ?? AppStoreCacheManager.shared
        let sourcesVM = sourcesViewModel ?? SourcesViewModel.shared
        let sourcePolicyChanged = XSignDashboardSources.apply(next.dashboard)
        if sourcePolicyChanged { cache.invalidateNetworkCache() }
        let commandChanged = cache.configureManagedSources(next.app_control?.core_sources) || sourcePolicyChanged
        var needsRefresh = changedRevision || commandChanged || !cache.hasLoadedCatalog || Date().timeIntervalSince(lastCatalogRefresh) >= 60
        if let flush = next.app_control?.cache_flush_id,
           flush > UserDefaults.standard.integer(forKey: "xsign.lastCacheFlushID") {
            cache.invalidateNetworkCache()
            ImagePipeline.shared.cache.removeAll()
            URLCache.shared.removeAllCachedResponses()
            UserDefaults.standard.set(flush, forKey: "xsign.lastCacheFlushID")
            needsRefresh = true
        }
        if let purge = next.app_control?.purge_sources_id,
           purge > UserDefaults.standard.integer(forKey: "xsign.lastPurgeSourcesID") {
            cache.invalidateNetworkCache()
            UserDefaults.standard.set(purge, forKey: "xsign.lastPurgeSourcesID")
            needsRefresh = true
        }
        NotificationCenter.default.post(name: .xsignPolicyChanged, object: nil)
        if needsRefresh {
            lastCatalogRefresh = Date()
            let sources = Storage.shared.getSources()
            Task { @MainActor in await cache.forceRefresh(sources: sources, viewModel: sourcesVM) }
        }
    }

    nonisolated static func validHex(_ value: String) -> Bool {
        value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }
    private nonisolated static func downloadRoot(cached: XSignRemoteRoot?) async -> XSignRemoteRoot? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let ownerURL = URL(string: ProtectedSourcesVault.defaultOwnedURLString) else { return nil }
        var endpoints: [(String, URL)] = [("owner-repo.json", ownerURL)]
        if ownerURL.absoluteString == ProtectedSourcesVault.defaultOwnedURLString,
           let alt = URL(string: ProtectedSourcesVault.defaultOwnedGitHubRawURLString) {
            endpoints.append(("owner-repo-github.json", alt))
        }
        for (filename, url) in endpoints {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let tagKey = "xsign.config.etag." + filename
            if cached != nil, let etag = UserDefaults.standard.string(forKey: tagKey) {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            guard let (data, http) = try? await XSignBoundedHTTP.fetch(request, using: session, limit: 16_777_216) else { continue }
            if http.statusCode == 304 { return cached }
            guard http.statusCode == 200, data.count <= 16_777_216,
                  let decoded = try? JSONDecoder().decode(XSignRemoteRoot.self, from: data),
                  decoded.xsign_config != nil else { continue }
            if let etag = http.value(forHTTPHeaderField: "ETag") { UserDefaults.standard.set(etag, forKey: tagKey) }
            return decoded
        }
        return nil
    }
}

extension Notification.Name {
    static let xsignPolicyChanged = Notification.Name("xsign.policyChanged")
}

func xsignSafeURL(_ text: String?) -> URL? {
    guard let text, let url = URL(string: text),
          ["https", "http", "tg"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return url
}

// MARK: - Isolated custom splash renderer
final class XSignSplashScriptCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var lastHTML: String?
    var onAnimationCompleted: (() -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "xsignSplash", message.frameInfo.isMainFrame,
              (message.body as? String) == "finished" else { return }
        onAnimationCompleted?()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }
}
struct XSignCustomCSSSplashWebView: UIViewRepresentable {
    let htmlCode: String
    var onFinishedFromJS: (() -> Void)? = nil
    func makeCoordinator() -> XSignSplashScriptCoordinator { XSignSplashScriptCoordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "xsignSplash")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onAnimationCompleted = onFinishedFromJS
        guard context.coordinator.lastHTML != htmlCode else { return }
        context.coordinator.lastHTML = htmlCode
        let document = "<!DOCTYPE html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:\"></head><body>\(htmlCode)</body></html>"
        view.loadHTMLString(document, baseURL: nil)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: XSignSplashScriptCoordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "xsignSplash")
        coordinator.onAnimationCompleted = nil
    }
}

@main
struct FeatherApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@Environment(\.scenePhase) private var scenePhase


	@StateObject var downloadManager = DownloadManager.shared
	@StateObject private var storeCache = AppStoreCacheManager.shared
    @StateObject private var autoSign = AutoSignPipelineManager.shared
	@StateObject private var sourcesViewModel = SourcesViewModel.shared
	@StateObject private var remoteManager = XSignRemoteManager.shared
	@StateObject private var securityEnforcer = XSignSecurityEnforcer.shared
	@StateObject private var storage = Storage.shared

	@AppStorage("Feather.userTintColor") private var userTintHex: String = "#005BBB"
    @AppStorage("Feather.userInterfaceStyle")
    private var userInterfaceStyle: Int = UIUserInterfaceStyle.unspecified.rawValue
	@State private var _showSplash = true

	private var activeTintColor: Color {
		Color(hex: userTintHex)
	}

    private var preferredAppColorScheme: ColorScheme? {
        switch UIUserInterfaceStyle(rawValue: userInterfaceStyle) ?? .unspecified {
        case .light: return .light
        case .dark: return .dark
        default: return nil
        }
    }

    private func applyAppearanceToWindows() {
        let style = UIUserInterfaceStyle(rawValue: userInterfaceStyle) ?? .unspecified
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
                window.tintColor = UIColor(activeTintColor)
            }
        }
    }

	var body: some Scene {
		WindowGroup {
            Group {
                if !storage.isStoreLoaded { XSignStorageLoadView(storage: storage) }
                else {
			ZStack {
				VStack(spacing: 0) {
					if remoteManager.config?.app_control?.top_banner_enabled == true,
					   let text = remoteManager.config?.app_control?.top_banner_text, !text.isEmpty {
						Button {
							if let uStr = remoteManager.config?.app_control?.top_banner_url,
							   let u = xsignSafeURL(uStr) {
								UIApplication.shared.open(u)
							}
						} label: {
							HStack(spacing: 8) {
								Image(systemName: "bell.badge.fill")
									.font(.caption.bold())
								Text(text)
									.font(.caption.bold())
									.lineLimit(1)
								Spacer()
								Image(systemName: "chevron.left")
									.font(.caption2)
							}
							.foregroundColor(AppStoreTheme.contrastingText(forHex: userTintHex))
							.padding(.horizontal, 14)
							.padding(.vertical, 9)
							.background(activeTintColor)
						}
					}

					DownloadHeaderView(downloadManager: downloadManager)
						.transition(.move(edge: .top).combined(with: .opacity))
					VariedTabbarView()
						.environment(\.managedObjectContext, storage.context)
						.onOpenURL(perform: _handleURL)
						.transition(.move(edge: .top).combined(with: .opacity))
				}
				.tint(activeTintColor)
				.accentColor(activeTintColor)
				.animation(.easeInOut(duration: 0.25), value: downloadManager.manualDownloads.description)


				if _showSplash {
					XSignPhotoIdenticalSplashView(
						cache: storeCache,
						sourcesViewModel: sourcesViewModel,
						remoteManager: remoteManager
					) {
						withAnimation(.easeInOut(duration: 0.45)) {
							_showSplash = false
						}
					}
					.transition(.opacity)
					.zIndex(999)
				}

				if !_showSplash && (remoteManager.isMaintenanceActive || remoteManager.isForceUpdateRequired) {
					XSignRemoteGateOverlayView(remoteManager: remoteManager, tintColor: activeTintColor)
						.transition(.opacity)
						.zIndex(1000)
				}

				if securityEnforcer.isVPNOrProxyDetected {
					XSignVPNBlockedOverlayView(
						message: securityEnforcer.locks.vpn_warning_message ?? "عذراً، لا يمكن استخدام التطبيق أو التحميل أثناء تشغيل VPN أو مراقب شبكة."
					) {
						securityEnforcer.evaluateNetworkSecurity()
					}
					.transition(.opacity)
					.zIndex(2000)
				}
			}
            .tint(activeTintColor)
            .accentColor(activeTintColor)
			.preferredColorScheme(preferredAppColorScheme)
            .sheet(isPresented: $autoSign.showCertificateSetup, onDismiss: {
                autoSign.resumeAfterCertificateSetup()
            }) { CertificatesAddView() }
            .sheet(item: $autoSign.readyToInstallApp, onDismiss: {
                autoSign.presentNextReadyApp()
            }) { signedApp in
                InstallPreviewView(app: signedApp.base)
                    .xsignCompactSheet(height: 300)

            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await remoteManager.fetchRemoteConfig(storeCache: storeCache, sourcesViewModel: sourcesViewModel)
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break }
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await storeCache.runAutomaticUpdates(sources: { storage.getSources() }, viewModel: sourcesViewModel)
            }
            .onReceive(NotificationCenter.default.publisher(for: .xsignPolicyChanged)) { _ in
                autoSign.applyRemotePolicy()
                if remoteManager.blockingReason != nil {
                    for download in downloadManager.downloads where download.task != nil { downloadManager.cancelDownload(download) }
                }
            }
            .onChange(of: userTintHex) { _ in
                applyAppearanceToWindows()
            }
            .onChange(of: userInterfaceStyle) { _ in
                applyAppearanceToWindows()
            }
			.onAppear {
				if UserDefaults.standard.string(forKey: "Feather.userTintColor") == nil {
					UserDefaults.standard.set("#005BBB", forKey: "Feather.userTintColor")
				}
                applyAppearanceToWindows()
			}
                }
            }
		}
	}

	private func _handleURL(_ url: URL) {
		XSignSecurityEnforcer.shared.evaluateNetworkSecurity()
		if XSignSecurityEnforcer.shared.isVPNOrProxyDetected {
			UIAlertController.showAlertWithOk(
				title: "تنبيه أمني",
				message: XSignSecurityEnforcer.shared.locks.vpn_warning_message ?? "يرجى إيقاف الـ VPN أو مراقب الشبكة أولاً."
			)
			return
		}

		if url.scheme == "xsign" {
            if url.host == "import-certificate" {
                UIAlertController.showAlertWithOk(title: "إعداد التوقيع", message:
                    "استورد P12 وMobileProvision من إعداد التوقيع داخل التطبيق. روابط استيراد الشهادات معطّلة لحماية المفاتيح وكلمات المرور.")
                return
            }
            if url.host == "export-certificate" { return }

			if let fullPath = url.validatedScheme(after: "/source/") {
				FR.handleSource(fullPath) { }
			}
			if
				let fullPath = url.validatedScheme(after: "/install/"),
				let downloadURL = URL(string: fullPath)
			{
				UIAlertController.showAlertWithCancel(
					title: .localized("Install"),
					message: .localized("Do you want to download and install this file?") + "\n\n\(downloadURL)",
					actions: [
						UIAlertAction(title: .localized("Install"), style: .default) { _ in
							guard !XSignSecurityEnforcer.shared.isVPNOrProxyDetected else { return }
							_ = DownloadManager.shared.startDownload(from: downloadURL)
						}
					]
				)
			}
		} else {
			if url.pathExtension == "ipa" || url.pathExtension == "tipa" {
                Task { @MainActor in
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let result: Result<String, Error> = await withCheckedContinuation { continuation in
                        FR.importPackageFile(url) { continuation.resume(returning: $0) }
                    }
                    if case .failure(let error) = result {
                        UIAlertController.showAlertWithOk(title: "تعذّر استيراد IPA", message: error.localizedDescription)
                    }
                }
				return
			}
		}
	}
}

// MARK: - شاشة الحظر عند اكتشاف VPN أو مراقب شبكة
struct XSignVPNBlockedOverlayView: View {
	let message: String
	var onRetry: () -> Void

	var body: some View {
		ZStack {
			AppStoreTheme.background.ignoresSafeArea()

			VStack(spacing: 18) {
				Image(systemName: "network.badge.shield.half.filled")
					.font(.system(size: 58))
					.foregroundColor(.red)

				Text("تم إيقاف الاتصال لحماية التطبيق")
					.font(.title3.bold())
					.foregroundColor(.primary)

				Text(message)
					.font(.subheadline)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 28)

				Button(action: onRetry) {
					Text("إعادة الفحص بعد إيقاف الـ VPN")
						.font(.headline.bold())
						.foregroundColor(.white)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 14)
						.background(Color.red)
						.cornerRadius(14)
				}
				.padding(.horizontal, 40)
				.padding(.top, 8)
			}
			.padding(24)
		}
	}
}

// MARK: - شاشة الصيانة والتحديث الإجباري
struct XSignRemoteGateOverlayView: View {
	@ObservedObject var remoteManager: XSignRemoteManager
	let tintColor: Color
    @State private var showInternalUpdate=false
    @AppStorage("Feather.userTintColor") private var userTintHex: String = "#005BBB"

	var body: some View {
        ZStack {
            if !remoteManager.isMaintenanceActive,remoteManager.config?.dashboard?.update?.enabled == true {
                XSignAppUpdateView()
            } else {
			AppStoreTheme.background.ignoresSafeArea()

			VStack(spacing: 20) {
				Image(systemName: remoteManager.isMaintenanceActive ? "wrench.and.screwdriver.fill" : "arrow.down.circle.fill")
					.font(.system(size: 56))
					.foregroundColor(tintColor)

				Text(remoteManager.isMaintenanceActive
					 ? (remoteManager.config?.maintenance?.title ?? "التطبيق قيد الصيانة")
					 : "تحديث إجباري مطلوب")
					.font(.title2.bold())
					.foregroundColor(.primary)
					.multilineTextAlignment(.center)

				Text(remoteManager.isMaintenanceActive
					 ? (remoteManager.config?.maintenance?.message ?? "يرجى المحاولة لاحقاً.")
					 : (remoteManager.config?.force_update?.message ?? "يرجى تحديث التطبيق لأحدث إصدار."))
					.font(.subheadline)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 24)

				Button {
                    if !remoteManager.isMaintenanceActive, remoteManager.config?.dashboard?.update?.enabled == true {
                        showInternalUpdate=true
                        return
                    }
					let target = remoteManager.isMaintenanceActive
						? (remoteManager.config?.maintenance?.button_url ?? "")
						: (remoteManager.config?.force_update?.update_url ?? "")
					if let url = URL(string: target) {
						UIApplication.shared.open(url)
					}
				} label: {
					Text(remoteManager.isMaintenanceActive ? "متابعة قناة التيليجرام" : "تحديث التطبيق الآن")
						.font(.headline.bold())
						.foregroundColor(AppStoreTheme.contrastingText(forHex: userTintHex))
						.frame(maxWidth: .infinity)
						.padding(.vertical, 14)
						.background(tintColor)
						.cornerRadius(14)
				}
				.padding(.horizontal, 36)
			}
			.padding(24)
		}
        }
        .sheet(isPresented:$showInternalUpdate) { XSignAppUpdateView() }
	}
}

// MARK: - المسارات الهندسية المطابقة 100% لصورة X Sign
struct ExactImageXLeftRibbon: Shape {
	func path(in rect: CGRect) -> Path {
		let w = rect.width, h = rect.height
		func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }

		var path = Path()
		path.move(to: pt(0.3157, 0.1961))
		path.addLine(to: pt(0.4431, 0.1961))
		path.addLine(to: pt(0.4863, 0.2725))
		path.addLine(to: pt(0.6373, 0.0569))
		path.addLine(to: pt(0.4863, 0.3176))
		path.addLine(to: pt(0.4275, 0.2196))
		path.addLine(to: pt(0.3529, 0.2196))
		path.addLine(to: pt(0.4373, 0.3824))
		path.addLine(to: pt(0.2549, 0.6941))
		path.addLine(to: pt(0.4157, 0.3824))
		path.closeSubpath()
		return path
	}
}

struct ExactImageXRightRibbon: Shape {
	func path(in rect: CGRect) -> Path {
		let w = rect.width, h = rect.height
		func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }

		var path = Path()
		path.move(to: pt(0.7451, 0.0569))
		path.addLine(to: pt(0.5765, 0.3961))
		path.addLine(to: pt(0.6745, 0.5745))
		path.addLine(to: pt(0.5353, 0.5745))
		path.addLine(to: pt(0.5000, 0.5020))
		path.addLine(to: pt(0.3588, 0.6980))
		path.addLine(to: pt(0.5020, 0.4549))
		path.addLine(to: pt(0.5529, 0.5471))
		path.addLine(to: pt(0.6353, 0.5471))
		path.addLine(to: pt(0.5471, 0.3961))
		path.closeSubpath()
		return path
	}
}

struct ExactImageSignFeatherWing: Shape {
	func path(in rect: CGRect) -> Path {
		let w = rect.width, h = rect.height
		func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }

		var path = Path()
		path.move(to: pt(0.604, 0.812))
		path.addCurve(to: pt(0.725, 0.760), control1: pt(0.625, 0.782), control2: pt(0.665, 0.785))
		path.addCurve(to: pt(0.668, 0.770), control1: pt(0.702, 0.770), control2: pt(0.686, 0.772))
		path.addCurve(to: pt(0.746, 0.672), control1: pt(0.708, 0.752), control2: pt(0.738, 0.725))
		path.addCurve(to: pt(0.646, 0.745), control1: pt(0.722, 0.715), control2: pt(0.688, 0.732))
		path.addCurve(to: pt(0.704, 0.692), control1: pt(0.672, 0.728), control2: pt(0.695, 0.712))
		path.addCurve(to: pt(0.622, 0.752), control1: pt(0.674, 0.718), control2: pt(0.642, 0.726))
		path.addCurve(to: pt(0.594, 0.816), control1: pt(0.612, 0.765), control2: pt(0.602, 0.795))
		path.closeSubpath()
		return path
	}
}

struct PhotoIdenticalXVectorView: View {
	let progress: CGFloat
	let fillAlpha: Double
	let glow: Double
	var logoColor: Color = .white
	var showSignAndFeather: Bool = true
	var leftOffset: CGSize = .zero
	var rightOffset: CGSize = .zero
    var strokeWidth: CGFloat = 2.8
    var glowRadius: CGFloat = 18

	var body: some View {
		ZStack {
			ZStack {
				ExactImageXLeftRibbon()
					.fill(logoColor.opacity(fillAlpha))
				ExactImageXLeftRibbon()
					.trim(from: 0, to: progress)
					.stroke(logoColor, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .miter, miterLimit: 18))
			}
			.offset(leftOffset)

			ZStack {
				ExactImageXRightRibbon()
					.fill(logoColor.opacity(fillAlpha))
				ExactImageXRightRibbon()
					.trim(from: 0, to: progress)
					.stroke(logoColor, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .miter, miterLimit: 18))
			}
			.offset(rightOffset)

			if showSignAndFeather {
				ZStack {
					Text("Sign")
						.font(.custom("Georgia-Italic", size: 52))
						.foregroundColor(logoColor)
						.position(x: 146, y: 262)

					ExactImageSignFeatherWing()
						.fill(logoColor)
				}
				.opacity(fillAlpha)
			}
		}
		.frame(width: 320, height: 320)
		.shadow(color: logoColor.opacity(0.65 * glow), radius: glowRadius, x: 0, y: 0)
	}
}

struct XSignPhotoIdenticalSplashView: View {
    @ObservedObject var cache: AppStoreCacheManager
    @ObservedObject var sourcesViewModel: SourcesViewModel
    @ObservedObject var remoteManager: XSignRemoteManager
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beganAt = Date()
    @State private var animated = false
    @State private var dismissed = false

    private var settings: XSignSplashConfig? { remoteManager.config?.splash_screen }
    private var duration: Double { min(7, max(1.5, settings?.duration_seconds ?? 3.2)) }
    private var style: String { settings?.animation_style ?? "laser_draw" }
    private var logoColor: Color { Color(hex: remoteManager.config?.theme?.splash_logo_hex ?? "#FFFFFF") }
    private var useCSS: Bool { settings?.engine == "custom_css" && !(settings?.custom_code ?? "").isEmpty }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: remoteManager.config?.theme?.splash_bg_top_hex ?? "#002B66"),
                                    Color(hex: remoteManager.config?.theme?.splash_bg_bottom_hex ?? "#00183B")],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            if useCSS, let code = settings?.custom_code {
                XSignCustomCSSSplashWebView(htmlCode: code).ignoresSafeArea()
            } else {
                VStack(spacing: 8) {
                    vector
                    if let subtitle = settings?.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption.bold()).tracking(3).foregroundStyle(logoColor.opacity(0.8))
                    }
                }
            }
        }
        .task(id: settings) {
            animated = false
            await Task.yield()
            withAnimation(animation) { animated = true }
            let remaining = max(0, duration - Date().timeIntervalSince(beganAt))
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
            guard !dismissed else { return }
            dismissed = true
            onFinished()
        }
    }

    private var animation: Animation {
        if reduceMotion { return .linear(duration: 0.15) }
        switch style {
        case "neon_pulse", "liquid_shine": return .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
        case "twin_slash": return .spring(response: 0.72, dampingFraction: 0.72)
        case "cyber_glitch": return .interpolatingSpring(stiffness: 170, damping: 10)
        default: return .easeInOut(duration: min(duration * 0.55, 1.6))
        }
    }
    private var vector: some View {
        let side = CGFloat(min(310, max(150, settings?.size_px ?? 225)))
        let moving = animated || reduceMotion
        let drawing = style == "laser_draw"
        let slashing = style == "twin_slash" && !moving
        let neon = style == "neon_pulse"
        let liquid = style == "liquid_shine"
        return PhotoIdenticalXVectorView(
            progress: drawing && !moving ? 0 : 1,
            fillAlpha: drawing && !moving ? 0 : 1,
            glow: moving ? 0.9 : 0.35,
            logoColor: logoColor,
            showSignAndFeather: settings?.show_sign_feather ?? true,
            leftOffset: slashing ? CGSize(width: -120, height: 120) : .zero,
            rightOffset: slashing ? CGSize(width: 120, height: -120) : .zero,
            strokeWidth: CGFloat(min(18, max(2, settings?.stroke_width ?? 8)) * 0.32),
            glowRadius: CGFloat(min(45, max(0, settings?.glow_radius ?? 18))))
            .overlay {
                if liquid {
                    LinearGradient(colors: [.clear, Color.white.opacity(moving ? 0.7 : 0.05), .clear],
                                   startPoint: moving ? .topLeading : .bottomTrailing,
                                   endPoint: moving ? .bottomTrailing : .topLeading)
                        .mask(ExactImageXLeftRibbon().fill().overlay(ExactImageXRightRibbon().fill()))
                }
            }
            .scaleEffect(side / 320 * (neon && moving ? 0.96 : moving ? 1 : 0.88))
            .rotationEffect(.degrees(style == "cyber_glitch" && !moving ? 12 : 0))
            .offset(y: liquid && moving ? -8 : 0)
            .frame(width: side, height: side)
            .opacity(moving ? 1 : drawing || slashing ? 1 : 0)
    }
}

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    private var storeReadySubscription: AnyCancellable?
    private var didPrepareStorage = false
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		_createLowMemoryPipeline()
		_createDocumentsDirectories()
		ResetView.clearWorkCache()
        storeReadySubscription = Storage.shared.$isStoreLoaded.filter { $0 }.first()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, !self.didPrepareStorage else { return }
                self.didPrepareStorage = true
                self._configureProtectedCoreSources()
                self._addDefaultCertificates()
            }
		return true
	}

	func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
		ImagePipeline.shared.cache.removeAll()
		URLCache.shared.removeAllCachedResponses()
	}

	private func _createLowMemoryPipeline() {
		DataLoader.sharedUrlCache.diskCapacity = 0
		DataLoader.sharedUrlCache.memoryCapacity = 0

		let pipeline = ImagePipeline {
			let dataLoader: DataLoader = {
				let config = URLSessionConfiguration.default
				config.urlCache = nil
				config.requestCachePolicy = .useProtocolCachePolicy
				config.httpMaximumConnectionsPerHost = 4
				return DataLoader(configuration: config)
			}()
			let dataCache = try? DataCache(name: "com.ipablack.xsign.datacache")
			let imageCache = Nuke.ImageCache()
			dataCache?.sizeLimit = 300 * 1024 * 1024
			imageCache.costLimit = 32 * 1024 * 1024
			imageCache.countLimit = 120
			$0.dataCache = dataCache
			$0.imageCache = imageCache
			$0.dataLoader = dataLoader
			$0.dataCachePolicy = .storeAll
			$0.isStoringPreviewsInMemoryCache = false
			$0.isDecompressionEnabled = true
		}

		ImagePipeline.shared = pipeline
	}

	private func _createDocumentsDirectories() {
		let fileManager = FileManager.default

		let directories: [URL] = [
			fileManager.archives,
			fileManager.certificates,
			fileManager.signed,
			fileManager.unsigned
		]

		for url in directories {
			try? fileManager.createDirectoryIfNeeded(at: url)
		}
	}

	private func _configureProtectedCoreSources() {
		let context = Storage.shared.context
		context.perform {
			let request = NSFetchRequest<AltSource>(entityName: "AltSource")
			let existingSources = (try? context.fetch(request)) ?? []

            for source in existingSources where ProtectedSourcesVault.isRetiredSource(source.sourceURL, identifier: source.identifier) {
                context.delete(source)
            }

            let coreRepos = AppStoreCacheManager.resolvedManagedSources(nil).map {
                (name: $0.name, id: $0.id, url: $0.url)
            }

			let updatedExisting = (try? context.fetch(request)) ?? []
			for repo in coreRepos {
				guard let repoURL = URL(string: repo.url) else { continue }
				let alreadyExists = updatedExisting.contains {
					$0.sourceURL.map { XSignCatalogIO.canonicalURL($0) == XSignCatalogIO.canonicalURL(repoURL) } == true ||
					$0.identifier == repo.id
				}
				if !alreadyExists {
					let newSource = AltSource(context: context)
					newSource.name = repo.name
					newSource.identifier = repo.id
					newSource.sourceURL = repoURL
					newSource.date = Date()
				}
			}

			try? context.save()
		}
	}

	private func _addDefaultCertificates() {
		guard let signingAssetsURL = Bundle.main.url(forResource: "signing-assets", withExtension: nil) else {
			return
		}

		do {
			let folderContents = try FileManager.default.contentsOfDirectory(
				at: signingAssetsURL,
				includingPropertiesForKeys: nil,
				options: .skipsHiddenFiles
			)

			for folderURL in folderContents {
				guard folderURL.hasDirectoryPath else { continue }

				let p12URL = folderURL.appendingPathComponent("cert.p12")
				let provisionURL = folderURL.appendingPathComponent("cert.mobileprovision")
				let passwordURL = folderURL.appendingPathComponent("cert.txt")

				guard
					FileManager.default.fileExists(atPath: p12URL.path),
					FileManager.default.fileExists(atPath: provisionURL.path),
					FileManager.default.fileExists(atPath: passwordURL.path)
				else {
					Logger.misc.warning("Skipping xsign cert: missing required files")
					continue
				}

				// حساب البصمة الرقمية للشهادة ليتعرف التطبيق على أي شهادة جديدة حتى لو كان اسمها دائماً xsign
				let p12Data = try Data(contentsOf: p12URL)
				let certFingerprint = SHA256.hash(data: p12Data).compactMap { String(format: "%02x", $0) }.joined()
				let importKey = "feather.didImportCert.\(certFingerprint)"

				guard UserDefaults.standard.bool(forKey: importKey) == false else { continue }

				let rawPassword = try String(contentsOf: passwordURL, encoding: .utf8)
				let password = rawPassword.trimmingCharacters(in: .whitespacesAndNewlines)

				FR.handleCertificateFiles(
					p12URL: p12URL,
					provisionURL: provisionURL,
					p12Password: password,
					certificateName: "xsign",
					isDefault: true
				) { error in
					if error == nil {
						UserDefaults.standard.set(true, forKey: importKey)
						UserDefaults.standard.set(true, forKey: "feather.didImportDefaultCertificates")
					}
				}
			}
		} catch {
			Logger.misc.error("Failed to list signing-assets: \(error)")
		}
	}
}

private struct XSignStorageLoadView: View {
    @ObservedObject var storage: Storage
    var body: some View {
        VStack(spacing: 16) {
            if storage.storeLoadError != nil {
                Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                Text("تعذّر فتح البيانات المحفوظة").font(.headline)
                Text("أعد المحاولة لفتح مكتبتك.").foregroundStyle(.secondary)
                Button("إعادة المحاولة") { storage.retryLoadingStore() }
            } else { ProgressView(); Text("جارٍ فتح مكتبتك…").foregroundStyle(.secondary) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.layoutDirection, .rightToLeft)
    }
}
