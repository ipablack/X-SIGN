import SwiftUI
import NimbleViews
import IDeviceSwift

// Native signing has completed. Installation uses Feather Semi Local, without pairing or export.
struct InstallPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = InstallerStatusViewModel(isIdevice: false)
    @State private var operation: Task<Void, Never>?
    @State private var started = false
    @State private var awaitingChoice = true
    @State private var delivered = false
    @State private var status = ""
    @State private var showError = false
    @State private var errorMessage = ""
    let app: AppInfoPresentable

    var body: some View {
        VStack(spacing: 12) {
            if awaitingChoice {
                Label("النسخة جاهزة", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                Text(app.name ?? "التطبيق").font(.subheadline)
                Text("تثبيت مباشر بطريقة Feather، بدون Pairing.").font(.footnote).foregroundStyle(.secondary)
                Button("تثبيت على الجهاز") { begin() }.buttonStyle(.borderedProminent)
                Button("تم") { dismiss() }
            } else {
                if !delivered && started { ProgressView() }
                Text(status).font(.subheadline).multilineTextAlignment(.center)
                if delivered {
                    Text("اكتمال نقل الملف لا يؤكد نجاح تثبيت iOS. وافق على رسالة النظام وانتظر انتهاء التثبيت.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("فتح التطبيق") { UIApplication.openApp(with: app.identifier ?? "") }
                    Button("تم") { dismiss() }
                } else if case .broken = viewModel.status {
                    Button("إعادة المحاولة") { started = false; begin() }
                    Button("إغلاق") { dismiss() }
                } else {
                    Text("أبقِ XSign مفتوحاً أثناء طلب التثبيت.").font(.caption).foregroundStyle(.secondary)
                    Button("إيقاف التثبيت", role: .cancel) { operation?.cancel(); dismiss() }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.secondarySystemBackground))
        .interactiveDismissDisabled(started && !delivered && !showError)
        .onDisappear { operation?.cancel(); stopAudio() }
        .alert("التثبيت", isPresented: $showError,
            actions: { Button("حسناً", role: .cancel) {} },
            message: { Text(errorMessage) })
    }

    @MainActor private func begin() {
        guard !started else { return }
        guard let identifier = app.identifier, !identifier.isEmpty else { fail(XSignOTAError.invalidPackage); return }
        started = true
        awaitingChoice = false
        delivered = false
        status = "تجهيز نسخة التثبيت…"
        viewModel.status = .none
        #if !targetEnvironment(macCatalyst)
        BackgroundAudioManager.shared.start()
        #endif
        operation = Task.detached(priority: .userInitiated) {
            let handler = await ArchiveHandler(app: app, viewModel: viewModel)
            do {
                try Task.checkCancellation()
                let metadata = try await handler.move()
                let package = try await handler.archive()
                try Task.checkCancellation()
                let installer = XSignOTAInstaller()
                try await installer.install(package: package, bundleIdentifier: metadata.identifier, version: metadata.version, title: metadata.title,
                    update: { stage in
                        switch stage {
                        case .preparingTLS: status = "تجهيز التثبيت المحلي…"
                        case .preparingDomain: status = "تجهيز ملف التثبيت عبر خدمة Feather…"
                        case .waitingForSystem: status = "وافق على طلب التثبيت من iOS…"
                        case .delivering: status = "نقل التطبيق إلى نظام iOS…"; viewModel.status = .sendingPayload
                        case .delivered:
                            delivered = true
                            status = "أُرسل ملف التطبيق إلى iOS."
                            viewModel.status = .installing
                        }
                    }, open: { link in
                        await withCheckedContinuation { continuation in
                            UIApplication.shared.open(link, options: [:]) { continuation.resume(returning: $0) }
                        }
                    })
                await handler.clean()
                await MainActor.run { stopAudio() }
            } catch {
                await handler.clean()
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                await MainActor.run { fail(error) }
            }
        }
    }

    @MainActor private func fail(_ error: Error) {
        started = false
        viewModel.status = .broken(error)
        // Never put a capability URL or signing credential in a displayed network error.
        errorMessage = (error as? XSignOTAError)?.localizedDescription ?? "تعذّر التثبيت. تحقق من الاتصال وخدمة Feather وصلاحية شهادة التطبيق."
        status = errorMessage
        showError = true
        stopAudio()
    }
    @MainActor private func stopAudio() {
        #if !targetEnvironment(macCatalyst)
        BackgroundAudioManager.shared.stop()
        #endif
    }
}
