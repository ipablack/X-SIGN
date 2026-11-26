import SwiftUI

struct XSignLinkImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var destination: XSignImportLink?
    @State private var error: String?
    @State private var request: Task<Void, Never>?

    var body: some View {
        XSignNavigationView {
            Form {
                Section {
                    TextField(xsignText("رابط تنزيل IPA"), text: $input)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .environment(\.layoutDirection, .leftToRight)
                    Button(xsignText("معاينة الرابط"), action: preview)
                        .disabled(request != nil || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text(verbatim: "HTTPS IPA · itms-services")
                }
                if request != nil { ProgressView() }
                if let error {
                    Text(xsignText(error)).foregroundStyle(.red)
                }
                if let destination {
                    Section {
                        Text(verbatim: destination.title ?? destination.package.host ?? "")
                        if let version = destination.version {
                            XSignLabeledContent(xsignText("الإصدار"), value: version)
                        }
                        Button(xsignText("استيراد")) {
                            _ = DownloadManager.shared.startDownload(from: destination.package,
                                id: "FeatherManualDownload_\(UUID().uuidString)")
                            dismiss()
                        }
                    }
                }
            }
            .xsignListBackground()
            .navigationTitle(xsignText("استيراد من رابط"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(xsignText("إلغاء")) { dismiss() }
                }
            }
            .onChange(of: input) { _ in
                request?.cancel()
                request = nil
                destination = nil
                error = nil
            }
            .onDisappear { request?.cancel() }
        }
    }

    private func preview() {
        destination = nil
        error = nil
        do {
            switch try XSignImportLink.parse(input) {
            case .package(let url): destination = XSignImportLink(package: url)
            case .manifest(let url):
                request = Task { @MainActor in
                    defer { if !Task.isCancelled { request = nil } }
                    if let reason = await XSignRemoteManager.shared.prepareProtectedOperation() {
                        if !Task.isCancelled { error = reason }
                        return
                    }
                    let session = XSignBoundedHTTP.session()
                    defer { session.finishTasksAndInvalidate() }
                    do {
                        let (bytes, response) = try await XSignBoundedHTTP.fetch(URLRequest(url: url),
                            using: session, limit: XSignImportLink.manifestLimit)
                        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
                        let link = try XSignImportLink.parseManifest(bytes)
                        if !Task.isCancelled { destination = link }
                    } catch let failure as XSignImportLink.ValidationError {
                        if !Task.isCancelled { self.error = failure.localizedDescription }
                    } catch {
                        if !Task.isCancelled { self.error = "تعذّر قراءة ملف التثبيت." }
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
