import SwiftUI
import WebKit
import ZIPFoundation
import CryptoKit

struct XSignVerifiedSelfUpdate: Sendable {
    fileprivate let appUUID: String
    fileprivate let bundleID: String
    fileprivate init(appUUID: String, bundleID: String) { self.appUUID=appUUID;self.bundleID=bundleID }
    @MainActor func permits(_ app: AppInfoPresentable) -> Bool {
        app.uuid == appUUID && app.identifier == bundleID && bundleID == Bundle.main.bundleIdentifier
    }
}

@MainActor final class XSignAppUpdater: ObservableObject {
    @Published var busy=false
    @Published var message=""
    @Published var needsCertificate=false
    @Published var delivered=false
    @Published var progress: Double?
    private var pendingUpdate: XSignOwnerUpdate?
    private var knownCertificates=Set<String>()
    private var operation: Task<Void,Never>?
    private var interruption: String?
    private let maximumSize: Int64=2_147_483_648
    func cancel() { operation?.cancel() }
    func releaseChanged() {
        cancel(); pendingUpdate = nil; needsCertificate = false; delivered = false; progress = nil
        if !busy { message = "" }
    }
    func start(_ update: XSignOwnerUpdate) {
        guard !busy else { return }
        let security = XSignSecurityEnforcer.shared
        guard let transfer = security.startProtectedTransfer(onFailure: { [weak self] reason in
            self?.interruption = reason
            self?.operation?.cancel()
        }) else {
            message = security.packageNetworkFailure ?? "تعذّر بدء طلب التثبيت. أعد المحاولة."
            return
        }
        interruption = nil
        delivered = false
        busy=true;progress=nil;message="التحقق من التحديث…"
        operation=Task {
            defer {
                security.finishProtectedTransfer(transfer)
                busy = false
                operation = nil
            }
            do {
                let remote = XSignRemoteManager.shared
                await remote.fetchRemoteConfig(force: true)
                try Task.checkCancellation()
                guard remote.remoteSyncStatus == XSignRemoteManager.synchronizedStatus else {
                    throw failure("تعذّر التحقق من التحديث المنشور. تحقق من اتصالك وأعد المحاولة.")
                }
                try checkRelease(update)
                guard let latest=update.latest_version, let origin=update.releaseOrigin,
                      let bundleID=Bundle.main.bundleIdentifier, update.targets(bundleID) else {
                    throw failure("لا يوجد تحديث صالح لهذا البندل في إعدادات الناشر.")
                }
                if let manifest=update.manifestURL {
                    let session=XSignBoundedHTTP.session();defer { session.invalidateAndCancel() }
                    let (data,response)=try await XSignBoundedHTTP.fetch(URLRequest(url:manifest),using:session,limit:32768)
                    guard response.statusCode == 200,
                          let root=try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
                          let items=root["items"] as? [[String:Any]],items.count == 1,
                          let metadata=items[0]["metadata"] as? [String:Any],metadata["bundle-identifier"] as? String == bundleID,
                          let build = metadata["bundle-version"] as? String,
                          XSignReleaseVersion.compare(build, update.targetBuild ?? latest) == 0,
                          metadata["kind"] as? String == "software",
                          let assets=items[0]["assets"] as? [[String:Any]] else {
                        throw failure("ملف تحديث الناشر لا يطابق هوية XSign ورقم البناء المطلوب.")
                    }
                    let packages = assets.filter { $0["kind"] as? String == "software-package" }
                    guard packages.count == 1, XSignManagedSource.httpsURL(packages[0]["url"] as? String) != nil else {
                        throw failure("ملف وصف التحديث يجب أن يشير إلى حزمة واحدة عبر HTTPS.")
                    }
                    try checkRelease(update)
                    let url = try XSignManifestBridge.installationLink(for: manifest)
                    guard await open(url), !Task.isCancelled else { throw failure("تعذّر فتح طلب تثبيت iOS.") }
                    delivered=true
                    message="وافق على طلب iOS، ثم افتح XSign بعد اكتمال التثبيت."
                    return
                }
                guard let url=update.verifiedURL,let expected=update.sha256 else { throw failure("التحديث غير متاح حالياً. حاول لاحقاً.") }
                guard let embedded = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
                      let installed = try? XSignSelfUpdateProfile.read(embedded) else {
                    throw failure("تعذّر قراءة ملف توقيع XSign المثبّت. حدّثه باستخدام طريقة تثبيته الأصلية.")
                }
                message = "التحقق من شهادة التحديث…"
                guard Storage.shared.isStoreLoaded else {
                    throw failure("جارٍ تحميل الشهادات لهذا الجهاز. أعد المحاولة بعد اكتمال التحميل.")
                }
                guard let selected = await XSignSelfUpdateCertificate.select(installed: installed, bundleID: bundleID) else {
                    try Task.checkCancellation()
                    knownCertificates = Set(Storage.shared.getAllCertificates().compactMap { $0.uuid })
                    pendingUpdate = update
                    needsCertificate = true
                    message = "هذه النسخة تحتاج إلى إعادة توقيع. أضف شهادة متوافقة مع XSign المثبّت."
                    return
                }
                try checkRelease(update)
                message="جاري تنزيل التحديث…"
                let directory=XSignPrivateFiles.workDirectory(prefix:"SelfUpdate")
                try XSignPrivateFiles.createDirectory(directory)
                defer { try? FileManager.default.removeItem(at:directory) }
                let file=try await XSignUpdateFileDownload.fetch(url,to:directory.appendingPathComponent("X-SIGN.ipa"),maximum:maximumSize,progress:{ [weak self] value in
                    Task { @MainActor in self?.progress=value }
                })
                try checkRelease(update)
                progress=nil
                message="التحقق من سلامة التحديث…"
                let hashTask=Task.detached(priority:.userInitiated) {
                    let stream=try FileHandle(forReadingFrom:file);defer { try? stream.close() }
                    var hasher=SHA256()
                    while let block=try stream.read(upToCount:1_048_576),!block.isEmpty { try Task.checkCancellation();hasher.update(data:block) }
                    return hasher.finalize().map { String(format:"%02x",$0) }.joined()
                }
                let hash=try await withTaskCancellationHandler(operation:{ try await hashTask.value },onCancel:{ hashTask.cancel() })
                try checkRelease(update)
                guard hash == expected.lowercased() else { throw failure("بصمة الملف لا تطابق الإصدار المنشور. أُوقف التحديث.") }

                let metadataTask = Task.detached(priority: .userInitiated) { try XSignIPAExtractor.readUpdateMetadata(file) }
                let metadata = try await withTaskCancellationHandler(
                    operation: { try await metadataTask.value }, onCancel: { metadataTask.cancel() })
                guard let dictionary = try PropertyListSerialization.propertyList(from: metadata.info, format: nil) as? [String: Any] else {
                    throw XSignOTAError.invalidPackage
                }
                let info = try XSignOTABundleMetadata(info: dictionary)
                guard info.identifier == bundleID, XSignReleaseVersion.compare(info.shortVersion, latest) == 0,
                      update.targetBuild.map({ XSignReleaseVersion.compare($0, info.version) == 0 }) ?? true else {
                    throw failure("ملف التحديث لا يطابق هوية التطبيق أو الإصدار المنشور.")
                }
                if let expectedRequest = update.targetBuildRequest,
                   dictionary["XSignStudioBuildRequest"] as? String != expectedRequest {
                    throw failure("ملف IPA لا يطابق طلب البناء المعتمد من Studio.")
                }
                try checkRelease(update)

                let extraction = directory.appendingPathComponent("Extracted")
                let extractTask = Task.detached(priority: .userInitiated) {
                    try XSignIPAExtractor.extract(file, to: extraction)
                }
                try await withTaskCancellationHandler(operation: { try await extractTask.value }, onCancel: { extractTask.cancel() })
                try checkRelease(update)
                try FileManager.default.removeItem(at: file)
                let payload = extraction.appendingPathComponent("Payload")
                let applications = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "app" }
                guard applications.count == 1, let appDirectory = applications.first else { throw XSignOTAError.invalidPackage }
                let plist = appDirectory.appendingPathComponent("Info.plist")
                let stamped = try XSignAppMetadata.readInfo(at: plist)
                stamped["XSignReleaseOrigin"] = origin
                let data = try PropertyListSerialization.data(fromPropertyList: stamped, format: .binary, options: 0)
                try data.write(to: plist, options: .atomic)
                try XSignPrivateFiles.protect(plist)
                guard !selected.isDeleted, !selected.revoked,
                      selected.expiration.map({ $0 > Date() }) == true,
                      let provision = Storage.shared.getFile(.provision, from: selected),
                      let key = Storage.shared.getFile(.certificate, from: selected) else {
                    throw failure("شهادة التحديث غير متاحة. أضف شهادة صالحة ومتوافقة مع النسخة المثبّتة.")
                }
                let credentials = ZsignHandler.Credentials(provisionPath: provision.path, certificatePath: key.path,
                    password: try Storage.shared.signingPassword(for: selected))
                message = "جاري توقيع تحديث XSign على جهازك…"
                let package = directory.appendingPathComponent("SignedUpdate.ipa")
                let signing = Task.detached(priority: .userInitiated) {
                    await FRPackageWorkGate.shared.acquire()
                    do {
                        try Task.checkCancellation()
                        try XSignMachOEncryption.verifyPayload(at: payload)
                        // The signing engine receives an isolated bundle, never a library record.
                        let profile = appDirectory.appendingPathComponent("embedded.mobileprovision")
                        if FileManager.default.fileExists(atPath: profile.path) { try FileManager.default.removeItem(at: profile) }
                        let handler = ZsignHandler(appUrl: appDirectory, options: Options.defaultOptions)
                        try await handler.sign(with: credentials)
                        try Task.checkCancellation()
                        try FileManager.default.zipItem(at: payload, to: package, shouldKeepParent: true, compressionMethod: .none)
                        try XSignPrivateFiles.protect(package)
                        await FRPackageWorkGate.shared.release()
                    } catch {
                        await FRPackageWorkGate.shared.release()
                        throw error
                    }
                }
                try await withTaskCancellationHandler(operation: { try await signing.value }, onCancel: { signing.cancel() })
                try checkRelease(update)
                let signedInfo = try XSignOTABundleMetadata.read(from: appDirectory)
                let signedProfile = try XSignSelfUpdateProfile.read(appDirectory.appendingPathComponent("embedded.mobileprovision"))
                let signedDictionary = try XSignAppMetadata.readInfo(at: plist)
                guard signedInfo.identifier == bundleID, XSignReleaseVersion.compare(signedInfo.shortVersion, latest) == 0,
                      signedInfo.version == info.version, signedProfile.canReplace(installed, bundleID: bundleID),
                      signedDictionary["XSignReleaseOrigin"] as? String == origin,
                      update.targetBuildRequest.map({ signedDictionary["XSignStudioBuildRequest"] as? String == $0 }) ?? true else {
                    throw failure("هوية التحديث الموقّع لا تطابق النسخة المثبّتة. أُوقف التثبيت.")
                }
                try await install(package: package, metadata: signedInfo, release: update, transfer: transfer)
                delivered = true
            } catch is CancellationError { if !delivered { message = interruption ?? "أُلغي التحديث." } }
            catch {
                if Task.isCancelled {
                    if !delivered { message = interruption ?? "أُلغي التحديث." }
                } else if case .timedOut? = error as? XSignOTAError {
                    message = "انتهت مهلة التثبيت. اضغط تثبيت وحاول مرة أخرى."
                } else {
                    message = (error as? XSignOTAError)?.localizedDescription
                        ?? (error as? XSignUpdateHTTPFailure)?.localizedDescription
                        ?? (error as? XSignIPAExtractor.InvalidArchive)?.localizedDescription
                        ?? ((error as NSError).domain == "XSign.Update" ? error.localizedDescription
                            : "تعذّر تجهيز التحديث. تحقق من الخدمة والشهادة وملف الإصدار.")
                }
            }
        }
    }
    private func checkRelease(_ release: XSignOwnerUpdate) throws {
        XSignSecurityEnforcer.shared.evaluateNetworkSecurity()
        try Task.checkCancellation()
        guard XSignRemoteManager.shared.canInstall(release) else { throw failure("تغيّر الإصدار المعتمد أو توقف التحديث. تحقق مجدداً.") }
    }
    func certificateSetupFinished() {
        guard let update=pendingUpdate else { return }
        pendingUpdate=nil
        let added=Set(Storage.shared.getAllCertificates().compactMap { $0.uuid }).subtracting(knownCertificates)
        if !added.isEmpty { start(update) }
    }
    private func install(package: URL, metadata: XSignOTABundleMetadata, release: XSignOwnerUpdate, transfer: UUID) async throws {
        try checkRelease(release)
        #if !targetEnvironment(macCatalyst)
        BackgroundAudioManager.shared.start()
        defer { BackgroundAudioManager.shared.stop() }
        #endif
        let installer = XSignOTAInstaller(confirmationTimeout: 90)
        try await installer.install(package: package, bundleIdentifier: metadata.identifier,
            version: metadata.version, title: metadata.title, mode: .selected, update: { [weak self] stage in
                switch stage {
                case .waitingForSystem: self?.message = "وافق على طلب التثبيت من iOS…"
                case .delivering: self?.message = "جاري إرسال التحديث إلى iOS…"
                case .delivered:
                    XSignSecurityEnforcer.shared.finishProtectedTransfer(transfer)
                    self?.delivered = true
                    self?.message = "انتظر اكتمال التثبيت، ثم افتح XSign من جديد."
                case .preparingServer, .preparingManifest: break
                }
            }, open: { link in
                XSignSecurityEnforcer.shared.evaluateNetworkSecurity()
                guard !Task.isCancelled, XSignRemoteManager.shared.canInstall(release) else { return false }
                return await withCheckedContinuation { continuation in
                    UIApplication.shared.open(link, options: [:]) { continuation.resume(returning: $0) }
                }
            })
    }
    private func failure(_ message: String) -> NSError { NSError(domain:"XSign.Update",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    private func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in UIApplication.shared.open(url,options:[:]) { continuation.resume(returning:$0) } }
    }
}

