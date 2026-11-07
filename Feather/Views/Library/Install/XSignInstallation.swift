import SwiftUI
import IDeviceSwift
import NimbleExtensions

/// Serializes handoffs to the iOS installer and owns the temporary IPA until delivery ends.
@MainActor
final class XSignInstallation: ObservableObject {
    static let shared = XSignInstallation()

    private struct Request {
        let app: AppInfoPresentable
        let id: String
        let afterDismissal: Bool
    }

    @Published private(set) var status: String?
    @Published private(set) var isWorking = false
    private var pending: [Request] = []
    private var activeID: String?
    private var operation: Task<Void, Never>?

    func install(_ app: AppInfoPresentable, afterDismissal: Bool = false) {
        if let reason = XSignRemoteManager.shared.blockingReason {
            if !isWorking { status = reason }
            return
        }
        guard let id = app.uuid, activeID != id, !pending.contains(where: { $0.id == id }) else { return }
        pending.append(Request(app: app, id: id, afterDismissal: afterDismissal))
        resumeIfPossible()
    }

    func resumeIfPossible() {
        guard operation == nil, !pending.isEmpty, UIApplication.shared.applicationState == .active,
              XSignRemoteManager.shared.blockingReason == nil else { return }
        let request = pending.removeFirst()
        let afterDismissal = request.afterDismissal
        activeID = request.id
        isWorking = true
        status = "تجهيز \(request.app.name ?? "التطبيق") للتثبيت…"

        operation = Task { @MainActor in
            let handler = ArchiveHandler(app: request.app, viewModel: InstallerStatusViewModel(isIdevice: false))
            #if !targetEnvironment(macCatalyst)
            BackgroundAudioManager.shared.start()
            #endif
            defer {
                #if !targetEnvironment(macCatalyst)
                BackgroundAudioManager.shared.stop()
                #endif
                handler.clean()
                operation = nil
                activeID = nil
                isWorking = false
                resumeIfPossible()
            }

            do {
                let metadata = try await handler.move()
                try Task.checkCancellation()
                let package = try await handler.archive()
                try Task.checkCancellation()
                let installer = XSignOTAInstaller()
                try await installer.install(package: package, bundleIdentifier: metadata.identifier,
                    version: metadata.version, title: metadata.title, update: { [weak self] stage in
                        self?.show(stage)
                    }, open: { link in
                        // Signing may finish as the app goes inactive or a sheet is presented.
                        while UIApplication.shared.applicationState != .active ||
                                (afterDismissal && Self.isPresentingSheet) {
                            guard XSignRemoteManager.shared.blockingReason == nil, !Task.isCancelled else { return false }
                            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return false }
                        }
                        guard XSignRemoteManager.shared.blockingReason == nil, !Task.isCancelled else { return false }
                        return await withCheckedContinuation { continuation in
                            UIApplication.shared.open(link, options: [:]) { continuation.resume(returning: $0) }
                        }
                    })
                status = nil
            } catch {
                status = Task.isCancelled ? nil : (error as? XSignOTAError)?.localizedDescription
                    ?? "تعذّر تجهيز التثبيت. جرّب تثبيت النسخة من قسم التوقيع."
            }
        }
    }

    func cancelOrDismiss() {
        if isWorking { operation?.cancel() }
        else { status = nil }
    }

    func applyPolicy() {
        if XSignRemoteManager.shared.blockingReason != nil {
            pending.removeAll()
            operation?.cancel()
            status = nil
        } else {
            resumeIfPossible()
        }
    }

    private static var isPresentingSheet: Bool {
        UIApplication.topViewController()?.view.window?.rootViewController?.presentedViewController != nil
    }

    private func show(_ stage: XSignOTAInstaller.Stage) {
        switch stage {
        case .preparingTLS, .preparingDomain:
            status = "جاري تجهيز طلب التثبيت…"
        case .waitingForSystem:
            status = "وافق على طلب التثبيت من iOS."
        case .delivering:
            status = "جاري إرسال التطبيق إلى iOS…"
        case .delivered:
            status = nil
        }
    }
}

struct XSignInstallationStatus: View {
    @ObservedObject private var installation = XSignInstallation.shared

    var body: some View {
        if let status = installation.status {
            HStack(spacing: 10) {
                if installation.isWorking { ProgressView().controlSize(.small) }
                Text(status).font(.footnote.weight(.medium))
                Spacer(minLength: 4)
                Button { installation.cancelOrDismiss() } label: {
                    Image(systemName: "xmark").frame(width: 38, height: 40)
                }.buttonStyle(.plain)
                    .accessibilityLabel(installation.isWorking ? "إلغاء التثبيت" : "إخفاء الرسالة")
            }
            .padding(.leading, 12)
            .xsignSurface(radius: 14)
            .accessibilityElement(children: .contain)
        }
    }
}
