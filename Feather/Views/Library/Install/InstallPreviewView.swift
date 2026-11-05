//
//  InstallPreview.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import OSLog

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss

	@AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	@State private var _isWebviewPresenting = false
	@State private var progressTask: Task<Void, Never>?
    @State private var installLinkTask: Task<Void, Never>?
    @State private var didRequestInstallation = false
    @State private var didStartPreparation = false
	
	var app: AppInfoPresentable
	@StateObject var viewModel: InstallerStatusViewModel
	@StateObject var installer: ServerInstaller
	
	@State var isSharing: Bool
	
	init(app: AppInfoPresentable, isSharing: Bool = false) {
		self.app = app
		self.isSharing = isSharing
		let viewModel = InstallerStatusViewModel(isIdevice: UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1)
		self._viewModel = StateObject(wrappedValue: viewModel)
		self._installer = StateObject(wrappedValue: ServerInstaller(app: app, viewModel: viewModel))
	}
	
	// MARK: Body
	var body: some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		ZStack {
			InstallProgressView(app: app, viewModel: viewModel)
			_status()
			_button()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(cornerRadius)
		.padding()
		.sheet(isPresented: $_isWebviewPresenting) {
			SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
		}
		.onReceive(viewModel.$status) { newStatus in
			if _installationMethod == 0 {
                if case .ready = newStatus, !didRequestInstallation {
                    didRequestInstallation = true
                    installLinkTask = Task { @MainActor in
                        let branded = await installer.verifiedBrandedInstallLink()
                        guard !Task.isCancelled else { return }
                        if let branded {
                            _ = await UIApplication.shared.open(branded)
                        } else if _serverMethod == 0, let local = URL(string: installer.iTunesLink) {
                            // Static-only Hosting has no dynamic manifest. Keep the existing
                            // installation method working until the optional endpoint is deployed.
                            _ = await UIApplication.shared.open(local)
                        } else if _serverMethod == 1 {
                            _isWebviewPresenting = true
                        }
                    }
                }

				if case .sendingPayload = newStatus, _serverMethod == 1 {
					_isWebviewPresenting = false
				}
				
				if case .installing = newStatus {
					if progressTask == nil, let bundleID = app.identifier, !bundleID.isEmpty {
						progressTask = startInstallProgressPolling(
							bundleID: bundleID,
							viewModel: viewModel
						)
					}
				}
				
				switch newStatus {
				case .completed, .broken(_):
					progressTask?.cancel()
					progressTask = nil
					#if !targetEnvironment(macCatalyst)
					BackgroundAudioManager.shared.stop()
					#endif
				default:
					break
				}
			}
		}
		.onAppear(perform: _install)
		
		#if !targetEnvironment(macCatalyst)
		.onAppear {
			BackgroundAudioManager.shared.start()
		}
		#endif
		
        .onDisappear {
            installLinkTask?.cancel()
            installLinkTask = nil
            progressTask?.cancel()
			progressTask = nil
			
			#if !targetEnvironment(macCatalyst)
			BackgroundAudioManager.shared.stop()
			#endif
		}
	}
	
	@ViewBuilder
	private func _status() -> some View {
		Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
			.padding()
			.labelStyle(.titleAndIcon)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
			.animation(.smooth, value: viewModel.statusImage)
	}
	
	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if viewModel.isCompleted {
				Button {
					UIApplication.openApp(with: app.identifier ?? "")
				} label: {
					NBButton("Open", systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
	}
	
	private func _install() {
        guard !didStartPreparation else { return }
        if !isSharing && (app.identifier ?? "").isEmpty {
            viewModel.status = .broken(NSError(domain: "XSign.Installation", code: 2, userInfo: [NSLocalizedDescriptionKey: "معرّف التطبيق مفقود. راجع معلومات التطبيق ثم أعد توقيعه."]))
            return
        }
        didStartPreparation = true
		guard isSharing || app.identifier != Bundle.main.bundleIdentifier || _installationMethod == 1 else {
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			)
			return
		}
				
        let sharing = isSharing
        let method = _installationMethod
        let useShareSheet = _useShareSheet
        let currentBundleID = Bundle.main.bundleIdentifier ?? ""
        Task.detached(priority: .userInitiated) {
            do {
                let handler = await ArchiveHandler(app: app, viewModel: viewModel)
                try await handler.move()
                let packageURL = try await handler.archive(forLocalInstallation: !sharing && method == 0)
                if !sharing {
                    if method == 0 {
                        // IPA is streamed directly from this device; no upload/re-download round trip.
                        try installer.start()
                        await MainActor.run {
                            installer.packageUrl = packageURL
                            viewModel.status = .ready
                        }
                        // The .installing status publisher owns progress polling.
                        // Starting a second poller here races that publisher.
                    } else if method == 1 {
                        let proxy = await InstallationProxy(viewModel: viewModel)
                        try await proxy.install(at: packageURL, suspend: app.identifier == currentBundleID)
                    }
                } else {
                    let package = try await handler.moveToArchive(packageURL, shouldOpen: !useShareSheet)
                    await MainActor.run {
                        dismiss()
                        if useShareSheet, let package {
                            UIActivityViewController.show(activityItems: [package])
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    progressTask?.cancel()
                    progressTask = nil
                    UIAlertController.showAlertWithOk(
                        title: .localized("Install"), message: String(describing: error), action: {
                            HeartbeatManager.shared.start(true)
                            dismiss()
                        }
                    )
                }
            }
        }

	}
	
	private func startInstallProgressPolling(
		bundleID: String,
		viewModel: InstallerStatusViewModel
	) -> Task<Void, Never> {

		Task.detached(priority: .background) {
			var hasStarted = false

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
				}

				let progress = hasStarted
					? Self._normalizeInstallProgress(rawProgress)
					: 0.0

				Logger.misc.info("Install progress for \(bundleID): \(progress)")

				await MainActor.run {
					viewModel.installProgress = progress
				}

				if hasStarted && rawProgress == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(Void()))
					}
					break
				}

				do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break } // 2 polls/s; no busy loop
			}
		}
	}

	private nonisolated static func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
	}
}