private struct XSignUpdateHTTPFailure: LocalizedError {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 401, 403, 404:
            return "تعذّر الوصول إلى ملف التحديث (HTTP \(status)). راجع توفر الملف وصلاحيات المستودع."
        default:
            return "تعذّر تنزيل ملف التحديث (HTTP \(status)). أعد المحاولة لاحقاً."
        }
    }
}

private final class XSignUpdateFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximum: Int64
    private var continuation: CheckedContinuation<URL,Error>?
    private var saved=false
    private var lastProgress=Date.distantPast
    private let progress:(@Sendable(Double)->Void)?
    init(destination:URL,maximum:Int64,progress:(@Sendable(Double)->Void)?) { self.destination=destination;self.maximum=maximum;self.progress=progress }
    static func fetch(_ url: URL,to destination: URL,maximum:Int64,progress:(@Sendable(Double)->Void)?=nil) async throws -> URL {
        let delegate=XSignUpdateFileDownload(destination:destination,maximum:maximum,progress:progress)
        let request = try XSignCatalogueEndpoint.packageRequest(
            URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        let configuration=URLSessionConfiguration.ephemeral
        configuration.urlCache=nil;configuration.timeoutIntervalForRequest=30;configuration.timeoutIntervalForResource=1800
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        let session=URLSession(configuration:configuration,delegate:delegate,delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                delegate.continuation=continuation
                if Task.isCancelled { delegate.continuation=nil;continuation.resume(throwing:CancellationError()) }
                else { session.downloadTask(with:request).resume() }
            }
        },onCancel:{ session.invalidateAndCancel() })
    }
    func urlSession(_ session: URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,
                    totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) {
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum { downloadTask.cancel();return }
        if totalBytesExpectedToWrite>0,Date().timeIntervalSince(lastProgress)>=0.15 {
            lastProgress=Date();progress?(min(1,Double(totalBytesWritten)/Double(totalBytesExpectedToWrite)))
        }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,
                    newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
        let allowed = request.url.flatMap { XSignManagedSource.httpsURL($0.absoluteString) } != nil &&
            XSignCatalogueEndpoint.mayRedirect(task, to: request)
        completionHandler(allowed ? request : nil)
    }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard response.statusCode == 200 else { throw XSignUpdateHTTPFailure(status: response.statusCode) }
            guard let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, Int64(size) <= maximum else { throw XSignOTAError.invalidPackage }
            try FileManager.default.moveItem(at:location,to:destination);try XSignPrivateFiles.protect(destination)
            saved=true;continuation?.resume(returning:destination);continuation=nil
        } catch { continuation?.resume(throwing:error);continuation=nil }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        if !saved { continuation?.resume(throwing:error ?? URLError(.cannotDecodeContentData));continuation=nil }
    }
}

