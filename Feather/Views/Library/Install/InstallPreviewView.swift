import SwiftUI
import NimbleViews
import IDeviceSwift

// Signing is performed locally before this sheet. Installation uses the device proxy only.
struct InstallPreviewView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("Feather.useShareSheetForArchiving") private var useShareSheet = false
    @StateObject var viewModel: InstallerStatusViewModel
    @State private var operation: Task<Void, Never>?
    @State private var started = false
    @State private var showSetup = false
    @State private var showError = false
    @State private var errorMessage = ""
    var app: AppInfoPresentable
    @State var isSharing: Bool

    init(app: AppInfoPresentable, isSharing: Bool = false) {
        self.app = app
        self.isSharing = isSharing
        self._viewModel = StateObject(wrappedValue: InstallerStatusViewModel(isIdevice: true))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            InstallProgressView(app: app, viewModel: viewModel)
            VStack(spacing: 8) {
                Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
                if viewModel.isCompleted {
                    Button("فتح التطبيق") { UIApplication.openApp(with: app.identifier ?? "") }
                }
                if case .broken = viewModel.status {
                    HStack {
                        Button("إعادة المحاولة") { started = false; begin(sharing: isSharing) }
                        Button("إعداد التثبيت المحلي") { showSetup = true }
                        Button("تصدير IPA") { started = false; begin(sharing: true) }
                    }
                    .font(.footnote)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
        .padding()
        .onAppear { begin(sharing: isSharing) }
        .onDisappear { operation?.cancel(); stopAudio() }
        .sheet(isPresented: $showSetup) {
            NavigationStack { InstallationView() }
        }
        .alert("XSign", isPresented: $showError) {
            Button("حسناً", role: .cancel) {}
        } message: { Text(errorMessage) }
    }

    @MainActor
    private func begin(sharing: Bool) {
        guard !started else { return }
        started = true
        if !sharing && !FileManager.default.isReadableFile(atPath: HeartbeatManager.pairingFile()) {
            fail(NSError(domain: "XSign.Installation", code: 700, userInfo: [
                NSLocalizedDescriptionKey: "التوقيع محلي وجاهز. للتثبيت المباشر استورد ملف Pairing لجهازك من إعداد التثبيت المحلي. يمكنك أيضاً تصدير ملف IPA الموقّع."
            ]))
            return
        }
        if !sharing && (app.identifier ?? "").isEmpty {
            fail(NSError(domain: "XSign.Installation", code: 701, userInfo: [NSLocalizedDescriptionKey: "معرّف التطبيق مفقود؛ أعد توقيعه بعد مراجعة معلوماته."]))
            return
        }
        UserDefaults.standard.set(1, forKey: "Feather.installationMethod")
        viewModel.status = .none
        let share = useShareSheet
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        #if !targetEnvironment(macCatalyst)
        BackgroundAudioManager.shared.start()
        #endif
        operation = Task.detached(priority: .userInitiated) {
            let handler = await ArchiveHandler(app: app, viewModel: viewModel)
            do {
                try Task.checkCancellation()
                try await handler.move()
                // Both direct installation methods consume a local IPA; avoid needless compression.
                let package = try await handler.archive(forLocalInstallation: !sharing)
                try Task.checkCancellation()
                if sharing {
                    let exported = try await handler.moveToArchive(package, shouldOpen: !share)
                    await MainActor.run {
                        if share, let exported { UIActivityViewController.show(activityItems: [exported]) }
                        stopAudio()
                        dismiss()
                    }
                } else {
                    let proxy = await InstallationProxy(viewModel: viewModel)
                    try await proxy.install(at: package, suspend: app.identifier == ownBundle)
                    await MainActor.run { stopAudio() }
                }
                await handler.clean()
            } catch {
                await handler.clean()
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                await MainActor.run { fail(error) }
            }
        }
    }

    @MainActor private func fail(_ error: Error) {
        viewModel.status = .broken(error)
        errorMessage = error.localizedDescription
        showError = true
        stopAudio()
    }

    @MainActor private func stopAudio() {
        #if !targetEnvironment(macCatalyst)
        BackgroundAudioManager.shared.stop()
        #endif
    }
}
