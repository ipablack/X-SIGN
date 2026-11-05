import SwiftUI
import CoreData

@MainActor
private final class XSignBulkSigningModel: ObservableObject {
    let queue: XSignBatchQueue<any AppInfoPresentable>
    @Published var errorMessage: String?

    init(apps: [any AppInfoPresentable]) {
        queue = XSignBatchQueue(items: apps)
        queue.onChange = { [weak self] in self?.objectWillChange.send() }
    }

    func start(certificate: CertificatePair?, retry: Bool = false) {
        guard !queue.isRunning else { return }
        guard let certificate else { errorMessage = "أضف شهادة ثم اخترها لبدء التوقيع."; return }
        var common = OptionsManager.shared.options
        common.signingOption = .default
        // A per-app name/version override must never rename an entire batch to the same identity.
        common.appName = nil; common.appIdentifier = nil; common.appVersion = nil
        if common.matchCertificateAppID == true && XSignSecurityEnforcer.shared.locks.allowsAppMetadataEditing && queue.entries.count > 1 {
            do {
                guard let url = Storage.shared.getFile(.provision, from: certificate) else { throw SigningFileHandlerError.missingCertifcate }
                guard try XSignProvisioningProfile.read(at: url).isWildcard else {
                    errorMessage = "مطابقة App ID المحدد ستعطي التطبيقات البندل نفسه. استخدم بروفايل عامًا للمجموعة أو وقّع تطبيقًا واحدًا."
                    return
                }
            } catch { errorMessage = error.localizedDescription; return }
        }
        errorMessage = nil
        if retry { queue.prepareRetry() }
        let snapshot = common
        queue.start { app in
            if let managed = app as? NSManagedObject, managed.isDeleted || managed.managedObjectContext == nil {
                throw NSError(domain: "XSign.Batch", code: 404, userInfo: [NSLocalizedDescriptionKey:"التطبيق لم يعد موجودًا في المكتبة."])
            }
            var options = snapshot
            if let identifier = app.identifier {
                options.appIdentifier = options.identifiers[identifier]
                if options.appIdentifier == nil && options.ppqProtection && certificate.ppQCheck {
                    options.appIdentifier = identifier + "." + options.ppqString
                }
            }
            if let name = app.name { options.appName = options.displayNames[name] }
            let result: Result<String, Error> = await withCheckedContinuation { continuation in
                FR.signPackageFileWithResult(app, using: options, icon: nil, certificate: certificate, preserveBundleForBatch: true) {
                    continuation.resume(returning: $0)
                }
            }
            return try result.get()
        }
    }
}

@MainActor
struct XSignBulkSigningView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: XSignBulkSigningModel
    @State private var certificateIndex: Int
    @State private var installApp: AnyApp?
    @FetchRequest(entity: CertificatePair.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)])
    private var certificates: FetchedResults<CertificatePair>

    init(apps: [any AppInfoPresentable]) {
        _model = StateObject(wrappedValue: XSignBulkSigningModel(apps: apps))
        _certificateIndex = State(initialValue: UserDefaults.standard.integer(forKey: "feather.selectedCert"))
    }
    private var selectedCertificate: CertificatePair? {
        certificates.indices.contains(certificateIndex) ? certificates[certificateIndex] : certificates.first
    }
    private var completed: Int {
        model.queue.entries.filter { entry in
            switch entry.state { case .succeeded, .failed: return true; default: return false }
        }.count
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    if certificates.isEmpty { Text("أضف شهادة من إعدادات الحساب أولًا.") }
                    else {
                        Picker("الشهادة", selection: $certificateIndex) {
                            ForEach(Array(certificates.enumerated()), id: \.element.objectID) { index, certificate in
                                Text(certificate.nickname ?? "شهادة \(index + 1)").tag(index)
                            }
                        }.disabled(model.queue.isRunning)
                    }
                    ProgressView(value: Double(completed), total: Double(max(1, model.queue.entries.count)))
                    Text("تمت معالجة \(completed) من \(model.queue.entries.count)").font(.footnote).foregroundStyle(.secondary)
                    if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                    if model.queue.isRunning {
                        Button("توقّف بعد التطبيق الحالي", role: .destructive) { model.queue.stopAfterCurrent() }
                    } else if model.queue.entries.contains(where: { $0.state.isRetryable }) {
                        Button("إعادة محاولة المتعذر والمتبقي") { model.start(certificate: selectedCertificate, retry: true) }
                            .disabled(certificates.isEmpty)
                    } else if completed == 0 {
                        Button("بدء توقيع المجموعة") { model.start(certificate: selectedCertificate) }.disabled(certificates.isEmpty)
                    }
                } footer: {
                    Text("تُوقَّع التطبيقات بالتتابع لتقليل الضغط على الذاكرة. تبقى معلومات كل تطبيق، وتطبّق خيارات التوقيع العامة والتخصيصات المسجلة له. يمكنك تثبيت كل نتيجة بعد اكتمالها.")
                }
                Section("التطبيقات") {
                    ForEach(model.queue.entries) { entry in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.item.name ?? "تطبيق").font(.headline)
                                Text(status(entry.state)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if case .working = entry.state { ProgressView() }
                            if case .succeeded(let uuid) = entry.state {
                                Button("تثبيت") {
                                    if let signed = AutoSignPipelineManager.fetchSignedApps().first(where: { $0.uuid == uuid }) {
                                        installApp = AnyApp(base: signed)
                                    } else { model.errorMessage = "لم تعد النسخة الموقعة موجودة في المكتبة." }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("التوقيع الجماعي")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("إغلاق") { dismiss() }.disabled(model.queue.isRunning)
            } }
            .sheet(item: $installApp) { app in InstallPreviewView(app: app.base) }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(model.queue.isRunning)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func status(_ state: XSignBatchQueue<any AppInfoPresentable>.State) -> String {
        switch state {
        case .waiting: return "بانتظار التوقيع"
        case .working: return "جارٍ التوقيع"
        case .succeeded: return "جاهز للتثبيت"
        case .failed(let reason): return reason
        case .cancelled: return "أُلغي انتظاره"
        }
    }
}
