//
//  ContentView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import CoreData
import NimbleViews

// MARK: - Minimalist Signing View with Instant Info.plist Auto-Sign on Import
struct LibraryView: View {
    @AppStorage("Feather.userTintColor") private var userTintHex: String = "#005BBB"
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject var sourcesViewModel = SourcesViewModel.shared
	
	@State private var _selectedInfoAppPresenting: AnyApp?
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _selectedInstallAppPresenting: AnyApp?
	@State private var _isImportingPresenting = false
	@State private var _isDownloadingPresenting = false
    @State private var _isAppStoreLinkPresenting = false
    @State private var _batchApps: [any AppInfoPresentable] = []
    @State private var _isBulkSigningPresenting = false
    @State private var _isImportingFiles = false
	@State private var _isSettingsPresenting = false
	@State private var _alertDownloadString: String = ""
	
	@State private var _signingInProgressUUIDs: Set<String> = []
	@State private var _oneClickStatusMessage: String? = nil
	
	@State private var _selectedAppUUIDs: Set<String> = []
	@State private var _editMode: EditMode = .inactive
	
	@State private var _searchText = ""
	@State private var _selectedScope: Scope = .all
	
	@Namespace private var _namespace
	
	private func filteredAndSortedApps<T>(from apps: FetchedResults<T>) -> [T] where T: NSManagedObject {
		let query = AppStoreBilingualEngine.normalize(_searchText)
		guard !query.isEmpty else { return Array(apps) }
		
		return apps.filter { item in
			let name = (item.value(forKey: "name") as? String) ?? ""
			let identifier = (item.value(forKey: "identifier") as? String) ?? ""
			let combined = AppStoreBilingualEngine.normalize("\(name) \(identifier)")
			
			if combined.contains(query) { return true }
			
			for group in AppStoreBilingualEngine.preNormalizedSynonymGroups {
				if group.contains(where: { combined.contains($0) }) &&
				   group.contains(where: { $0.contains(query) || query.contains($0) }) {
					return true
				}
			}
			return false
		}
	}
	
	private var _filteredSignedApps: [Signed] {
		filteredAndSortedApps(from: _signedApps)
	}
	