struct XSignAppUpdateView: View {
    @State private var checking = false
    @AppStorage("Feather.userTintColor") private var tintHex = "#005BBB"
    @ObservedObject private var security = XSignSecurityEnforcer.shared
    @ObservedObject private var remote=XSignRemoteManager.shared
    @StateObject private var updater=XSignAppUpdater()
    var isRequired = false
    private var release: XSignOwnerUpdate? { isRequired ? remote.requiredRelease : remote.optionalRelease }
    var body: some View {
        ScrollView {
            VStack(spacing:16) {
                if let release {
                    let actionAvailable = !updater.busy
                    let custom = release.html.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    let hasCustomAction = custom?.contains("xsign-update://install") == true
                    let name = release.app_name.flatMap { $0.isEmpty ? nil : $0 } ?? remote.currentAppName
                    let heading = isRequired
                        ? String(format: xsignText("حدّث %@ للمتابعة"), name)
                        : String(format: xsignText("تحديث %@"), name)
                    let version = xsignText("الإصدار") + " " + (release.latest_version ?? "—")
                    let notes = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let info = notes.flatMap { $0.isEmpty ? nil : $0 }
                        ?? xsignText("ثبّت الإصدار ووافق على طلب iOS.")
                    let install = { if actionAvailable { updater.start(release) } }
                    XSignUpdateHTML(html: custom ?? XSignInstallPageHTML.page(heading: heading, name: name, version: version,
                        details: info, canInstall: actionAvailable, button: xsignText("تثبيت"), tintHex: tintHex), onInstall: install)
                        .frame(height: custom == nil ? 330 : 390)
                    if custom != nil && !hasCustomAction {
                        Button(action: install) { Text(xsignText("تثبيت")).frame(maxWidth: .infinity) }
                            .buttonStyle(XSignInstallButtonStyle())
                            .disabled(!actionAvailable)
                    }
                    if !release.installable {
                        Text("بيانات ملف التحديث غير مكتملة في لوحة التحكم. أعد فحص رابط IPA وانشر التحديث مجدداً.")
                            .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    if let networkFailure = security.packageNetworkFailure {
                        Text(xsignText(networkFailure)).font(.footnote).foregroundStyle(.secondary)
                    }
                    if updater.busy && !updater.delivered {
                        if let progress = updater.progress { ProgressView(value: progress) }
                        else { ProgressView() }
                    }
                    if !updater.message.isEmpty {
                        Text(xsignText(updater.message)).font(.footnote).multilineTextAlignment(.center)
                    }
                } else if !remote.initialSyncSettled {
                    ProgressView("جارٍ التحقق من التحديث…")
                } else if remote.remoteSyncStatus != XSignRemoteManager.synchronizedStatus {
                    Label("تعذّر التحقق من آخر تحديث", systemImage: "exclamationmark.circle")
                        .font(.headline)
                    Text(xsignText(remote.remoteSyncStatus)).font(.footnote).foregroundStyle(.secondary)
                } else if remote.ownerRelease?.enabled == false {
                    Label("التحديث متوقف في إعدادات المتجر", systemImage: "pause.circle").font(.headline)
                } else if remote.ownerRelease?.enabled == true, remote.ownerRelease?.installable != true {
                    Label("بيانات ملف التحديث غير مكتملة في لوحة التحكم. أعد فحص رابط IPA وانشر التحديث مجدداً.",
                          systemImage: "exclamationmark.circle").font(.footnote)
                } else {
                    Label("ماكو تحديث متاح حالياً", systemImage: "checkmark.circle").font(.headline)
                }
                if release == nil {
                    Button {
                        guard !checking else { return }
                        checking = true
                        Task { @MainActor in
                            await remote.fetchRemoteConfig(force: true)
                            checking = false
                        }
                    } label: {
                        if checking { ProgressView() }
                        else { Text("التحقق الآن") }
                    }
                    .font(.footnote)
                    .xsignGlassButton()
                    .disabled(checking)
                }
            }.frame(maxWidth: 480).padding(.horizontal, 16).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
        .xsignPageBackground()

        .sheet(isPresented:$updater.needsCertificate,onDismiss:{ updater.certificateSetupFinished() }) { CertificatesAddView() }
        .interactiveDismissDisabled(updater.busy)
        .onDisappear { updater.cancel() }
        .onChange(of: release?.installIdentity) { _ in updater.releaseChanged() }
        .onChange(of: security.isVPNOrProxyDetected) { blocked in
            if blocked { updater.releaseChanged() }
        }
    }
}

enum XSignInstallPageHTML {
    private static let template = Bundle.main.url(forResource: "XSignUpdateScreen", withExtension: "html")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        ?? "<main style='padding:24px;background:Canvas;color:CanvasText;border-radius:18px;text-align:center;font-family:system-ui'><h1>{{heading}}</h1><p>{{name}} · {{version}}</p><p>{{details}}</p>{{action}}</main>"

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "{", with: "&#123;").replacingOccurrences(of: "}", with: "&#125;")
    }

