import SwiftUI
import WebKit
import CoreData
import IDeviceSwift
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
    private let maximumSize: Int64=2_147_483_648
    func cancel() { operation?.cancel() }
    func releaseChanged() {
        cancel(); pendingUpdate = nil; needsCertificate = false; delivered = false; progress = nil
        if !busy { message = "" }
    }
    func start(_ update: XSignOwnerUpdate) {
        guard !busy,!delivered else { return }
        busy=true;progress=nil;message="التحقق من التحديث…"
        operation=Task {
            defer { busy=false }
            do {
                try checkRelease(update)
                guard let latest=update.latest_version, let origin=update.releaseOrigin,
                      let bundleID=Bundle.main.bundleIdentifier else { throw failure("لا يوجد تحديث صالح في إعدادات الناشر.") }
                if let manifest=update.manifestURL {
                    let session=XSignBoundedHTTP.session();defer { session.invalidateAndCancel() }
                    let (data,response)=try await XSignBoundedHTTP.fetch(URLRequest(url:manifest),using:session,limit:32768)
                    guard response.statusCode == 200,
                          let root=try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
                          let items=root["items"] as? [[String:Any]],items.count == 1,
                          let metadata=items[0]["metadata"] as? [String:Any],metadata["bundle-identifier"] as? String == bundleID,
                          metadata["bundle-version"] as? String == (update.targetBuild ?? latest),
                          let assets=items[0]["assets"] as? [[String:Any]],
                          assets.contains(where:{ $0["kind"] as? String == "software-package" && XSignManagedSource.httpsURL($0["url"] as? String) != nil }) else {
                        throw failure("ملف تحديث الناشر لا يطابق هوية XSign ورقم البناء المطلوب.")
                    }
                    try checkRelease(update)
                    var link=URLComponents();link.scheme="itms-services";link.host=""
                    link.queryItems=[.init(name:"action",value:"download-manifest"),.init(name:"url",value:manifest.absoluteString)]
                    guard let url=link.url, await open(url) else { throw failure("تعذّر فتح طلب تثبيت iOS.") }
                    delivered=true
                    message="أُرسل طلب التحديث إلى iOS. هذا لا يؤكد اكتمال التثبيت؛ وافق على رسالة النظام."
                    return
                }
                guard let url=update.verifiedURL,let expected=update.sha256 else { throw failure("التحديث غير متاح حالياً. حاول لاحقاً.") }
                guard let embedded=Bundle.main.url(forResource:"embedded",withExtension:"mobileprovision"),
                      let installed=try? XSignSelfUpdateProfile.read(embedded) else {
                    throw failure("تعذّر التحقق من هوية XSign المثبّتة؛ لم يبدأ التحديث.")
                }
                guard let certificate=await XSignSelfUpdateCertificate.select(installed:installed,bundleID:bundleID) else {
                    try Task.checkCancellation()
                    knownCertificates=Set(Storage.shared.getAllCertificates().compactMap { $0.uuid })
                    pendingUpdate=update;needsCertificate=true
                    message="أضف شهادة متوافقة مع نسخة XSign المثبّتة لإكمال التحديث."
                    return
                }
                message="جاري تنزيل التحديث…"
                let directory=XSignPrivateFiles.workDirectory(prefix:"SelfUpdate")
                try XSignPrivateFiles.createDirectory(directory)
                defer { try? FileManager.default.removeItem(at:directory) }
                let file=try await XSignUpdateFileDownload.fetch(url,to:directory.appendingPathComponent("update.ipa"),maximum:maximumSize,progress:{ [weak self] value in
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
                let uuid: String=try await withCheckedThrowingContinuation { continuation in
                    FR.importPackageFile(file,consumeTemporaryFile:false) { continuation.resume(with:$0) }
                }
                let importedRequest=NSFetchRequest<Imported>(entityName:"Imported");importedRequest.fetchLimit=1
                importedRequest.predicate=NSPredicate(format:"uuid == %@",uuid)
                guard let imported=try Storage.shared.context.fetch(importedRequest).first else { throw failure("تعذّر قراءة تطبيق التحديث.") }
                defer { Storage.shared.deleteApp(for:imported) }
                guard let appDirectory=Storage.shared.getAppDirectory(for:imported) else { throw failure("تعذّر قراءة تطبيق التحديث.") }
                let info=try XSignOTABundleMetadata.read(from:appDirectory)
                guard info.identifier == bundleID, info.shortVersion == latest,
                      update.targetBuild == nil || update.targetBuild == info.version else {
                    throw failure("ملف التحديث لا يطابق هوية التطبيق أو الإصدار المنشور.")
                }
                try checkRelease(update)
                // The signed bundle records the selected release, including reinstalls of the same version.
                let plist = appDirectory.appendingPathComponent("Info.plist")
                var stamped = try XSignAppMetadata.readInfo(at: plist)
                stamped["XSignReleaseOrigin"] = origin
                let data = try PropertyListSerialization.data(fromPropertyList: stamped, format: .binary, options: 0)
                try data.write(to: plist, options: .atomic)
                try XSignPrivateFiles.protect(plist)
                message="جاري تجهيز التحديث…"
                var options=Options.defaultOptions;options.signingOption = .default
                options.appName=nil;options.appIdentifier=nil;options.appVersion=nil;options.matchCertificateAppID=false
                let permit=XSignVerifiedSelfUpdate(appUUID:uuid,bundleID:bundleID)
                let signedUUID: String=try await withCheckedThrowingContinuation { continuation in
                    FR.signPackageFileWithResult(imported,using:options,icon:nil,certificate:certificate,selfUpdatePermit:permit) {
                        continuation.resume(with:$0)
                    }
                }
                let request=NSFetchRequest<Signed>(entityName:"Signed");request.fetchLimit=1
                request.predicate=NSPredicate(format:"uuid == %@",signedUUID)
                guard let signed=try Storage.shared.context.fetch(request).first else { throw failure("تعذّر العثور على نسخة التحديث الموقعة.") }
                defer { Storage.shared.deleteApp(for:signed) }
                try checkRelease(update)
                guard let signedDirectory=Storage.shared.getAppDirectory(for:signed) else { throw failure("تعذّر فحص التحديث الجاهز.") }
                let signedInfo=try XSignOTABundleMetadata.read(from:signedDirectory)
                let signedProfile=try XSignSelfUpdateProfile.read(signedDirectory.appendingPathComponent("embedded.mobileprovision"))
                let signedDictionary = try XSignAppMetadata.readInfo(at: signedDirectory.appendingPathComponent("Info.plist"))
                guard signedInfo.identifier==bundleID,signedInfo.shortVersion==latest,
                      signedInfo.version==info.version,signedProfile.canReplace(installed,bundleID:bundleID),
                      signedDictionary["XSignReleaseOrigin"] as? String == origin else {
                    throw failure("لم تجتز النسخة الموقعة فحص الهوية. أُوقف التثبيت لحماية بياناتك.")
                }
                try await install(signed, release: update)
                delivered=true;message="تم إرسال التحديث إلى iOS. وافق على طلب التثبيت وانتظر اكتماله."
            } catch is CancellationError { message="أُلغي التحديث." }
            catch { message=(error as NSError).domain == "XSign.Update" ? error.localizedDescription : "تعذّر تجهيز التحديث. تحقق من الخدمة والشهادة وملف الإصدار." }
        }
    }
    private func checkRelease(_ release: XSignOwnerUpdate) throws {
        try Task.checkCancellation()
        guard XSignRemoteManager.shared.canInstall(release) else { throw failure("تغيّر الإصدار المعتمد أو توقف التحديث. تحقق مجدداً.") }
    }
    func certificateSetupFinished() {
        guard let update=pendingUpdate else { return }
        pendingUpdate=nil
        let added=Set(Storage.shared.getAllCertificates().compactMap { $0.uuid }).subtracting(knownCertificates)
        if !added.isEmpty { start(update) }
    }
    private func install(_ app: AppInfoPresentable, release: XSignOwnerUpdate) async throws {
        let status=InstallerStatusViewModel(isIdevice:false)
        let handler=ArchiveHandler(app:app,viewModel:status)
        #if !targetEnvironment(macCatalyst)
        BackgroundAudioManager.shared.start()
        defer { BackgroundAudioManager.shared.stop() }
        #endif
        do {
            let metadata=try await handler.move()
            let package=try await handler.archive()
            try checkRelease(release)
            let installer=XSignOTAInstaller()
            try await installer.install(package:package,bundleIdentifier:metadata.identifier,
                version:metadata.version,title:metadata.title,update:{ [weak self] stage in
                    switch stage {
                    case .waitingForSystem: self?.message="وافق على طلب التثبيت من iOS…"
                    case .delivering: self?.message="جاري تثبيت التحديث…"
                    default: break
                    }
                },open:{ link in
                    guard XSignRemoteManager.shared.canInstall(release) else { return false }
                    return await withCheckedContinuation { continuation in
                        UIApplication.shared.open(link,options:[:]) { continuation.resume(returning:$0) }
                    }
                })
            await handler.clean()
        } catch { await handler.clean();throw error }
    }
    private func failure(_ message: String) -> NSError { NSError(domain:"XSign.Update",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    private func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in UIApplication.shared.open(url,options:[:]) { continuation.resume(returning:$0) } }
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
        let configuration=URLSessionConfiguration.ephemeral
        configuration.urlCache=nil;configuration.timeoutIntervalForRequest=30;configuration.timeoutIntervalForResource=1800
        let session=URLSession(configuration:configuration,delegate:delegate,delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                delegate.continuation=continuation
                if Task.isCancelled { delegate.continuation=nil;continuation.resume(throwing:CancellationError()) }
                else { session.downloadTask(with:url).resume() }
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
        completionHandler(request.url.flatMap { XSignManagedSource.httpsURL($0.absoluteString) } == nil ? nil : request)
    }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {
        do {
            guard let response=downloadTask.response as? HTTPURLResponse,response.statusCode == 200,
                  let size=try location.resourceValues(forKeys:[.fileSizeKey]).fileSize,size>0,Int64(size)<=maximum else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at:location,to:destination);try XSignPrivateFiles.protect(destination)
            saved=true;continuation?.resume(returning:destination);continuation=nil
        } catch { continuation?.resume(throwing:error);continuation=nil }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        if !saved { continuation?.resume(throwing:error ?? URLError(.cannotDecodeContentData));continuation=nil }
    }
}

struct XSignAppUpdateView: View {
    @ObservedObject private var remote=XSignRemoteManager.shared
    @StateObject private var updater=XSignAppUpdater()
    var isRequired = false
    var body: some View {
        ScrollView {
            VStack(spacing:16) {
                if let release=remote.config?.dashboard?.update, release.installable {
                    let allowed = remote.canInstall(release) && !updater.busy && !updater.delivered
                    let custom = release.html.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    let heading = isRequired ? "حدّث XSign للمتابعة" : "تحديث XSign"
                    let version = "الإصدار \(release.latest_version ?? "—")" + (release.targetBuild.map { " · البناء \($0)" } ?? "")
                    let info = release.notes.flatMap { $0.isEmpty ? nil : $0 } ?? (isRequired ? (remote.config?.force_update?.message ?? "ثبّت الإصدار المعتمد لمواصلة استخدام XSign.") : "ثبّت الإصدار الجديد ووافق على طلب iOS.")
                    XSignUpdateHTML(html: custom ?? XSignInstallPageHTML.page(heading: heading, name: "XSign", version: version,
                        details: info, canInstall: allowed, button: "تثبيت التحديث"), onInstall: { if allowed { updater.start(release) } })
                        .frame(height: custom == nil ? 345 : 390)
                    if custom != nil && allowed { Button("تثبيت التحديث") { updater.start(release) }.buttonStyle(.borderedProminent) }
                    Text("المثبّت الآن: \(remote.currentVersion) · البناء \(remote.currentBuild)").font(.caption).foregroundStyle(.secondary)
                    if updater.busy { ProgressView(value:updater.progress) }
                    if !updater.message.isEmpty { Text(updater.message).font(.footnote).multilineTextAlignment(.center) }
                    if updater.busy { Button("إلغاء",role:.cancel) { updater.cancel() } }
                } else { Label("ماكو تحديث متاح حالياً", systemImage: "checkmark.circle").font(.headline) }
                Button("التحقق الآن") { Task { await remote.fetchRemoteConfig(force: true) } }.font(.footnote)
            }.frame(maxWidth: 480).padding(.horizontal, 16).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
        .background(AppStoreTheme.background.ignoresSafeArea())
        .environment(\.layoutDirection, .rightToLeft)
        .sheet(isPresented:$updater.needsCertificate,onDismiss:{ updater.certificateSetupFinished() }) { CertificatesAddView() }
        .interactiveDismissDisabled(updater.busy)
        .onDisappear { updater.cancel() }
        .onChange(of: remote.config?.dashboard?.update?.installIdentity) { _ in updater.releaseChanged() }
    }
}

enum XSignInstallPageHTML {
    private static let template = Bundle.main.url(forResource: "XSignInstall", withExtension: "html")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        ?? "<main style='padding:24px;background:#003173;color:white;border-radius:18px;text-align:center;font-family:system-ui'><h1>{{heading}}</h1><p>{{name}} · {{version}}</p><p>{{details}}</p>{{action}}</main>"

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "{", with: "&#123;").replacingOccurrences(of: "}", with: "&#125;")
    }

    static func page(heading: String, name: String, version: String, details: String, canInstall: Bool, button: String) -> String {
        let action = canInstall ? "<a class='install-action' style='color:#003173;background:#e9f3ff' href='xsign-update://install'>\(escape(button))</a><p class='install-hint'>وافق على طلب التثبيت من iOS.</p>" : ""
        var page = template
        for (key, value) in [("heading", escape(heading)), ("name", escape(name)), ("version", escape(version)),
                             ("details", escape(String(details.prefix(3000)))), ("action", action)] {
            page = page.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return page
    }

    static func document(_ fragment: String) -> String {
        "<!doctype html><html lang='ar' dir='rtl'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none';style-src 'unsafe-inline';img-src data:;form-action 'none';base-uri 'none'\"></head><body>" + String(fragment.prefix(100000)) + "</body></html>"
    }
}

struct XSignUpdateHTML: UIViewRepresentable {
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
            if action.navigationType == .linkActivated,action.sourceFrame.isMainFrame,action.targetFrame?.isMainFrame == true,
               action.request.url?.absoluteString == "xsign-update://install" {
                decisionHandler(.cancel);onInstall();return
            }
            decisionHandler(action.navigationType == .other && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
