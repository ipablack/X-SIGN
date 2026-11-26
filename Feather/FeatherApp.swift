//
//  FeatherApp.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import CoreData
import AltSourceKit
import Nuke
import OSLog
import WebKit
import Combine
import CFNetwork
import Darwin
import Network
import CryptoKit
import Security
import UserNotifications

// MARK: - نماذج إعدادات اللوحة (متوافقة مع Sendable في Xcode 26.3)
struct XSignRemoteRoot: Codable, Equatable, Sendable {
	let name: String?
    let subtitle: String?
    let iconURL: String?
    let categories: [ASRepository.CatalogCategory]?
	let tintColor: String?
	let repo_revision_id: Int?
	let xsign_config: XSignRemoteConfig?
}

struct XSignRemoteConfig: Codable, Equatable, Sendable {
    let usage_stats: XSignUsageSettings?
    let push_endpoint: String?
	let splash_screen: XSignSplashConfig?
	let theme: XSignThemeColors?
	let maintenance: XSignMaintenance?
	let force_update: XSignForceUpdate?
	let security_locks: XSignSecurityLocks?
	let app_control: XSignAppControl?
    let dashboard: XSignDashboardConfig?
}

struct XSignUsageSettings: Codable, Hashable, Sendable {
    let enabled: Bool?
    let endpoint: String?

    var serviceURL: URL? {
        guard let url = XSignManagedSource.httpsURL(endpoint),
              url.query == nil, url.path.isEmpty || url.path == "/" else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = "https"
        parts?.path = ""
        if parts?.port == 443 { parts?.port = nil }
        parts?.host = url.host?.lowercased()
        return parts?.url
    }
}

@MainActor final class XSignUsagePulse {
    static let shared = XSignUsagePulse()
    private var lastAttempt = Date.distantPast
    private var lastEndpoint = ""
    private var sending = false