	private var _filteredImportedApps: [Imported] {
		filteredAndSortedApps(from: _importedApps)
	}
	
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
	) private var _signedApps: FetchedResults<Signed>
	
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)]
	) private var _importedApps: FetchedResults<Imported>
	
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
	) private var _certificates: FetchedResults<CertificatePair>
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>
	
	var body: some View {
		NBNavigationView("التوقيع") {
			NBListAdaptable {
                Section {
                    Button { _isAppStoreLinkPresenting = true } label: {
                        Label("رابط App Store", systemImage: "link.badge.plus")
                    }
                    if _filteredSignedApps.isEmpty && _filteredImportedApps.isEmpty {
                        Text("استورد ملف IPA لتعديل معلوماته وتوقيعه، أو افتح رابط التطبيق في App Store.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
				Section {
					Picker("العرض", selection: $_selectedScope) {
						ForEach(Scope.allCases, id: \.displayName) { scope in
							Text(scope.displayName).tag(scope)
						}
					}
					.pickerStyle(.segmented)
					.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
					.listRowBackground(Color.clear)
				}
				
				if let status = _oneClickStatusMessage {
					Section {
						HStack(spacing: 10) {
							ProgressView()
								.tint(Color(hex: userTintHex))
							Text(status)
								.font(.subheadline.weight(.semibold))
								.foregroundStyle(.primary)
							Spacer()
						}
						.padding(.vertical, 4)
					}
				}
				
				if !_filteredImportedApps.isEmpty && (_selectedScope == .all || _selectedScope == .imported) {
					NBSection("جاهزة للتوقيع اللحظي", secondary: _filteredImportedApps.count.description) {
						ForEach(_filteredImportedApps, id: \.uuid) { app in
							VStack(spacing: 8) {
								LibraryCellView(
									app: app,
									selectedInfoAppPresenting: $_selectedInfoAppPresenting,
									selectedSigningAppPresenting: $_selectedSigningAppPresenting,
									selectedInstallAppPresenting: $_selectedInstallAppPresenting,
									selectedAppUUIDs: $_selectedAppUUIDs
								)
								.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
								
								HStack(spacing: 10) {
									Button {
										_ultraFastSign(app: app)
									} label: {
										HStack(spacing: 6) {
											if _signingInProgressUUIDs.contains(app.uuid ?? "") {
												ProgressView()
													.tint(AppStoreTheme.contrastingText(forHex: userTintHex))
													.scaleEffect(0.8)
												Text("توقيع لحظي...")
													.font(.footnote.weight(.bold))
											} else {
												Image(systemName: "bolt.fill")
													.font(.footnote.weight(.bold))
												Text("توقيع وتثبيت لحظي")
													.font(.footnote.weight(.bold))
											}
										}
										.foregroundStyle(AppStoreTheme.contrastingText(forHex: userTintHex))
										.frame(maxWidth: .infinity)
										.padding(.vertical, 8)
										.background(
											Capsule(style: .continuous)
												.fill(Color(hex: userTintHex))
										)
									}
									.buttonStyle(.plain)
									.disabled(_signingInProgressUUIDs.contains(app.uuid ?? ""))
									
									Button {
										_selectedSigningAppPresenting = AnyApp(base: app)
									} label: {
										Image(systemName: "slider.horizontal.3")
											.font(.footnote.weight(.bold))
											.foregroundStyle(.secondary)
											.frame(width: 36, height: 32)
											.background(AppStoreTheme.controlSurface, in: Capsule())
									}
									.buttonStyle(.plain)
								}
							}
							.padding(.vertical, 2)
						}
					}
				}
				
				if !_filteredSignedApps.isEmpty && (_selectedScope == .all || _selectedScope == .signed) {
					NBSection("الموقعة والجاهزة للتثبيت", secondary: _filteredSignedApps.count.description) {
						ForEach(_filteredSignedApps, id: \.uuid) { app in
							LibraryCellView(
								app: app,
								selectedInfoAppPresenting: $_selectedInfoAppPresenting,
								selectedSigningAppPresenting: $_selectedSigningAppPresenting,
								selectedInstallAppPresenting: $_selectedInstallAppPresenting,
								selectedAppUUIDs: $_selectedAppUUIDs
							)
							.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
						}
					}
				}
			}
			.searchable(text: $_searchText, placement: .platform(), prompt: "بحث في التوقيع (عربي / إنجليزي)...")
			.scrollDismissesKeyboard(.interactively)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					EditButton()
				}
				
				ToolbarItemGroup(placement: .topBarTrailing) {
					if _editMode.isEditing {
                        Button {
                            _batchApps = _allSelectedApps
                            _isBulkSigningPresenting = true
                        } label: { Image(systemName: "signature") }
                        .accessibilityLabel("توقيع التطبيقات المحددة")
                        .disabled(_allSelectedApps.isEmpty || _isImportingFiles)
						Button(role: .destructive) {
							_bulkDeleteSelectedApps()
						} label: {
							Image(systemName: "trash")
						}
						.disabled(_selectedAppUUIDs.isEmpty)
					} else {
						Menu {
							Button("استيراد ملفات IPA", systemImage: "arrow.down.doc") {
								_isImportingPresenting = true
							}
                            Button("رابط App Store", systemImage: "link.badge.plus") {
                                _isAppStoreLinkPresenting = true
                            }
							Button("استيراد وتوقيع من رابط مباشر", systemImage: "link") {
								_isDownloadingPresenting = true
							}
						} label: {
							Image(systemName: "arrow.down.doc.fill")
								.font(.system(size: 18))
						}
						
						AppStoreAccountAppIconButton {
							_isSettingsPresenting = true
						}
					}
				}
			}
			.environment(\.editMode, $_editMode)
            .sheet(isPresented: $_isBulkSigningPresenting, onDismiss: { _batchApps = []; AutoSignPipelineManager.shared.presentNextReadyApp() }) {
                XSignBulkSigningView(apps: _batchApps)
            }
			.sheet(item: $_selectedInfoAppPresenting, onDismiss: { AutoSignPipelineManager.shared.presentNextReadyApp() }) { app in
				LibraryInfoView(app: app.base)
			}
			.sheet(item: $_selectedInstallAppPresenting, onDismiss: { AutoSignPipelineManager.shared.presentNextReadyApp() }) { app in
				InstallPreviewView(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)
			}
			.fullScreenCover(item: $_selectedSigningAppPresenting, onDismiss: { AutoSignPipelineManager.shared.presentNextReadyApp() }) { app in
				SigningView(app: app.base)
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
			}
			.sheet(isPresented: $_isImportingPresenting, onDismiss: { AutoSignPipelineManager.shared.presentNextReadyApp() }) {
				FileImporterRepresentableView(
					allowedContentTypes: [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						_instantImportAndAutoSign(urls: urls)
					}
				)
				.ignoresSafeArea()
			}
            .sheet(isPresented: $_isAppStoreLinkPresenting, onDismiss: { AutoSignPipelineManager.shared.presentNextReadyApp() }) {
                XSignAppStoreLinkView()
            }
			.sheet(isPresented: $_isSettingsPresenting, onDismiss: { AutoSignPipelineManager.shared.presentNextReadyApp() }) {
				AppStore2026SettingsPopup(sources: _sources, viewModel: sourcesViewModel)
			}
			.alert("استيراد وتوقيع من رابط مباشر", isPresented: $_isDownloadingPresenting) {
				TextField("https://example.com/app.ipa", text: $_alertDownloadString)
					.textInputAutocapitalization(.never)
				Button("إلغاء", role: .cancel) {
					_alertDownloadString = ""
				}
				Button("تنزيل وتوقيع") {
					if let url = URL(string: _alertDownloadString) {
						_ = downloadManager.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.installApp"))) { _ in
				if let latest = _signedApps.first {
					_selectedInstallAppPresenting = AnyApp(base: latest)
				}
			}
			.onChange(of: _editMode) { mode in
				if mode == .inactive {
					_selectedAppUUIDs.removeAll()
				}
			}
		}
		.environment(\.layoutDirection, .rightToLeft)
	}
	
	// MARK: - Direct Native Importer + Instant Auto-Sign
    private var _allSelectedApps: [any AppInfoPresentable] {
        let imported: [any AppInfoPresentable] = Array(_importedApps)
        let signed: [any AppInfoPresentable] = Array(_signedApps)
        let apps = imported + signed
        return apps.filter { _selectedAppUUIDs.contains($0.uuid ?? "") }
    }

    private func _instantImportAndAutoSign(urls: [URL]) {
        guard !urls.isEmpty, !_isImportingFiles else { return }
        _isImportingFiles = true
        Task { @MainActor in
            var imported: [any AppInfoPresentable] = []
            var failures: [String] = []
            defer { _isImportingFiles = false }
            for (index, url) in urls.enumerated() {
                _oneClickStatusMessage = "استيراد \(index + 1) من \(urls.count)…"
                let hasAccess = url.startAccessingSecurityScopedResource()
                let result: Result<String, Error> = await withCheckedContinuation { continuation in
                    FR.importPackageFile(url) { continuation.resume(returning: $0) }
                }
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                switch result {
                case .success(let uuid):
                    if let app = AutoSignPipelineManager.fetchImportedApps().first(where: { $0.uuid == uuid }) {
                        imported.append(app)
                    } else { failures.append(url.lastPathComponent + ": تعذّر العثور على التطبيق المستورد.") }
                case .failure(let error): failures.append(url.lastPathComponent + ": " + error.localizedDescription)
                }
            }
            _oneClickStatusMessage = nil
            let presentResult = {
                if urls.count == 1, let app = imported.first { _ultraFastSign(app: app) }
                else if !imported.isEmpty { _batchApps = imported; _isBulkSigningPresenting = true }
            }
            if !failures.isEmpty {
                UIAlertController.showAlertWithOk(title: "تعذّر استيراد بعض الملفات", message: failures.prefix(5).joined(separator: "\n"), action: presentResult)
            } else { presentResult() }
        }
    }

	// MARK: - Ultra-Fast Instant Signing via ZSign
	private func _ultraFastSign(app: AppInfoPresentable) {
		let selectedCertIndex = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		let activeCert: CertificatePair? = {
			if _certificates.indices.contains(selectedCertIndex) {
				return _certificates[selectedCertIndex]
			}
			return _certificates.first
		}()
		
		guard let cert = activeCert else {
			_oneClickStatusMessage = nil
			UIAlertController.showAlertWithOk(
				title: "لا توجد شهادة",
				message: "يرجى إضافة شهادة توقيع أولاً من أيقونة الحساب في الأعلى."
			)
			return
		}
		
		let uuid = app.uuid ?? ""
		UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
		_signingInProgressUUIDs.insert(uuid)
		_oneClickStatusMessage = "توقيع لحظي لـ \(app.name ?? "التطبيق")..."
		
		let options = OptionsManager.shared.options
		
		FR.signPackageFileWithResult(
			app,
			using: options,
			icon: nil,
			certificate: cert
		) { result in
			DispatchQueue.main.async {
				_signingInProgressUUIDs.remove(uuid)
				_oneClickStatusMessage = nil
				
                switch result {
                case .failure(let error):
					UINotificationFeedbackGenerator().notificationOccurred(.error)
					UIAlertController.showAlertWithOk(
						title: "فشل التوقيع",
						message: error.localizedDescription
					)
                case .success(let uuid):
					UINotificationFeedbackGenerator().notificationOccurred(.success)
					if let newlySigned = AutoSignPipelineManager.fetchSignedApps().first(where: { $0.uuid == uuid }) {
						_selectedInstallAppPresenting = AnyApp(base: newlySigned)
					}
				}
			}
		}
	}
	
    private func _bulkDeleteSelectedApps() {
        for app in _allSelectedApps { Storage.shared.deleteApp(for: app) }
        _selectedAppUUIDs.removeAll()
    }

	enum Scope: CaseIterable {
		case all
		case imported
		case signed
		
		var displayName: String {
			switch self {
			case .all:      return "الكل"
			case .imported: return "جاهزة للتوقيع"
			case .signed:   return "الموقعة"
			}
		}
	}
}
