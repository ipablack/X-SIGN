//
//  SigningView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import UniformTypeIdentifiers
import NimbleViews

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@ObservedObject private var policy = XSignSecurityEnforcer.shared
    @StateObject private var _optionsManager = OptionsManager.shared
    @AppStorage("Feather.userTintColor") private var userTintHex = "#005BBB"

	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isSigning = false
    @State private var signingFailureMessage: String?
    @State private var _showCertificateSetup = false
    @State private var _resumeAfterCertificateSetup = false
	@State var appIcon: UIImage?

	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .easeInOut(duration: 0.2)
	) private var certificates: FetchedResults<CertificatePair>

	private func _selectedCert() -> CertificatePair? {
        Storage.shared.activeSigningCertificate(preferredIndex: _temporaryCertificate)
	}

	var app: AppInfoPresentable

	init(app: AppInfoPresentable) {
		self.app = app
		let storedCert = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}

	// MARK: Body
	var body: some View {
        NBNavigationView("توقيع التطبيق", displayMode: .inline) {
            ScrollView {
                VStack(spacing: 16) {
                    appSummary
                    _cert()
                    _customizationOptions(for: app)
                    _customizationProperties(for: app)
                }
                .frame(maxWidth: 620)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .background(AppStoreTheme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { signingFooter }
            .toolbar {
                NBToolbarButton(role: .dismiss)
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .navigationBarTrailing
				) {
					_temporaryOptions = OptionsManager.shared.options
					appIcon = nil
				}
			}
            .sheet(isPresented: $_showCertificateSetup, onDismiss: {
                let resume = _resumeAfterCertificateSetup
                _resumeAfterCertificateSetup = false
                _temporaryCertificate = UserDefaults.standard.integer(forKey: "feather.selectedCert")
                if resume && _selectedCert() != nil { _start() }
            }) { CertificatesAddView() }
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
				.ignoresSafeArea()
			}
            .sheet(isPresented: $_isImagePickerPresenting) {
                XSignPhotoPicker { image in appIcon=image?.resizeToSquare() }
            }
			.disabled(_isSigning)
			.animation(.easeInOut(duration: 0.25), value: _isSigning)
		}
		.onAppear {
			// ppq protection
			if
				_optionsManager.options.ppqProtection,
				let identifier = app.identifier,
				let cert = _selectedCert(),
				cert.ppQCheck
			{
				_temporaryOptions.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
			}

			if
				let currentBundleId = app.identifier,
				let newBundleId = _temporaryOptions.identifiers[currentBundleId]
			{
				_temporaryOptions.appIdentifier = newBundleId
			}

			if
				let currentName = app.name,
				let newName = _temporaryOptions.displayNames[currentName]
			{
				_temporaryOptions.appName = newName
			}
		}
        .environment(\.layoutDirection, .rightToLeft)
	}
}