    func sendIfNeeded(_ settings: XSignUsageSettings?) async {
        guard !Task.isCancelled, settings?.enabled == true, let service = settings?.serviceURL,
              !sending, !XSignSecurityEnforcer.shared.hasInterceptingNetwork,
              service.absoluteString != lastEndpoint || Date().timeIntervalSince(lastAttempt) >= 60 else { return }
        lastAttempt = Date()
        lastEndpoint = service.absoluteString
        sending = true
        defer { sending = false }
        let scope = SHA256.hash(data: Data(service.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "XSign.usageInstallation." + scope
        let saved = UserDefaults.standard.string(forKey: key)
        let id: String
        if let saved, saved.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil {
            id = saved
        } else {
            id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            UserDefaults.standard.set(id, forKey: key)
        }
        var request = URLRequest(url: service.appendingPathComponent("v1/visit"), timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "installation_id": id, "bundle": Bundle.main.bundleIdentifier ?? ""
        ])
        let session = XSignBoundedHTTP.session()
        defer { session.invalidateAndCancel() }
        _ = try? await XSignBoundedHTTP.fetch(request, using: session, limit: 512)
    }
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

private func xsignNotice(
    _ legacy: String?, translations: [String: String]?, language: XSignLanguage
) -> String? {
    let candidates = [
        translations?[language.rawValue],
        legacy,
        translations?[XSignLanguage.arabic.rawValue],
        translations?[XSignLanguage.english.rawValue],
        translations?[XSignLanguage.kurdish.rawValue]
    ]
    return candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}

struct XSignMaintenance: Codable, Equatable, Sendable {
    let enabled: Bool?
    let title: String?
    let message: String?
    let button_url: String?
    let title_i18n: [String: String]?
    let message_i18n: [String: String]?

    var displayTitle: String {
        translated(title, translations: title_i18n, defaultKey: "التطبيق قيد الصيانة")
    }

    var displayMessage: String {
        translated(message, translations: message_i18n,
                   defaultKey: "نقوم حالياً بتحديث الخدمات، يرجى المحاولة لاحقاً.")
    }

    private func translated(_ legacy: String?, translations: [String: String]?, defaultKey: String) -> String {
        let language = XSignLanguage.current
        let text = xsignNotice(legacy, translations: translations, language: language)
        if let text, text != defaultKey { return text }
        return xsignText(defaultKey, language: language)
    }
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
    var blocksVPN: Bool { XSignNetworkPolicy.shouldBlock(enabled: anti_vpn_proxy, detected: true) }

    var allowsIconChanges: Bool { lock_icon_change != true }
    var allowsLibraryInjection: Bool { lock_dylib_injection == false }

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
	let top_banner_text_i18n: [String: String]?
	let top_banner_url: String?
	let cache_flush_id: Int?
	let purge_sources_id: Int?
	let core_sources: [XSignCoreSourceItem]?

    var bannerText: String? {
        xsignNotice(top_banner_text, translations: top_banner_text_i18n, language: .current)
    }
}

// MARK: - Network policy and active transfer cancellation
@MainActor
final class XSignSecurityEnforcer: ObservableObject {
	static let shared = XSignSecurityEnforcer()

	private let locksStorageKey = "xsign.persistedSecurityLocks_v4"
	private let pathMonitor = NWPathMonitor()
	private let monitorQueue = DispatchQueue(label: "com.ipablack.xsign.netguard", qos: .utility)
    private var protectedTransfers: [UUID: @MainActor (String) -> Void] = [:]
    private var securityChecks: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

	@Published var locks: XSignSecurityLocks = XSignSecurityLocks(
        allow_app_metadata_editing: true,
		lock_bundle_rename: false,
		lock_icon_change: false,
		lock_dylib_injection: true,
		anti_vpn_proxy: true,
		require_online_handshake: false,
		vpn_warning_message: "عذراً، لا يمكن استخدام تطبيق X-Sign أو تحميل التطبيقات أثناء تشغيل VPN أو برامج مراقبة الشبكة (Proxy)."
	)
	@Published var isVPNOrProxyDetected: Bool = false
    @Published private(set) var hasInterceptingNetwork = false
	@Published var didCompleteOnlineHandshake: Bool = false
    @Published private(set) var installationFailure: String?

    static let vpnFailure = "تعذّر التحقق من أمان الاتصال بسبب تشغيل VPN أو بروكسي. أوقفه ثم أعد المحاولة."
    static let backgroundFailure = "أوقف iOS وقت العمل في الخلفية. افتح XSign وأعد محاولة التثبيت."
    var packageNetworkFailure: String? { isVPNOrProxyDetected ? Self.vpnFailure : nil }

	init() {
		if let data = UserDefaults.standard.data(forKey: locksStorageKey),
		   let saved = try? JSONDecoder().decode(XSignSecurityLocks.self, from: data) {
			self.locks = saved
		}
		evaluateNetworkSecurity()
		startEventDrivenNetworkMonitor()
	}

    func startProtectedTransfer(onFailure: @escaping @MainActor (String) -> Void) -> UUID? {
        evaluateNetworkSecurity()
        if let reason = packageNetworkFailure {
            reportInstallationFailure(reason)
            onFailure(reason)
            return nil
        }
        let id = UUID()
        protectedTransfers[id] = onFailure
        synchronizeTransferMonitoring()
        return id
    }

    func finishProtectedTransfer(_ id: UUID?) {
        guard let id, protectedTransfers.removeValue(forKey: id) != nil else { return }
        synchronizeTransferMonitoring()
    }

    func dismissInstallationFailure() { installationFailure = nil }

    func reportInstallationFailure(_ message: String) {
        if installationFailure != message { installationFailure = message }
    }

    private func stopProtectedTransfers(_ reason: String) {
        guard !protectedTransfers.isEmpty else { return }
        let cancellations = Array(protectedTransfers.values)
        protectedTransfers.removeAll()
        reportInstallationFailure(reason)
        for cancel in cancellations { cancel(reason) }
        synchronizeTransferMonitoring()
    }

    private var blocksInterceptingNetworks: Bool {
        locks.blocksVPN
    }

    private func synchronizeTransferMonitoring() {
        if !protectedTransfers.isEmpty {
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "XSign protected transfer") { [weak self] in
                    guard let self else { return }
                    self.evaluateNetworkSecurity()
                    self.stopProtectedTransfers(Self.backgroundFailure)
                }
            }
            if securityChecks == nil {
                securityChecks = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                        self?.evaluateNetworkSecurity()
                    }
                }
            }
        } else {
            securityChecks?.cancel()
            securityChecks = nil
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }

    func applicationDidEnterBackground() {
        evaluateNetworkSecurity()
        if backgroundTask == .invalid {
            stopProtectedTransfers(Self.backgroundFailure)
        }
    }

    func updateLocks(_ newLocks: XSignSecurityLocks?, verifiedOnline: Bool = false) {
        didCompleteOnlineHandshake = verifiedOnline
        if let newLocks, locks != newLocks {
            locks = newLocks
            if let encoded = try? JSONEncoder().encode(newLocks) {
                UserDefaults.standard.set(encoded, forKey: locksStorageKey)
            }
        }
        evaluateNetworkSecurity()
        synchronizeTransferMonitoring()
    }

    private func startEventDrivenNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !connected { self.didCompleteOnlineHandshake = false }
                self.evaluateNetworkSecurity()
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    func evaluateNetworkSecurity() {
        let path = pathMonitor.currentPath
        let activeInterfaces = path.status == .satisfied
            ? Set(path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name))
            : []
        let detected = Self.isVPNOrProxyActiveOnDevice(activeInterfaces: activeInterfaces)
        let blocked = blocksInterceptingNetworks && detected
        let interceptionChanged = hasInterceptingNetwork != detected
        let overlayChanged = isVPNOrProxyDetected != blocked
        if interceptionChanged { hasInterceptingNetwork = detected }
        if overlayChanged { isVPNOrProxyDetected = blocked }
        if blocked { stopProtectedTransfers(Self.vpnFailure) }
        if interceptionChanged || overlayChanged {
            NotificationCenter.default.post(name: .xsignPolicyChanged, object: nil)
        }
    }

    private nonisolated static func isVPNOrProxyActiveOnDevice(activeInterfaces: Set<String>) -> Bool {
        var scopedProxies: [String: [String: Any]] = [:]
        if let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
           let settings = raw as NSDictionary as? [String: Any] {
            if XSignNetworkPolicy.hasEnabledProxy(in: settings) { return true }
            scopedProxies = settings["__SCOPED__"] as? [String: [String: Any]] ?? [:]
        }

        guard !activeInterfaces.isEmpty else { return false }
        if activeInterfaces.contains(where: { scopedProxies[$0].map(XSignNetworkPolicy.hasEnabledProxy) == true }) {
            return true
        }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return false }
        defer { freeifaddrs(first) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            let interface = entry.pointee
            pointer = interface.ifa_next
            guard interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  let address = interface.ifa_addr, let interfaceName = interface.ifa_name else { continue }
            let name = String(cString: interfaceName)
            guard address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            guard XSignNetworkPolicy.isActiveTunnelInterface(name, activeInterfaces: activeInterfaces) else { continue }
            switch address.pointee.sa_family {
            case UInt8(AF_INET):
                var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                if withUnsafeBytes(of: &ipv4, { XSignNetworkPolicy.hasUsableTunnelAddress(Array($0)) }) { return true }
            case UInt8(AF_INET6):
                var ipv6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                if withUnsafeBytes(of: &ipv6, { XSignNetworkPolicy.hasUsableTunnelAddress(Array($0)) }) { return true }
            default: break
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
		if !locks.allowsIconChanges && didModifyIcon {
			return (false, "غير مسموح بتغيير أو استبدال أيقونة التطبيق الأصلية.")
		}
		if !locks.allowsLibraryInjection && injectedDylibCount > 0 {
			return (false, "غير مسموح بحقن أدوات خارجية (.dylib / .deb) داخل التطبيق.")
		}
		return (true, nil)
	}
}

