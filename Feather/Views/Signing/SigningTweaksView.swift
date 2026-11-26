//
//  SigningTweaksView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//

import SwiftUI
import CryptoKit
import NimbleViews
import UniformTypeIdentifiers

// MARK: - View
struct SigningTweaksView: View {
    @ObservedObject private var policy = XSignSecurityEnforcer.shared
    @State private var selectingLibraries = false
    @State private var selectingFramework = false
    @State private var importMessage: String?
	@Binding var options: Options
    @Binding var isImporting: Bool

	// MARK: Body
	var body: some View {
		NBList(xsignText("الإضافات والحقن")) {
            Section {
                Label("إضافات النسخة", systemImage: "shippingbox.fill").font(.title3.bold())
                Text("أضف مكتبة أو فريمورك، ثم راجع وجهة الحقن قبل التوقيع.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !policy.locks.allowsLibraryInjection {
                    Label("إضافة المكتبات مقفلة من إدارة المتجر", systemImage: "lock.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("إضافة ملفات") {
                Button {
                    selectingLibraries = true
                } label: { Label("إضافة دايليب أو حزمة DEB", systemImage: "doc.badge.plus") }
                .fileImporter(isPresented: $selectingLibraries, allowedContentTypes: [.item],
                              allowsMultipleSelection: true) { importFiles($0, framework: false) }
                Button {
                    selectingFramework = true
                } label: { Label("إضافة فريمورك", systemImage: "shippingbox") }
                .fileImporter(isPresented: $selectingFramework,
                              allowedContentTypes: [UTType(filenameExtension: "framework") ?? .bundle, .folder],
                              allowsMultipleSelection: true) { importFiles($0, framework: true) }
                Text("للفريمورك، اختر المجلد الكامل الذي ينتهي بـ .framework من تطبيق الملفات.")
                    .font(.footnote).foregroundStyle(.secondary)
                if isImporting { ProgressView("جاري تجهيز الملفات…") }
            }
            .disabled(isImporting || !policy.locks.allowsLibraryInjection)
            if let importMessage {
                Section { Text(xsignText(importMessage)).font(.footnote).foregroundStyle(.red) }
            }
			DisclosureGroup("خيارات الحقن المتقدمة") {
				SigningOptionsView.picker(
					.localized("Injection Path"),
					systemImage: "doc.badge.gearshape",
					selection: $options.injectPath,
					values: Options.InjectPath.allCases
				)
				SigningOptionsView.picker(
					.localized("Injection Folder"),
					systemImage: "folder.badge.gearshape",
					selection: $options.injectFolder,
					values: Options.InjectFolder.allCases
				)

				Toggle(isOn: $options.injectIntoExtensions) {
					Label(.localized("Inject into Extensions"), systemImage: "syringe")
				}
                Text("مسار ومجلد الحقن يخصّان ملفات dylib. توضع الفريموركات في Frameworks.")
                    .font(.footnote).foregroundStyle(.secondary)
			}
            .disabled(!policy.locks.allowsLibraryInjection)

			NBSection(xsignText("الملفات المختارة")) {
                Text("\(options.injectionFiles.count) ملفات جاهزة للإضافة")
                    .font(.footnote).foregroundStyle(.secondary)
				if !options.injectionFiles.isEmpty {
					ForEach(options.injectionFiles, id: \.absoluteString) { tweak in
						_file(tweak: tweak)
					}
				} else {
					Text("لم تُضف ملفات بعد")
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			}
		}
        .xsignListBackground()
		.animation(.easeInOut(duration: 0.25), value: options.injectionFiles)

	}
}

struct XSignSigningLibraryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var remote = XSignRemoteManager.shared
    @ObservedObject private var policy = XSignSecurityEnforcer.shared
    @State private var pending: Task<Void, Never>?
    @State private var message: String?
    let bundle: String
    @Binding var files: [URL]
    @Binding var managedFiles: [URL: XSignSigningLibrary]
    @Binding var isImporting: Bool

    init(bundle: String, files: Binding<[URL]>, managedFiles: Binding<[URL: XSignSigningLibrary]>,
         isImporting: Binding<Bool>) {
        self.bundle = bundle
        _files = files
        _managedFiles = managedFiles
        _isImporting = isImporting
    }

    private var catalogue: [XSignSigningLibrary] { remote.config?.dashboard?.signing_libraries ?? [] }
    private var available: [XSignSigningLibrary] {
        var ids = Set<String>()
        return catalogue.prefix(40).filter { $0.matches(bundle) && ids.insert($0.id).inserted }
    }

    var body: some View {
        NBNavigationView(xsignText("دايلبات جاهزة"), displayMode: .inline) {
            List {
                if available.isEmpty {
                    Text("لا توجد مكتبات جاهزة لهذا التطبيق.").foregroundStyle(.secondary)
                }
                ForEach(available) { library in
                    let selected = files.first { managedFiles[$0]?.id == library.id }
                    Button {
                        if let selected {
                            files.removeAll { $0 == selected }
                            managedFiles.removeValue(forKey: selected)
                            SigningTweaksView.discardStagedFiles([selected])
                        } else {
                            add(library)
                        }
                    } label: {
                        Label(library.name, systemImage: selected == nil ? "plus.circle" : "checkmark.circle.fill")
                    }
                    .disabled(isImporting || !policy.locks.allowsLibraryInjection)
                }
                if isImporting { ProgressView("جاري تنزيل المكتبة والتحقق منها…") }
                if let message { Text(xsignText(message)).font(.footnote).foregroundStyle(.red) }
            }
            .xsignListBackground()
            .toolbar { Button("تم") { dismiss() }.disabled(isImporting) }
        }
        .interactiveDismissDisabled(isImporting)
        .onDisappear { pending?.cancel() }
    }

    @MainActor private func add(_ library: XSignSigningLibrary) {
        guard !isImporting, policy.locks.allowsLibraryInjection, let url = library.downloadURL else { return }
        guard !files.contains(where: { $0.lastPathComponent.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame }) else {
            message = "يوجد ملف بالاسم نفسه ضمن قائمة الحقن."
            return
        }
        isImporting = true
        message = nil
        pending = Task { @MainActor in
            defer { isImporting = false; pending = nil }
            if let reason = await remote.prepareProtectedOperation() {
                message = reason
                return
            }
            guard policy.locks.allowsLibraryInjection, catalogue.contains(library), !Task.isCancelled else { return }
            do {
                let file = try await Self.download(library, from: url)
                policy.evaluateNetworkSecurity()
                guard !Task.isCancelled, remote.blockingReason == nil,
                      policy.locks.allowsLibraryInjection, catalogue.contains(library) else {
                    SigningTweaksView.discardStagedFiles([file])
                    if !Task.isCancelled { message = remote.blockingReason ?? "تغيّرت صلاحية المكتبة. أعد المحاولة." }
                    return
                }
                managedFiles[file] = library
                files.append(file)
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    private nonisolated static func download(_ library: XSignSigningLibrary, from url: URL) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: XSignCatalogRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await XSignBoundedHTTP.fetch(URLRequest(url: url), using: session, limit: 8 * 1024 * 1024)
        let magic = Data(data.prefix(4))
        let knownMagic: [Data] = [Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xca, 0xfe, 0xba, 0xbf])]
        guard response.statusCode == 200, data.count >= 32, knownMagic.contains(magic),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == library.sha256 else {
            throw NSError(domain: "XSign.ManagedLibrary", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "تعذّر التحقق من ملف الدايلب أو بصمته SHA-256."])
        }
        try Task.checkCancellation()
        let directory = XSignPrivateFiles.workDirectory(prefix: "Injection")
        let file = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try XSignPrivateFiles.createDirectory(directory)
            try data.write(to: file, options: .atomic)
            guard try !XSignMachOEncryption.isEncrypted(executable: file) else {
                throw XSignMachOEncryption.InspectionError.encryptedExecutable
            }
            try XSignPrivateFiles.protect(file)
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

// MARK: - Extension: View
extension SigningTweaksView {
    @MainActor
    private func importFiles(_ result: Result<[URL], Error>, framework: Bool) {
        guard policy.locks.allowsLibraryInjection, !isImporting else { return }
        switch result {
        case .failure(let error):
            importMessage = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            isImporting = true
            importMessage = nil
            Task { @MainActor in
                defer { isImporting = false }
                for url in urls {
                    if options.injectionFiles.contains(where: {
                        $0.lastPathComponent.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame
                    }) {
                        importMessage = "يوجد ملف بالاسم نفسه. احذف النسخة المختارة قبل استبدالها."
                        continue
                    }
                    do {
                        let staged = try await Task.detached(priority: .utility) {
                            try Self.stage(url, framework: framework)
                        }.value
                        if !policy.locks.allowsLibraryInjection {
                            Self.discardStagedFiles([staged])
                            importMessage = "تغيّرت الصلاحيات أثناء الاستيراد. حدّث إعدادات المتجر ثم أعد المحاولة."
                            return
                        }
                        options.injectionFiles.append(staged)
                    } catch {
                        importMessage = url.lastPathComponent + " · " + error.localizedDescription
                    }
                }
            }
        }
    }

    private nonisolated static func stage(_ url: URL, framework: Bool) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard (framework ? ["framework"] : ["dylib", "deb"]).contains(ext) else {
            let message = framework ? "اختر مجلدًا ينتهي بـ .framework." : "اختر ملفًا ينتهي بـ .dylib أو .deb."
            throw NSError(domain: "XSign.Injection", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
        }
        if ext == "framework" {
            try XSignIPAExtractor.validateTree(url)
            guard Bundle(url: url)?.executableURL != nil else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            let type = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard type.isRegularFile == true, type.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        }
        let directory = XSignPrivateFiles.workDirectory(prefix: "Injection")
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try XSignPrivateFiles.createDirectory(directory)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    nonisolated static func discardStagedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            let root = XSignPrivateFiles.workRoot.standardizedFileURL
            for folder in Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL })
            where folder.deletingLastPathComponent() == root && folder.lastPathComponent.hasPrefix("Injection_") {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

	@ViewBuilder
	private func _file(tweak: URL) -> some View {
		Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(tweak.lastPathComponent).font(.subheadline.weight(.medium))
                Text(tweak.pathExtension.uppercased()).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "doc.badge.gearshape").foregroundStyle(Color.accentColor)
        }
			.lineLimit(2)
			.frame(maxWidth: .infinity, alignment: .leading)
			.swipeActions(edge: .trailing, allowsFullSwipe: true) {
				_fileActions(tweak: tweak)
			}
			.contextMenu {
				_fileActions(tweak: tweak)
			}
	}

	@ViewBuilder
	private func _fileActions(tweak: URL) -> some View {
		Button(role: .destructive) {
            options.injectionFiles.removeAll { $0 == tweak }
            Self.discardStagedFiles([tweak])
		} label: {
			Label(.localized("Delete"), systemImage: "trash")
		}
	}
}