extension SigningView {
    private var appSummary: some View {
        HStack(spacing: 14) {
            if let appIcon {
                Image(uiImage: appIcon).resizable().scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                FRAppIconView(app: app, size: 64)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(_temporaryOptions.appName ?? app.name ?? "التطبيق")
                    .font(.title3.bold()).lineLimit(2)
                if let bundle = _temporaryOptions.appIdentifier ?? app.identifier {
                    Text(bundle).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                }
                if let version = _temporaryOptions.appVersion ?? app.version {
                    Text("الإصدار \(version)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .xsignSurface(radius: 22)
    }

    private var signingFooter: some View {
        VStack(spacing: 10) {
            if let message = signingFailureMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).xsignSurface(radius: 14)
            }
            Button(action: _start) {
                HStack(spacing: 8) {
                    if _isSigning { ProgressView().tint(AppStoreTheme.contrastingText(forHex: userTintHex)) }
                    else { Image(systemName: "signature") }
                    Text(_isSigning ? "جاري التوقيع…" : "ابدأ التوقيع").font(.headline)
                }
                .foregroundStyle(AppStoreTheme.contrastingText(forHex: userTintHex))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(_isSigning)
        }
        .frame(maxWidth: 620)
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(AppStoreTheme.background.ignoresSafeArea(edges: .bottom))
    }

    private func signingSection<Content: View>(_ title: String, icon: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(Color.accentColor)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .xsignSurface()
    }

	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		signingSection("معلومات التطبيق", icon: "square.and.pencil") {
			Menu {
				Button { _isAltPickerPresenting = true } label: { Label(.localized("Select Alternative Icon"), systemImage: "app.dashed") }
				Button { _isFilePickerPresenting = true } label: { Label(.localized("Choose from Files"), systemImage: "folder") }
				Button { _isImagePickerPresenting = true } label: { Label(.localized("Choose from Photos"), systemImage: "photo") }
            } label: {
                Label("تغيير الأيقونة", systemImage: "photo")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(policy.locks.lock_icon_change ?? true)
            Divider()

            _infoCell(.localized("Name"), desc: _temporaryOptions.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: _temporaryOptions.appName ?? (app.name ?? ""),
					bindingValue: $_temporaryOptions.appName,
                    field: .name, originalValue: app.name
                )
            }.disabled(!policy.locks.allowsAppMetadataEditing)
			_infoCell(.localized("Identifier"), desc: _temporaryOptions.appIdentifier ?? app.identifier) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: _temporaryOptions.appIdentifier ?? (app.identifier ?? ""),
					bindingValue: $_temporaryOptions.appIdentifier,
                    field: .bundleIdentifier, originalValue: app.identifier
                )
            }.disabled(!policy.locks.allowsAppMetadataEditing)

			_cloneRow(for: app).disabled(!policy.locks.allowsAppMetadataEditing)

			_infoCell(.localized("Version"), desc: _temporaryOptions.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: _temporaryOptions.appVersion ?? (app.version ?? ""),
					bindingValue: $_temporaryOptions.appVersion,
                    field: .version, originalValue: app.version
				)
			}.disabled(!policy.locks.allowsAppMetadataEditing)
		}
	}

	@ViewBuilder
	private func _cloneRow(for app: AppInfoPresentable) -> some View {
		let baseID = app.identifier ?? ""
		let currentID = _temporaryOptions.appIdentifier ?? baseID
		let canRemoveClone = currentID.hasSuffix("1") && currentID.count > baseID.count

		HStack(spacing: 12) {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text("الاستنساخ")
						.font(.body)
					Text("إضافة أو إزالة (1) من البندل لتكرار التطبيق")
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
			} icon: {
				Image(systemName: "plus.square.on.square.fill")
					.foregroundStyle(Color.accentColor)
					.font(.system(size: 18, weight: .semibold))
			}

			Spacer()

			HStack(spacing: 0) {
				// زر الناقص (-) لعكس العملية
				Button {
					guard canRemoveClone else { return }
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
					withAnimation(.easeInOut(duration: 0.2)) {
						var updated = currentID
						updated.removeLast()
						_temporaryOptions.appIdentifier = updated
					}
				} label: {
					Image(systemName: "minus")
						.font(.system(size: 14, weight: .bold))
						.frame(width: 38, height: 32)
						.foregroundStyle(canRemoveClone ? Color.primary : Color.secondary.opacity(0.35))
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.disabled(!canRemoveClone)

				Divider()
					.frame(height: 18)

				// زر الزائد (+) لإضافة 1 إلى البندل
				Button {
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
					withAnimation(.easeInOut(duration: 0.2)) {
						_temporaryOptions.appIdentifier = currentID + "1"
					}
				} label: {
					Image(systemName: "plus")
						.font(.system(size: 14, weight: .bold))
						.frame(width: 38, height: 32)
						.foregroundStyle(Color.accentColor)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
			}
			.background(
				RoundedRectangle(cornerRadius: 9, style: .continuous)
					.fill(Color(UIColor.secondarySystemFill))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 9, style: .continuous)
					.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
			)
		}
		.padding(.vertical, 2)
	}

	@ViewBuilder
	private func _cert() -> some View {
		signingSection("شهادة التوقيع", icon: "checkmark.seal") {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					CertificatesCellView(
						cert: cert
					)
				}
			} else {
                Button("إضافة شهادة") { _showCertificateSetup = true }
			}
		}
	}

	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		signingSection("إعدادات متقدمة", icon: "slider.horizontal.3") {
			DisclosureGroup(.localized("Modify")) {
				NavigationLink(.localized("Existing Dylibs")) {
					SigningDylibView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}

				NavigationLink(.localized("Frameworks & PlugIns")) {
					SigningFrameworksView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}

				NavigationLink(.localized("Entitlements") + " (BETA)") {
					SigningEntitlementsView(
						bindingValue: $_temporaryOptions.appEntitlementsFile
					)
				}

				NavigationLink(.localized("Tweaks")) {
					SigningTweaksView(
						options: $_temporaryOptions
                    )
                }.disabled(policy.locks.lock_dylib_injection ?? true)
			}

			NavigationLink(.localized("Properties")) {
				Form { SigningOptionsView(
					options: $_temporaryOptions,
					temporaryOptions: _optionsManager.options
				)}
				.xsignListBackground()
				.navigationTitle(.localized("Properties"))
			}
		}
	}

	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(desc ?? .localized("Unknown")).font(.subheadline.weight(.medium)).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
		}
	}
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _start() {
        guard !_isSigning else { return }
        signingFailureMessage = nil
        if policy.locks.allowsAppMetadataEditing {
            do {
                _ = try XSignAppMetadata.validated(_temporaryOptions.appName, field: .name, original: app.name)
                _ = try XSignAppMetadata.validated(_temporaryOptions.appIdentifier, field: .bundleIdentifier, original: app.identifier)
                _ = try XSignAppMetadata.validated(_temporaryOptions.appVersion, field: .version, original: app.version)
            } catch {
                signingFailureMessage = error.localizedDescription
                return
            }
        }
		guard
			_selectedCert() != nil || _temporaryOptions.signingOption != .default
		else {
            _resumeAfterCertificateSetup = true
            _showCertificateSetup = true
			return
		}

		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()
		_isSigning = true

        FR.signPackageFileWithResult(app, using: _temporaryOptions, icon: appIcon, certificate: _selectedCert()) { result in
            _isSigning = false
            switch result {
            case .failure(let error):
                signingFailureMessage = error.localizedDescription
            case .success(let uuid):
                if _temporaryOptions.post_deleteAppAfterSigned, !app.isSigned {
                    Storage.shared.deleteApp(for: app)
                }
                if _temporaryOptions.post_installAppAfterSigned,
                   let signed = AutoSignPipelineManager.fetchSignedApp(uuid: uuid) {
                    XSignInstallation.shared.install(signed, afterDismissal: true)
                }
                dismiss()
            }
        }
	}
}
