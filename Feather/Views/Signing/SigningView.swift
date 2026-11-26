//
//  SigningView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import UniformTypeIdentifiers
import NimbleViews
import ImageIO

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@ObservedObject private var policy = XSignSecurityEnforcer.shared
    @StateObject private var _optionsManager = OptionsManager.shared

	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
    @State private var isLoadingIcon = false
    @State private var isImportingTweaks = false
    @State private var showsSigningLibraries = false
    @State private var managedLibraryFiles: [URL: XSignSigningLibrary] = [:]
    @State private var isRefreshingPolicy = false
    @State private var editedBundleID = false
    @State private var cloneIdentifier: String?
    @State private var bundleBeforeClone: String?
    @State private var bundleWasEdited = false
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var policyStatus: String?
    @FocusState private var focusedMetadataField: String?
	@State private var _isSigning = false
    @State private var didLoadAppDefaults = false
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
        NBNavigationView(xsignText("تجهيز التطبيق"), displayMode: .inline) {
            ScrollView {
                VStack(spacing: 16) {
                    appSummary
                    if !restrictedEdits.isEmpty || policyStatus != nil { customizationAccess }
                    if _temporaryOptions.signingOption == .default { _cert() }
                    _customizationOptions(for: app)
                    _customizationProperties(for: app)
                    if _temporaryOptions.signingOption == .default { installPreference }
                    signingReview
                }
                .frame(maxWidth: 620)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .xsignPageBackground()
            .xsignDismissKeyboardOnScroll()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if focusedMetadataField == nil { signingFooter }
            }
            .toolbar {
                NBToolbarButton(role: .dismiss)
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .navigationBarTrailing,
                    isDisabled: _isSigning || isLoadingIcon || isImportingTweaks
				) {
                    SigningTweaksView.discardStagedFiles(_temporaryOptions.injectionFiles)
                    managedLibraryFiles.removeAll()
                    signingFailureMessage = nil
                    editedBundleID = false
                    cloneIdentifier = nil
                    focusedMetadataField = nil
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
            .sheet(isPresented: $showsSigningLibraries) {
                XSignSigningLibraryPicker(bundle: app.identifier ?? "", files: $_temporaryOptions.injectionFiles,
                    managedFiles: $managedLibraryFiles, isImporting: $isImportingTweaks)
            }
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
            .fileImporter(isPresented: $_isFilePickerPresenting, allowedContentTypes: [.image], onCompletion: importIcon)
            .sheet(isPresented: $_isImagePickerPresenting) {
                XSignPhotoPicker { image in
                    guard policy.locks.allowsIconChanges else { return }
                    guard let image else { signingFailureMessage = "تعذّر فتح الصورة المختارة."; return }
                    signingFailureMessage = nil
                    appIcon = image.resizeToSquare()
                }
            }
			.disabled(_isSigning)
			.animation(.easeInOut(duration: 0.25), value: _isSigning)
		}
        .overlay {
            if _isSigning { signingActivity }
        }
        .interactiveDismissDisabled(_isSigning)
		.onAppear {
            guard !didLoadAppDefaults else { return }
            didLoadAppDefaults = true
            guard policy.locks.allowsAppMetadataEditing else { return }
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

	}
}

extension SigningView {
    private var installsAfterSigning: Bool {
        _temporaryOptions.signingOption == .default && _temporaryOptions.post_installAppAfterSigned
    }

    private var restrictedEdits: [String] {
        let locks = policy.locks
        return [
            locks.allowsAppMetadataEditing ? nil : "الاسم والبندل والإصدار",
            locks.allowsIconChanges ? nil : "الأيقونة",
            locks.allowsLibraryInjection ? nil : "إضافة المكتبات والفريموركات"
        ].compactMap { $0 }
    }

