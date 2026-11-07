//
//  CertificatesAddView.swift
//  Feather
//
//  Created by samara on 15.04.2025.
//

import SwiftUI
import NimbleViews
import UniformTypeIdentifiers

// MARK: - View
struct CertificatesAddView: View {
	@Environment(\.dismiss) private var dismiss
	
    @State private var _isSaving = false
	@State private var _p12URL: URL? = nil
	@State private var _provisionURL: URL? = nil
	@State private var _p12Password: String = ""
	@State private var _certificateName: String = ""
	
	@State private var _isImportingP12Presenting = false
	@State private var _isImportingMobileProvisionPresenting = false
	
	var saveButtonDisabled: Bool {
		_isSaving || _p12URL == nil || _provisionURL == nil
	}
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("New Certificate"), displayMode: .inline) {
			Form {
                Section {
                    Text("أضف P12 وملف MobileProvision وكلمة المرور مرة واحدة. بعدها يوقّع XSign ملفات IPA على جهازك مباشرة.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if _isSaving { ProgressView("جارٍ التحقق وحفظ الشهادة…") }
                }
				NBSection(.localized("Files")) {
					_importButton(.localized("Import Certificate File"), file: _p12URL) {
						_isImportingP12Presenting = true
					}
					_importButton(.localized("Import Provisioning File"), file: _provisionURL) {
						_isImportingMobileProvisionPresenting = true
					}
				}
				NBSection(.localized("Password")) {
					SecureField(.localized("Enter Password"), text: $_p12Password)
				} footer: {
					Text(.localized("Enter the password associated with the private key. Leave it blank if theres no password required."))
				}
				
				Section {
					TextField(.localized("Nickname (Optional)"), text: $_certificateName)
				}
			}
            .xsignListBackground()
            .disabled(_isSaving)
            .interactiveDismissDisabled(_isSaving)
			.toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }.disabled(_isSaving)
                }
				
				NBToolbarButton(
					.localized("Save"),
					style: .text,
					placement: .confirmationAction,
					isDisabled: saveButtonDisabled
				) {
					_saveCertificate()
				}
			}
			.sheet(isPresented: $_isImportingP12Presenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.p12],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self._p12URL = selectedFileURL
					}
				)
				.ignoresSafeArea()
			}
			.sheet(isPresented: $_isImportingMobileProvisionPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.mobileProvision],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self._provisionURL = selectedFileURL
					}
				)
				.ignoresSafeArea()
			}
		}
	}
}

// MARK: - Extension: View
extension CertificatesAddView {
	@ViewBuilder
	private func _importButton(
		_ title: String,
		file: URL?,
		action: @escaping () -> Void
	) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let file { Text(file.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .foregroundColor(.accentColor)
		.animation(.easeInOut(duration: 0.3), value: file != nil)
	}
}

// MARK: - Extension: View (import)
extension CertificatesAddView {
    private func _saveCertificate() {
        guard !_isSaving, let p12URL = _p12URL, let provisionURL = _provisionURL else { return }
        _isSaving = true
        let password = _p12Password
        let name = _certificateName
        // Password/profile decoding runs off the UI thread. Saving errors keep this form open.
        Task {
            let validationError: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                let keyAccess = p12URL.startAccessingSecurityScopedResource()
                let profileAccess = provisionURL.startAccessingSecurityScopedResource()
                defer {
                    if keyAccess { p12URL.stopAccessingSecurityScopedResource() }
                    if profileAccess { provisionURL.stopAccessingSecurityScopedResource() }
                }
                guard let profile = CertificateReader(provisionURL).decoded else {
                    return "ملف MobileProvision غير صالح. اختر ملفاً صحيحاً."
                }
                guard profile.ExpirationDate > Date() else { return "انتهت صلاحية ملف MobileProvision. أضف ملفاً سارياً." }
                guard FR.checkPasswordForCertificate(for: p12URL, with: password, using: provisionURL) else {
                    return "تعذّر فتح شهادة P12. تحقق من الملف وكلمة المرور."
                }
                return nil
            }.value
            if let validationError {
                _isSaving = false
                UIAlertController.showAlertWithOk(title: "إعداد التوقيع", message: validationError)
                return
            }
            FR.handleCertificateFiles(p12URL: p12URL, provisionURL: provisionURL,
                                      p12Password: password, certificateName: name) { error in
                _isSaving = false
                if let error {
                    UIAlertController.showAlertWithOk(title: "تعذّر حفظ الشهادة", message: error.localizedDescription)
                    return
                }
                // Certificate storage is sorted newest first; reuse the newly imported identity.
                UserDefaults.standard.set(0, forKey: "feather.selectedCert")
                AutoSignPipelineManager.shared.refreshCertificateCache()
                dismiss()
            }
        }
    }
}