    static func page(heading: String, name: String, version: String, details: String, canInstall: Bool, button: String, tintHex: String = "#005BBB") -> String {
        let tint = XSignRemoteManager.validHex(tintHex) ? tintHex : "#005BBB"
        let action = canInstall ? "<a class='install-action' href='xsign-update://install'>\(escape(button))</a>" : ""
        var page = template.replacingOccurrences(of: "{{tint}}", with: tint)
        for (key, value) in [("heading", escape(heading)), ("name", escape(name)), ("version", escape(version)),
                             ("details", escape(String(details.prefix(3000)))), ("action", action)] {
            page = page.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return page
    }

    static func document(_ fragment: String) -> String {
        "<!doctype html><html lang='ar' dir='rtl'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><meta name='color-scheme' content='light dark'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none';style-src 'unsafe-inline';img-src data:;form-action 'none';base-uri 'none'\"></head><body>" + String(fragment.prefix(100000)) + "</body></html>"
    }
}

struct XSignUpdateHTML: UIViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    let html: String
    let onInstall: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onInstall:onInstall) }
    func makeUIView(context:Context)->WKWebView {
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript=false
        let view=WKWebView(frame:.zero,configuration:config)
        view.isOpaque=false;view.backgroundColor = .clear;view.navigationDelegate=context.coordinator
        view.allowsLinkPreview=false
        return view
    }
    func updateUIView(_ view:WKWebView,context:Context) {
        context.coordinator.onInstall=onInstall
        view.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        let content=XSignInstallPageHTML.document(html)
        if context.coordinator.lastHTML != content {
            context.coordinator.lastHTML=content;view.loadHTMLString(content,baseURL:nil)
        }
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML=""
        var onInstall: () -> Void
        init(onInstall:@escaping()->Void) { self.onInstall=onInstall }
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,
                     decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
            if action.navigationType == .linkActivated,action.sourceFrame.isMainFrame,action.targetFrame?.isMainFrame != false,
               action.request.url?.absoluteString == "xsign-update://install" {
                decisionHandler(.cancel);onInstall();return
            }
            decisionHandler(action.navigationType == .other && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