    private var customizationAccess: some View {
        signingSection("صلاحيات التخصيص", icon: restrictedEdits.isEmpty ? "lock.open" : "lock") {
            if !restrictedEdits.isEmpty {
                Text(String(format: xsignText("إعدادات المتجر تقفل: %@"),
                            restrictedEdits.map { xsignText($0) }.joined(separator: XSignLanguage.current == .english ? ", " : "، ")))
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    guard !isRefreshingPolicy else { return }
                    isRefreshingPolicy = true
                    Task { @MainActor in
                        let remote = XSignRemoteManager.shared
                        await remote.fetchRemoteConfig(force: true)
                        policyStatus = remote.remoteSyncStatus
                        isRefreshingPolicy = false
                    }
                } label: {
                    if isRefreshingPolicy { ProgressView() }
                    else { Label("تحديث الصلاحيات", systemImage: "arrow.clockwise") }
                }
                .xsignGlassButton()
                .disabled(isRefreshingPolicy)
            }
            if let policyStatus {
                Text(xsignText(policyStatus)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var actionTitle: String {
        if _temporaryOptions.signingOption == .onlyModify {
            return _isSigning ? "جاري الحفظ…" : "حفظ التعديلات"
        }
        if _isSigning { return "جاري التوقيع…" }
        return installsAfterSigning ? "توقيع وتثبيت" : "توقيع وحفظ"
    }

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
                Text(_temporaryOptions.appName ?? app.name ?? xsignText("التطبيق"))
                    .font(.title3.bold()).lineLimit(2)
                if let bundle = _temporaryOptions.appIdentifier ?? app.identifier {
                    Text(bundle).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                }
                if let version = _temporaryOptions.appVersion ?? app.version {
                    Text("الإصدار \(version)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(AppStoreTheme.controlSurface, in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .xsignSurface(radius: 22)
    }

    private var installPreference: some View {
        signingSection("بعد التوقيع", icon: "arrow.down.app") {
            Toggle(isOn: $_temporaryOptions.post_installAppAfterSigned) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("التثبيت على هذا الجهاز").font(.subheadline.weight(.semibold))
                    Text("يفتح طلب التثبيت من iOS بعد نجاح التوقيع.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var signingReview: some View {
        signingSection("مراجعة النسخة", icon: "checklist") {
            HStack { Text("الإضافات"); Spacer(); Text("\(_temporaryOptions.injectionFiles.count)").foregroundStyle(.secondary) }
            HStack { Text("النتيجة"); Spacer(); Text(xsignText(actionTitle)).foregroundStyle(.secondary) }
            if !_temporaryOptions.removeFiles.isEmpty {
                Text("سيُحذف \(_temporaryOptions.removeFiles.count) عناصر من النسخة المعدلة.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var signingActivity: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 18) {
                FRAppIconView(app: app, size: 72)
                Text(xsignText(actionTitle)).font(.title3.bold())
                ProgressView().scaleEffect(1.2)
                Text(xsignText(installsAfterSigning ? "سيظهر طلب iOS عند جاهزية التثبيت." : "تظهر النسخة الجاهزة في المكتبة بعد اكتمال العملية."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(28).frame(maxWidth: 340).xsignSurface(radius: 26).padding(24)
        }

        .accessibilityAddTraits(.isModal)
    }

    private var signingFooter: some View {
        VStack(spacing: 10) {
            if let message = signingFailureMessage {
                Label(xsignText(message), systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).xsignSurface(radius: 14)
            }
            Button(action: _start) {
                HStack(spacing: 8) {
                    if _isSigning { ProgressView().controlSize(.small) }
                    else { Image(systemName: "signature") }
                    Text(xsignText(actionTitle)).font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .controlSize(.large)
            .xsignProminentGlassButton()
            .disabled(_isSigning || isLoadingIcon || isImportingTweaks)
        }
        .padding(12)
        .xsignSurface(radius: 22)
        .frame(maxWidth: 620)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(AppStoreTheme.background)
    }

    private func signingSection<Content: View>(_ title: String, icon: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(xsignText(title), systemImage: icon).font(.headline).foregroundStyle(Color.accentColor)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .xsignSurface()
    }

	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		signingSection("تخصيص النسخة", icon: "square.and.pencil") {
			Menu {
				Button { _isAltPickerPresenting = true } label: { Label(.localized("Select Alternative Icon"), systemImage: "app.dashed") }
				Button { _isFilePickerPresenting = true } label: { Label(.localized("Choose from Files"), systemImage: "folder") }
				Button { _isImagePickerPresenting = true } label: { Label(.localized("Choose from Photos"), systemImage: "photo") }
                if appIcon != nil {
                    Button("استعادة الأيقونة الأصلية", role: .destructive) { appIcon = nil }
                }
            } label: {
                Label("تغيير الأيقونة", systemImage: "photo")
                    .font(.subheadline.weight(.semibold))
            }
            .xsignGlassButton()
            .disabled(isLoadingIcon || !policy.locks.allowsIconChanges)
            Divider()

            VStack(spacing: 14) {
                metadataField("اسم التطبيق", original: app.name, field: .name,
                              value: Binding(get: { _temporaryOptions.appName }, set: { name in
                    if name != nil && _temporaryOptions.appName == nil {
                        _temporaryOptions.changeLanguageFilesForCustomDisplayName = true
                    }
                    _temporaryOptions.appName = name
                }))
                metadataField("معرّف الحزمة (Bundle ID)", original: app.identifier, field: .bundleIdentifier,
                              value: Binding(get: { _temporaryOptions.appIdentifier }, set: { value in
                                  cloneIdentifier = nil
                                  editedBundleID = value != nil
                                  _temporaryOptions.appIdentifier = value
                              }))
                metadataField("الإصدار", original: app.version, field: .version, value: $_temporaryOptions.appVersion)
                _cloneRow(for: app)
            }
            .disabled(!policy.locks.allowsAppMetadataEditing)
		}
	}

    private func _cloneRow(for app: AppInfoPresentable) -> some View {
        let isClone = cloneIdentifier != nil && _temporaryOptions.appIdentifier == cloneIdentifier
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isClone {
                    _temporaryOptions.appIdentifier = bundleBeforeClone
                    editedBundleID = bundleWasEdited
                    cloneIdentifier = nil
                } else if let original = _temporaryOptions.appIdentifier ?? app.identifier,
                          let identifier = XSignAppMetadata.cloneIdentifier(from: original) {
                    bundleBeforeClone = _temporaryOptions.appIdentifier
                    bundleWasEdited = editedBundleID
                    cloneIdentifier = identifier
                    _temporaryOptions.appIdentifier = identifier
                    editedBundleID = true
                }
            } label: {
                Label(xsignText(isClone ? "إلغاء الاستنساخ" : "إنشاء نسخة مستقلة"),
                      systemImage: isClone ? "arrow.uturn.backward" : "plus.square.on.square")
            }
            .xsignGlassButton()
            .disabled((_temporaryOptions.appIdentifier ?? app.identifier ?? "").isEmpty)
            Text("تُثبّت النسخة بمعرّف حزمة جديد بجانب التطبيق الأصلي.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
                Button("إضافة شهادة") { _showCertificateSetup = true }.buttonStyle(.bordered)
			}
            Text("اختر الشهادة التي ستستخدم لتوقيع هذه النسخة.")
                .font(.footnote).foregroundStyle(.secondary)
		}
	}

	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		signingSection("الإضافات والخصائص", icon: "slider.horizontal.3") {
            Button {
                showsSigningLibraries = true
            } label: {
                Label("دايلبات جاهزة", systemImage: "shippingbox.fill")
            }
            .disabled(isImportingTweaks || !policy.locks.allowsLibraryInjection)
            NavigationLink {
                SigningTweaksView(options: $_temporaryOptions, isImporting: $isImportingTweaks)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Label("إضافة دايليب وفريمورك", systemImage: "shippingbox")
                    Text(!policy.locks.allowsLibraryInjection
                        ? "مقفلة من إدارة المتجر"
                        : "\(_temporaryOptions.injectionFiles.count) ملفات مختارة")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            NavigationLink {
                XSignPackageContentsView(app: app)
            } label: {
                Label(xsignText("محتويات الحزمة"), systemImage: "doc.text.magnifyingglass")
            }
			DisclosureGroup("إدارة المكتبات والإضافات الموجودة") {
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

				NavigationLink(xsignText("Entitlements")) {
					SigningEntitlementsView(
						bindingValue: $_temporaryOptions.appEntitlementsFile
					)
				}

            }


            Toggle(xsignText("Remove URL Scheme"), isOn: $_temporaryOptions.removeURLScheme)
            Toggle(xsignText("iPad Fullscreen"), isOn: $_temporaryOptions.ipadFullscreen)
            if _temporaryOptions.ipadFullscreen {
                Text(xsignText("يعتمد ملء الشاشة على إصدار iPadOS وطريقة عرض النوافذ."))
                    .font(.caption).foregroundStyle(.secondary)
            }
			NavigationLink {
				Form {
                    Section {
                        appSummary
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } footer: {
                        Text("تُطبّق هذه الخصائص على النسخة التي تجهّزها الآن.")
                    }
                    SigningOptionsView(options: $_temporaryOptions, temporaryOptions: _optionsManager.options)
                }
				.xsignListBackground()
				.navigationTitle("خصائص التطبيق")
            } label: {
                Label("خصائص التطبيق", systemImage: "slider.horizontal.3")
            }
		}
	}

    private func metadataField(_ title: String, original: String?, field: XSignAppMetadata.Field,
                               value: Binding<String?>) -> some View {
        let text = Binding(get: { value.wrappedValue ?? original ?? "" },
                           set: { value.wrappedValue = $0 == original ? nil : $0 })
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(xsignText(title)).font(.subheadline.weight(.semibold))
                Spacer()
                if value.wrappedValue != nil, original != nil {
                    Button("استعادة الأصل") { value.wrappedValue = nil }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }
            TextField(xsignText(title), text: text)
                .font(field == .bundleIdentifier ? .system(.subheadline, design: .monospaced) : .subheadline)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focusedMetadataField, equals: title)
                .onSubmit { focusedMetadataField = nil }
                .keyboardType(field == .version ? .numbersAndPunctuation : .default)
                .environment(\.layoutDirection, field == .name ? layoutDirection : .leftToRight)
                .padding(11)
                .background(AppStoreTheme.controlSurface, in: RoundedRectangle(cornerRadius: 10))
            if let value = value.wrappedValue, let message = XSignAppMetadata.errorMessage(for: value, field: field) {
                Text(xsignText(message)).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Extension: View (import)
extension SigningView {
    @MainActor
    private func importIcon(_ result: Result<URL, Error>) {
        guard policy.locks.allowsIconChanges else { return }
        switch result {
        case .failure(let error):
            signingFailureMessage = error.localizedDescription
        case .success(let url):
            isLoadingIcon = true
            signingFailureMessage = nil
            Task { @MainActor in
                defer { isLoadingIcon = false }
                let image = await Task.detached(priority: .utility) { Self.readIcon(url) }.value
                guard policy.locks.allowsIconChanges else { return }
                guard let image else { signingFailureMessage = "تعذّر فتح الصورة المختارة."; return }
                appIcon = UIImage(cgImage: image).resizeToSquare()
            }
        }
    }

    private nonisolated static func readIcon(_ url: URL) -> CGImage? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [String: Any] = [kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true, kCGImageSourceThumbnailMaxPixelSize as String: 512]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

	private func _start() {
        guard !_isSigning, !isLoadingIcon, !isImportingTweaks else { return }
        signingFailureMessage = nil
        let locksAtSubmission = policy.locks
        if appIcon != nil && !locksAtSubmission.allowsIconChanges {
            signingFailureMessage = "قُفل تغيير الأيقونة. حدّث الصلاحيات أو استخدم إعادة تعيين قبل التوقيع."
            return
        }
        if !_temporaryOptions.injectionFiles.isEmpty && !locksAtSubmission.allowsLibraryInjection {
            signingFailureMessage = "قُفلت إضافة المكتبات. أزل الملفات المختارة أو حدّث الصلاحيات قبل التوقيع."
            return
        }
        let currentLibraries = XSignRemoteManager.shared.config?.dashboard?.signing_libraries ?? []
        if _temporaryOptions.injectionFiles.contains(where: { file in
            managedLibraryFiles[file].map { !currentLibraries.contains($0) } ?? false
        }) {
            signingFailureMessage = "تغيّرت قائمة الدايلبات الجاهزة. أزل المكتبة المتوقفة أو اختر النسخة الحالية قبل التوقيع."
            return
        }
        if !locksAtSubmission.allowsAppMetadataEditing,
           _temporaryOptions.appName != nil || _temporaryOptions.appIdentifier != nil || _temporaryOptions.appVersion != nil {
            signingFailureMessage = "قُفل تعديل البيانات. حدّث الصلاحيات أو استخدم إعادة تعيين قبل التوقيع."
            return
        }
        if locksAtSubmission.allowsAppMetadataEditing {
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
        var requestedOptions = _temporaryOptions
        if cloneIdentifier != nil, requestedOptions.appIdentifier == cloneIdentifier {
            requestedOptions.post_deleteAppAfterSigned = false
        }
        let options = requestedOptions
        let installWhenReady = installsAfterSigning

        FR.signPackageFileWithResult(app, using: options, icon: appIcon, certificate: _selectedCert(),
                                     requireRequestedEdits: true, preserveEditedBundleID: editedBundleID) { result in
            _isSigning = false
            switch result {
            case .failure(let error):
                signingFailureMessage = error.localizedDescription
            case .success(let uuid):
                SigningTweaksView.discardStagedFiles(options.injectionFiles)
                if options.post_deleteAppAfterSigned, !app.isSigned {
                    Storage.shared.deleteApp(for: app)
                }
                if installWhenReady {
                    guard let signed = AutoSignPipelineManager.fetchSignedApp(uuid: uuid) else {
                        signingFailureMessage = "تم التوقيع. افتح المكتبة لعرض النسخة الموقّعة وتثبيتها."
                        return
                    }
                    XSignInstallation.shared.install(signed, afterDismissal: true)
                }
                dismiss()
            }
        }
	}
}