// MARK: - Remote panel transport
@MainActor
final class XSignRemoteManager: ObservableObject {
    static let shared = XSignRemoteManager()
    @Published private(set) var config: XSignRemoteConfig?
    @Published private(set) var currentRevisionID = 0
    @Published private(set) var lastRemoteSync: Date?
    @Published private(set) var remoteSyncStatus = "بانتظار المزامنة"
    @Published private(set) var sourceName = "IPA BLACK"
    private var cachedRoot: XSignRemoteRoot?
    private var requestTask: Task<Void, Never>?
    private var requestChecksBothFiles = false
    @Published private(set) var initialSyncSettled = false
    private var lastAttempt = Date.distantPast
    private var lastFullCatalogueProbe = Date.distantPast
    private var lastSuccess: Date?
    static let foregroundSyncInterval: UInt64 = 5_000_000_000
    static let synchronizedStatus = "تكوين IPA BLACK متزامن"

    init() {
        UserDefaults.standard.removeObject(forKey: "xsign.cachedOwnerRemoteRoot_v1")
        if UserDefaults.standard.object(forKey: "xsign.catalog.scope.v1") != nil {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: "xsign.catalog.access.v1"] as CFDictionary)
            UserDefaults.standard.removeObject(forKey: "xsign.catalog.scope.v1")
            UserDefaults.standard.removeObject(forKey: "xsign.catalog.origin.v1")
            XSignDashboardSources.resetManaged()
        }
        if let data = try? Data(contentsOf: Self.configurationFile),
           let root = try? JSONDecoder().decode(XSignRemoteRoot.self, from: data) {
            cachedRoot = root
            config = root.xsign_config
            XSignDashboardSources.apply(config?.dashboard, legacy: config?.app_control?.core_sources)
            currentRevisionID = root.repo_revision_id ?? 0
            sourceName = root.name ?? sourceName
            remoteSyncStatus = "يُستخدم آخر تكوين محفوظ حتى اكتمال الاتصال"
            XSignSecurityEnforcer.shared.updateLocks(config?.security_locks, verifiedOnline: false)
        }
    }

    var catalogueCategories: [ASRepository.CatalogCategory]? { cachedRoot?.categories }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    var isMaintenanceActive: Bool { config?.maintenance?.enabled == true }
    var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    var currentAppName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "XSign"
    }
    private var usesOriginalReleasePolicy: Bool {
        guard let bundle = Bundle.main.bundleIdentifier?.lowercased() else { return false }
        return bundle == XSignDashboardConfig.originalBundleIdentifier ||
            (bundle == XSignDashboardConfig.primaryBundleIdentifier && ownerRelease?.required == nil)
    }
    var ownerRelease: XSignOwnerUpdate? {
        config?.dashboard?.update(for: Bundle.main.bundleIdentifier)
    }
    var installedBundleIdentifier: String { Bundle.main.bundleIdentifier ?? "" }
    private var installedOrigin: String? { Bundle.main.object(forInfoDictionaryKey: "XSignReleaseOrigin") as? String }
    private var installedBuildRequest: String? { Bundle.main.object(forInfoDictionaryKey: "XSignStudioBuildRequest") as? String }

    private func isNewer(_ update: XSignOwnerUpdate) -> Bool {
        guard let version = update.latest_version else { return false }
        return XSignReleaseVersion.isNewer(currentVersion: currentVersion, currentBuild: currentBuild,
            targetVersion: version, targetBuild: update.targetBuild)
    }

    private var legacyGateIsActive: Bool {
        guard usesOriginalReleasePolicy, let update = config?.force_update, update.enabled == true,
              let minimum = update.min_version else { return false }
        return XSignReleaseVersion.isNewer(currentVersion: currentVersion, currentBuild: currentBuild,
            targetVersion: minimum, targetBuild: update.min_build_version.flatMap { $0.isEmpty ? nil : $0 })
    }

    var legacyUpdateURL: URL? {
        usesOriginalReleasePolicy ? XSignManagedSource.httpsURL(config?.force_update?.update_url) : nil
    }

    private var legacyInstallableRelease: XSignOwnerUpdate? {
        guard let release = ownerRelease, release.installable, isNewer(release),
              let version = release.latest_version, let minimum = config?.force_update?.min_version,
              let comparison = XSignReleaseVersion.compare(version, minimum), comparison >= 0 else { return nil }
        if comparison == 0, let minBuild = config?.force_update?.min_build_version, !minBuild.isEmpty {
            guard let targetBuild = release.targetBuild,
                  (XSignReleaseVersion.compare(targetBuild, minBuild) ?? -1) >= 0 else { return nil }
        }
        return release
    }

    var requiredRelease: XSignOwnerUpdate? {
        if let release = ownerRelease, let required = release.required {
            guard required, release.installable, release.needsUpdate(version: currentVersion, build: currentBuild,
                origin: installedOrigin, request: installedBuildRequest) else { return nil }
            return release
        }
        return legacyGateIsActive ? legacyInstallableRelease : nil
    }

    var isForceUpdateRequired: Bool {
        if ownerRelease?.required != nil { return requiredRelease != nil }
        return legacyGateIsActive
    }

    var optionalRelease: XSignOwnerUpdate? {
        guard !isMaintenanceActive, !isForceUpdateRequired,
              let release = ownerRelease, release.installable, release.required != true,
              release.needsUpdate(version: currentVersion, build: currentBuild,
                origin: installedOrigin, request: installedBuildRequest) else { return nil }
        return release
    }

    func canInstall(_ update: XSignOwnerUpdate) -> Bool {
        guard (!isMaintenanceActive || isForceUpdateRequired),
              update.installable, XSignSecurityEnforcer.shared.packageNetworkFailure == nil else { return false }
        let eligible = requiredRelease ?? optionalRelease
        return eligible?.installIdentity == update.installIdentity
    }
    nonisolated static func versionIsOlder(_ current: String, than required: String) -> Bool {
        XSignVersion.older(current, than: required)
    }
    var blockingReason: String? {
        let security = XSignSecurityEnforcer.shared
        if security.isVPNOrProxyDetected {
            return xsignText(security.locks.vpn_warning_message ?? "أوقف VPN أو البروكسي للمتابعة.")
        }
        if isMaintenanceActive { return config?.maintenance?.displayMessage ?? xsignText("التطبيق قيد الصيانة") }
        if isForceUpdateRequired { return xsignText(config?.force_update?.message ?? "يرجى تحديث التطبيق أولاً.") }
        if config?.dashboard?.signing_enabled == false { return xsignText("التوقيع متوقف مؤقتاً بقرار إدارة XSign.") }
        return nil
    }

    func prepareProtectedOperation() async -> String? {
        let security = XSignSecurityEnforcer.shared
        security.evaluateNetworkSecurity()
        if let reason = security.packageNetworkFailure { return reason }
        let handshakeRequired = security.locks.require_online_handshake == true
        if blockingReason != nil || (handshakeRequired && !security.didCompleteOnlineHandshake) {
            // Coalesce with foreground sync and throttle repeated attempts while offline.
            await fetchRemoteConfig()
            security.evaluateNetworkSecurity()
        }
        if let reason = security.packageNetworkFailure ?? blockingReason { return reason }
        if security.locks.require_online_handshake == true && !security.didCompleteOnlineHandshake {
            return "اتصل بالإنترنت لمزامنة إعدادات التطبيق أولاً."
        }
        return nil
    }

    func fetchRemoteConfig(storeCache: AppStoreCacheManager? = nil, sourcesViewModel: SourcesViewModel? = nil, force: Bool = false) async {
        while let running = requestTask {
            let checksBothFiles = requestChecksBothFiles
            await running.value
            if !force || checksBothFiles { return }
        }
        let now = Date()
        guard force || now.timeIntervalSince(lastAttempt) >= 4 else { return }
        lastAttempt = now
        let minimumRevision = currentRevisionID
        let probeFullCatalogue = force || now.timeIntervalSince(lastFullCatalogueProbe) >= 30
        if probeFullCatalogue { lastFullCatalogueProbe = now }
        requestChecksBothFiles = probeFullCatalogue
        let task = Task { @MainActor in
            let result = await Self.downloadRoot(minimumRevision: minimumRevision, probeFullCatalogue: probeFullCatalogue)
            applyRoot(result, storeCache: storeCache, sourcesViewModel: sourcesViewModel)
            initialSyncSettled = true
            requestTask = nil
        }
        requestTask = task
        await task.value
    }

    private func applyRoot(_ root: XSignRemoteRoot?, storeCache: AppStoreCacheManager?, sourcesViewModel: SourcesViewModel?) {
        guard let root, let next = root.xsign_config, (root.repo_revision_id ?? 0) >= currentRevisionID else {
            if XSignSecurityEnforcer.shared.didCompleteOnlineHandshake { XSignSecurityEnforcer.shared.didCompleteOnlineHandshake = false }
            let status = cachedRoot == nil ? "تعذّرت مزامنة إعدادات المتجر" : "تعذّر جلب التكوين؛ بقي آخر إعداد صالح"
            if remoteSyncStatus != status { remoteSyncStatus = status }
            return
        }
        lastSuccess = Date()
        let changedRevision = root != cachedRoot
        let changedConfig = next != config
        let previous = config
        cachedRoot = root
        if changedConfig { config = next }
        if let name = root.name, name != sourceName { sourceName = name }
        if let revision = root.repo_revision_id, revision != currentRevisionID { currentRevisionID = revision }
        if changedRevision || lastRemoteSync == nil || remoteSyncStatus != Self.synchronizedStatus { lastRemoteSync = lastSuccess }
        if remoteSyncStatus != Self.synchronizedStatus { remoteSyncStatus = Self.synchronizedStatus }
        if (changedConfig || changedRevision), let data = try? JSONEncoder().encode(root) {
            let file = Self.configurationFile
            try? XSignPrivateFiles.createDirectory(file.deletingLastPathComponent())
            try? data.write(to: file, options: .atomic)
            try? XSignPrivateFiles.protect(file)
        }
        if changedConfig || !XSignSecurityEnforcer.shared.didCompleteOnlineHandshake {
            XSignSecurityEnforcer.shared.updateLocks(next.security_locks, verifiedOnline: true)
        }
        let tint = next.theme?.app_tint_hex ?? root.tintColor
        if let tint, Self.validHex(tint), previous?.theme?.app_tint_hex != next.theme?.app_tint_hex ||
           UserDefaults.standard.string(forKey: "xsign.lastAppliedRemoteTint") != tint.uppercased() {
            UserDefaults.standard.set(tint.uppercased(), forKey: "xsign.lastAppliedRemoteTint")
            UserDefaults.standard.set(tint, forKey: "Feather.userTintColor")
            UserDefaults.standard.set(false, forKey: "Feather.hasCustomTintColor")
        }
        if let appearance = next.theme?.appearance, ["system","light","dark"].contains(appearance),
           previous?.theme?.appearance != appearance ||
           UserDefaults.standard.string(forKey:"xsign.lastRemoteAppearance") != appearance {
            UserDefaults.standard.set(appearance,forKey:"xsign.lastRemoteAppearance")
            UserDefaults.standard.set(appearance == "dark" ? 2 : appearance == "light" ? 1 : 0,forKey:"Feather.userInterfaceStyle")
        }
        let cache = storeCache ?? AppStoreCacheManager.shared
        let sourcesVM = sourcesViewModel ?? SourcesViewModel.shared
        cache.applyStudioCategories(root.categories)
        cache.applyTodaySources(next.dashboard?.today_source_ids)
        let sourcePolicyChanged = XSignDashboardSources.apply(next.dashboard, legacy: next.app_control?.core_sources)
        if sourcePolicyChanged { cache.invalidateNetworkCache() }
        let commandChanged = cache.configureManagedSources(next.app_control?.core_sources, resetAdapters: sourcePolicyChanged) || sourcePolicyChanged
        var needsRefresh = changedRevision || commandChanged
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
        if changedConfig { NotificationCenter.default.post(name: .xsignPolicyChanged, object: nil) }
        if needsRefresh, Storage.shared.isStoreLoaded, !isForceUpdateRequired, !isMaintenanceActive,
           !XSignSecurityEnforcer.shared.isVPNOrProxyDetected {
            let sources = Storage.shared.getSources()
            Task { @MainActor in await cache.forceRefresh(sources: sources, viewModel: sourcesVM) }
        }
    }

    nonisolated static func validHex(_ value: String) -> Bool {
        value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }
    private static var configurationFile: URL {
        let endpoint = XSignCatalogueEndpoint.ownerRequest(settings: true).url?.absoluteString ?? ""
        let key = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return XSignPrivateFiles.directory("CatalogueSettings").appendingPathComponent(key + ".json")
    }

    private nonisolated static func downloadRoot(minimumRevision: Int, probeFullCatalogue: Bool) async -> XSignRemoteRoot? {
        let session = XSignBoundedHTTP.session()
        defer { session.invalidateAndCancel() }
        if probeFullCatalogue {
            async let settings = downloadPolicy(settings: true, minimumRevision: minimumRevision, using: session)
            async let catalogue = downloadPolicy(settings: false, minimumRevision: minimumRevision, using: session)
            let (compact, full) = await (settings, catalogue)
            if let full, (full.repo_revision_id ?? 0) > (compact?.repo_revision_id ?? -1) { return full }
            return compact ?? full
        }
        if let compact = await downloadPolicy(settings: true, minimumRevision: minimumRevision, using: session) {
            return compact
        }
        return await downloadPolicy(settings: false, minimumRevision: minimumRevision, using: session)
    }

    private nonisolated static func downloadPolicy(settings: Bool, minimumRevision: Int, using session: URLSession) async -> XSignRemoteRoot? {
        var request = XSignCatalogueEndpoint.ownerRequest(settings: settings)
        let alternate = request.url.flatMap(XSignCatalogueEndpoint.alternatePublicRequest)
        if let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "xsign_sync", value: UUID().uuidString)]
            request.url = parts.url
        }
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        let limit = settings ? 524_288 : 16_777_216
        for candidate in [request] + [alternate].compactMap({ $0 }) {
            guard !Task.isCancelled else { return nil }
            guard let (data, response) = try? await XSignBoundedHTTP.fetch(candidate, using: session, limit: limit),
                  response.statusCode == 200, let root = try? JSONDecoder().decode(XSignRemoteRoot.self, from: data),
                  root.xsign_config != nil, (root.repo_revision_id ?? 0) >= minimumRevision else { continue }
            return root
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


    private var downloadManager: DownloadManager { .shared }
    private var storeCache: AppStoreCacheManager { .shared }
    private var autoSign: AutoSignPipelineManager { .shared }
    private var sourcesViewModel: SourcesViewModel { .shared }
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
                window.backgroundColor = AppStoreTheme.baseUIColor
            }
        }
    }

    @AppStorage("xsign.lastOptionalReleasePrompt") private var lastOptionalReleasePrompt = ""
    @State private var showOptionalUpdate = false
    @AppStorage(XSignLanguage.storageKey) private var languageCode = ""
    private var selectedLanguage: XSignLanguage? { XSignLanguage(rawValue: languageCode) }
    @State private var showCertificateSetup = false
    @State private var launchURL: URL?
    @State private var selectedTab: TabEnum = .today
    @State private var showImportedLibrary = false
    @State private var pushDestination: XSignPushDestination?
    @ObservedObject private var push = XSignPushNotifications.shared

    private var pushReady: Bool {
        scenePhase == .active && selectedLanguage != nil && storage.isStoreLoaded && !_showSplash
            && !gateIsVisible && !securityEnforcer.isVPNOrProxyDetected && !showOptionalUpdate && !showCertificateSetup
    }
    @ObservedObject private var importNotices = XSignImportNotices.shared

    private func presentOptionalUpdate() {
        guard scenePhase == .active, storage.isStoreLoaded, !_showSplash, selectedLanguage != nil,
              !gateIsVisible, !securityEnforcer.isVPNOrProxyDetected,
              !showCertificateSetup, let release = remoteManager.optionalRelease,
              let identity = release.promptIdentity, identity != lastOptionalReleasePrompt else { return }
        showOptionalUpdate = true
    }

    private var gateIsVisible: Bool { remoteManager.isMaintenanceActive || remoteManager.isForceUpdateRequired }

	var body: some Scene {
		WindowGroup {
            Group {
                if selectedLanguage == nil {
                    XSignLanguagePicker { language in
                        _showSplash = false
                        languageCode = language.rawValue
                        presentOptionalUpdate()
                    }
                } else if !storage.isStoreLoaded {
                    if securityEnforcer.isVPNOrProxyDetected {
                        XSignVPNBlockedOverlayView(message: securityEnforcer.locks.vpn_warning_message ??
                            "أوقف VPN أو البروكسي للمتابعة.") { securityEnforcer.evaluateNetworkSecurity() }
                    } else if gateIsVisible {
                    XSignRemoteGateOverlayView(remoteManager: remoteManager, tintColor: activeTintColor)
                            .tint(activeTintColor).accentColor(activeTintColor)
                    } else {
                        XSignStorageLoadView(storage: storage)
                    }
                } else {
			ZStack {
				if !gateIsVisible && !securityEnforcer.isVPNOrProxyDetected {
				VStack(spacing: 0) {
					if remoteManager.config?.app_control?.top_banner_enabled == true,
					   let text = remoteManager.config?.app_control?.bannerText {
						Button {
							if let uStr = remoteManager.config?.app_control?.top_banner_url,
							   let u = xsignSafeURL(uStr) {
								UIApplication.shared.open(u)
							}
						} label: {
							HStack(spacing: 8) {
								Image(systemName: "bell.badge.fill")
									.font(.caption.bold())
								Text(verbatim: text)
									.font(.caption.bold())
									.lineLimit(1)
								Spacer()
								Image(systemName: "chevron.forward")
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
					VariedTabbarView(selection: $selectedTab)
						.environment(\.managedObjectContext, storage.context)
					XSignInstallationStatus().padding(.horizontal, 16)
				}
				.tint(activeTintColor)
				.accentColor(activeTintColor)
				.sheet(isPresented: $showCertificateSetup, onDismiss: {
                    autoSign.showCertificateSetup = false
                    autoSign.resumeAfterCertificateSetup()
                    XSignInstallation.shared.resumeIfPossible()
                }) { CertificatesAddView() }

				}


				if _showSplash && !gateIsVisible && !securityEnforcer.isVPNOrProxyDetected {
					XSignPhotoIdenticalSplashView(
						remoteManager: remoteManager
					) {
						withAnimation(.easeInOut(duration: 0.45)) {
							_showSplash = false
						}
					}
					.transition(.opacity)
					.zIndex(999)
				}

				if gateIsVisible {
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
            .id(languageCode)
            .tint(activeTintColor)
            .accentColor(activeTintColor)
			.environment(\.managedObjectContext, storage.context)
            .task(id: scenePhase == .active && !gateIsVisible && !securityEnforcer.isVPNOrProxyDetected) {
                guard scenePhase == .active, !gateIsVisible, !securityEnforcer.isVPNOrProxyDetected else { return }
                await storeCache.runAutomaticUpdates(sources: { storage.getSources() }, viewModel: sourcesViewModel)
            }
            .sheet(isPresented: $showOptionalUpdate) {
                XSignAppUpdateView()
                    .onAppear {
                        if let identity = remoteManager.optionalRelease?.promptIdentity {
                            lastOptionalReleasePrompt = identity
                        }
                    }
                    .onChange(of: remoteManager.optionalRelease?.promptIdentity) { identity in
                        if let identity { lastOptionalReleasePrompt = identity }
                    }
            }
            .onChange(of: remoteManager.optionalRelease?.promptIdentity) { _ in
                if remoteManager.optionalRelease == nil { showOptionalUpdate = false }
                presentOptionalUpdate()
            }
            .onChange(of: _showSplash) { _ in presentOptionalUpdate() }
            .onChange(of: storage.isStoreLoaded) { _ in presentOptionalUpdate() }
            .onChange(of: languageCode) { _ in presentOptionalUpdate() }
            .onReceive(autoSign.$showCertificateSetup.removeDuplicates()) { showCertificateSetup = $0 }
            .onChange(of: showCertificateSetup) { _ in presentOptionalUpdate() }
            .onChange(of: securityEnforcer.isVPNOrProxyDetected) { _ in presentOptionalUpdate() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                securityEnforcer.evaluateNetworkSecurity()
                XSignInstallation.shared.resumeIfPossible()
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
            .xsignPageBackground()
            .preferredColorScheme(preferredAppColorScheme)
            .tint(activeTintColor)
            .task(id: importNotices.openLibrary && scenePhase == .active && selectedLanguage != nil
                    && storage.isStoreLoaded && !_showSplash && !gateIsVisible && !securityEnforcer.isVPNOrProxyDetected) {
                guard importNotices.openLibrary, scenePhase == .active, selectedLanguage != nil,
                      storage.isStoreLoaded, !_showSplash, !gateIsVisible, !securityEnforcer.isVPNOrProxyDetected else { return }
                importNotices.openLibrary = false
                if TabEnum.visibleTabs(for: remoteManager.config?.dashboard).contains(.library) {
                    selectedTab = .library
                } else {
                    showImportedLibrary = true
                }
            }
            .sheet(isPresented: $showImportedLibrary) {
                LibraryView().environment(\.managedObjectContext, storage.context)
            }
            .task(id: pushReady ? remoteManager.config?.push_endpoint.map { $0 + "|" + languageCode } : nil) {
                guard pushReady, let language = selectedLanguage else { return }
                await push.activate(endpoint: remoteManager.config?.push_endpoint, language: language)
            }
            .task(id: pushReady ? push.pending : nil) {
                guard pushReady, let pending = push.pending else { return }
                push.pending = nil
                if case .link(let url) = pending {
                    UIApplication.shared.open(url)
                } else {
                    pushDestination = pending
                }
            }
            .sheet(item: $pushDestination) { destination in
                XSignNotificationDestinationView(destination: destination)
            }
            .onChange(of: languageCode) { _ in XSignImportNotices.registerCategory() }
            .onOpenURL { url in
                if selectedLanguage == nil || !storage.isStoreLoaded {
                    launchURL = url
                } else if !gateIsVisible {
                    _handleURL(url)
                }
            }
            .task(id: selectedLanguage != nil && storage.isStoreLoaded && !gateIsVisible) {
                guard selectedLanguage != nil, storage.isStoreLoaded, !gateIsVisible, let url = launchURL else { return }
                launchURL = nil
                _handleURL(url)
            }
            .task(id: scenePhase == .active && securityEnforcer.hasInterceptingNetwork) {
                guard scenePhase == .active else { return }
                while securityEnforcer.hasInterceptingNetwork && !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 650_000_000) } catch { return }
                    securityEnforcer.evaluateNetworkSecurity()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .xsignPolicyChanged)) { _ in
                autoSign.applyRemotePolicy()
                XSignInstallation.shared.applyPolicy()
                if remoteManager.blockingReason != nil { downloadManager.applyRemotePolicy() }
                if gateIsVisible || securityEnforcer.isVPNOrProxyDetected {
                    showOptionalUpdate = false
                    autoSign.showCertificateSetup = false
                }
            }
            .alert("تعذّر التثبيت", isPresented: Binding(
                get: { securityEnforcer.installationFailure != nil && scenePhase == .active },
                set: { if !$0 && scenePhase == .active { securityEnforcer.dismissInstallationFailure() } }
            )) {
                Button("حسناً", role: .cancel) { securityEnforcer.dismissInstallationFailure() }
            } message: {
                Text(xsignText(securityEnforcer.installationFailure ?? ""))
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                securityEnforcer.evaluateNetworkSecurity()
                await remoteManager.fetchRemoteConfig(storeCache: storeCache, sourcesViewModel: sourcesViewModel, force: true)
                presentOptionalUpdate()
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: XSignRemoteManager.foregroundSyncInterval) } catch { break }
                    securityEnforcer.evaluateNetworkSecurity()
                    await remoteManager.fetchRemoteConfig(storeCache: storeCache, sourcesViewModel: sourcesViewModel)
                    presentOptionalUpdate()
                }
            }
            .task(id: scenePhase == .active ? remoteManager.config?.usage_stats : nil) {
                guard scenePhase == .active, let settings = remoteManager.config?.usage_stats,
                      settings.enabled == true, settings.serviceURL != nil else { return }
                while !Task.isCancelled {
                    await XSignUsagePulse.shared.sendIfNeeded(settings)
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { break }
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background { securityEnforcer.applicationDidEnterBackground() }
            }
            .environment(\.locale, (selectedLanguage ?? .arabic).locale)
            .environment(\.layoutDirection, (selectedLanguage ?? .arabic).direction)
		}
	}

	private func _handleURL(_ url: URL) {
		XSignSecurityEnforcer.shared.evaluateNetworkSecurity()
		if XSignSecurityEnforcer.shared.isVPNOrProxyDetected {
			UIAlertController.showAlertWithOk(
				title: xsignText("تنبيه أمني"),
				message: xsignText(XSignSecurityEnforcer.shared.locks.vpn_warning_message ?? "يرجى إيقاف الـ VPN أو مراقب الشبكة أولاً.")
			)
			return
		}

		if url.scheme == "xsign" {
            if url.host == "import-certificate" {
                UIAlertController.showAlertWithOk(title: xsignText("إعداد التوقيع"), message: xsignText(
                    "استورد P12 وMobileProvision من إعداد التوقيع داخل التطبيق. روابط استيراد الشهادات معطّلة لحماية المفاتيح وكلمات المرور."))
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
					message: .localized("Do you want to download and install this file?"),
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
                    if case .success = result { XSignImportNotices.completed() }
                    if case .failure(let error) = result {
                        UIAlertController.showAlertWithOk(title: xsignText("تعذّر استيراد IPA"), message: error.localizedDescription)
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

				Text(xsignText(message))
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

                XSignLanguageMenu().xsignGlassButton()
			}
			.padding(24)
		}
	}
}

// MARK: - شاشة الصيانة والتحديث الإجباري
struct XSignRemoteGateOverlayView: View {
	@ObservedObject var remoteManager: XSignRemoteManager
	let tintColor: Color
	var body: some View {
        ZStack {
            if remoteManager.requiredRelease != nil {
                XSignAppUpdateView(isRequired: true)
            } else {
			AppStoreTheme.background.ignoresSafeArea()

			VStack(spacing: 20) {
				Image(systemName: remoteManager.isMaintenanceActive ? "wrench.and.screwdriver.fill" : "arrow.down.circle.fill")
					.font(.system(size: 56))
					.foregroundColor(tintColor)

				Text(verbatim: remoteManager.isMaintenanceActive
					 ? (remoteManager.config?.maintenance?.displayTitle ?? xsignText("التطبيق قيد الصيانة"))
					 : xsignText("تحديث إجباري مطلوب"))
					.font(.title2.bold())
					.foregroundColor(.primary)
					.multilineTextAlignment(.center)

				Text(verbatim: remoteManager.isMaintenanceActive
					 ? (remoteManager.config?.maintenance?.displayMessage ?? xsignText("يرجى المحاولة لاحقاً."))
					 : xsignText(remoteManager.config?.force_update?.message ?? "يرجى تحديث التطبيق لأحدث إصدار."))
					.font(.subheadline)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 24)

                let target = remoteManager.isMaintenanceActive ? xsignSafeURL(remoteManager.config?.maintenance?.button_url) : remoteManager.legacyUpdateURL
                if let url = target {
				Button { UIApplication.shared.open(url) } label: {
					Text(xsignText(remoteManager.isMaintenanceActive ? "متابعة قناة التيليجرام" : "تحديث التطبيق الآن"))
						.font(.headline.bold())
						.frame(maxWidth: .infinity)
				}
                .buttonStyle(XSignInstallButtonStyle())
				.padding(.horizontal, 36)
                }
                Button(xsignText(remoteManager.isMaintenanceActive ? "إعادة التحقق من الصيانة" : "التحقق من التحديث")) {
                    Task { await remoteManager.fetchRemoteConfig(force: true) }
                }
                .xsignGlassButton()
                if remoteManager.initialSyncSettled && remoteManager.remoteSyncStatus != XSignRemoteManager.synchronizedStatus {
                    Text(xsignText(remoteManager.remoteSyncStatus)).font(.footnote).foregroundStyle(.secondary)
                }
                XSignLanguageMenu().xsignGlassButton()
			}
			.padding(24)
		}
        }
        .background(AppStoreTheme.background.ignoresSafeArea())
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
    @ObservedObject var remoteManager: XSignRemoteManager
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animated = false
    @State private var dismissed = false

    private struct Presentation: Hashable {
        let settings: XSignSplashConfig?
        let ready: Bool
    }

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
        .task(id: Presentation(settings: settings, ready: settings != nil || remoteManager.initialSyncSettled)) {
            guard !dismissed else { return }
            animated = false
            await Task.yield()
            withAnimation(animation) { animated = true }
            let waitingForSettings = settings == nil && !remoteManager.initialSyncSettled ? 0.75 : 0
            do { try await Task.sleep(nanoseconds: UInt64((duration + waitingForSettings) * 1_000_000_000)) } catch { return }
            finish()
        }
    }

    private func finish() {
        guard !dismissed else { return }
        dismissed = true
        onFinished()
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
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var storeReadySubscription: AnyCancellable?
    private var didPrepareStorage = false
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
        UITableView.appearance().backgroundColor = AppStoreTheme.baseUIColor
        UNUserNotificationCenter.current().delegate = self
        XSignImportNotices.registerCategory()
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

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let category = notification.request.content.categoryIdentifier
        completionHandler([XSignImportNotices.category, XSignPushNotifications.category].contains(category)
                          ? [.banner, .list, .sound] : [])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        if content.categoryIdentifier == XSignImportNotices.category,
           response.actionIdentifier != UNNotificationDismissActionIdentifier {
            Task { @MainActor in XSignImportNotices.shared.openLibrary = true }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  content.categoryIdentifier == XSignPushNotifications.category,
                  let destination = XSignPushDestination(kind: content.userInfo["xsign_kind"] as? String,
                                                        value: content.userInfo["xsign_target"] as? String) {
            Task { @MainActor in XSignPushNotifications.shared.pending = destination }
        }
        completionHandler()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        XSignPushNotifications.shared.receivedToken(deviceToken)
    }

	func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
		ImagePipeline.shared.cache.removeAll()
		URLCache.shared.removeAllCachedResponses()
	}

    func applicationDidEnterBackground(_ application: UIApplication) {
        XSignSecurityEnforcer.shared.applicationDidEnterBackground()
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
				let loader = DataLoader(configuration: config)
				loader.delegate = XSignCatalogRedirects()
				return loader
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
                } else if let existing = updatedExisting.first(where: { $0.identifier == repo.id }) {
                    existing.sourceURL = repoURL
                    existing.name = repo.name
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

    }
}
