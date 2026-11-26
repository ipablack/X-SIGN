import SwiftUI
import UniformTypeIdentifiers

struct SigningEntitlementsView: View {
    @Binding var bindingValue: URL?
    @State private var picking = false
    @State private var loading = false
    @State private var keys: [String] = []
    @State private var error: String?

    private static var directory: URL { XSignPrivateFiles.directory("CustomEntitlements") }

    var body: some View {
        List {
            Section {
                Button(xsignText("Select entitlements file")) { picking = true }.disabled(loading)
                if let file = bindingValue {
                    Text(verbatim: file.lastPathComponent).foregroundStyle(.secondary)
                    Button(xsignText("إزالة ملف الصلاحيات من النسخة"), role: .destructive) {
                        clearManagedFile(file)
                        bindingValue = nil
                        keys = []
                    }.disabled(loading)
                }
                if let error { Text(xsignText(error)).foregroundStyle(.red) }
                if loading { ProgressView() }
            }
            if !keys.isEmpty {
                Section(xsignText("Entitlements")) {
                    ForEach(keys, id: \.self) { Text(verbatim: $0).font(.footnote) }
                }
            }
        }
        .xsignListBackground()
        .navigationTitle(xsignText("Entitlements"))
        .fileImporter(isPresented: $picking, allowedContentTypes: [.propertyList, .entitlements]) { result in
            guard case .success(let file) = result else { return }
            importFile(file)
        }
        .task(id: bindingValue) {
            guard let file = bindingValue else { keys = []; return }
            let worker = Task.detached(priority: .utility) { try Self.read(file).keys }
            let values = try? await worker.value
            if !Task.isCancelled { keys = values ?? [] }
        }
    }

    private func importFile(_ file: URL) {
        loading = true
        error = nil
        Task { @MainActor in
            defer { loading = false }
            do {
                let output = try await Task.detached(priority: .utility) {
                    let access = file.startAccessingSecurityScopedResource()
                    defer { if access { file.stopAccessingSecurityScopedResource() } }
                    let content = try Self.read(file)
                    let root = Self.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    do {
                        try XSignPrivateFiles.createDirectory(root)
                        let output = root.appendingPathComponent("Entitlements.plist")
                        try content.data.write(to: output, options: .atomic)
                        try XSignPrivateFiles.protect(output)
                        return output
                    } catch {
                        try? FileManager.default.removeItem(at: root)
                        throw error
                    }
                }.value
                if let previous = bindingValue { clearManagedFile(previous) }
                bindingValue = output
            } catch { self.error = "ملف الصلاحيات غير صالح أو يتجاوز الحجم المسموح." }
        }
    }

    private static func read(_ file: URL) throws -> (data: Data, keys: [String]) {
        let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, (1...1_048_576).contains(size) else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: file)
        guard data.count <= 1_048_576,
              let contents = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (data, contents.keys.sorted())
    }

    private func clearManagedFile(_ file: URL) {
        let parent = file.deletingLastPathComponent()
        guard file.lastPathComponent == "Entitlements.plist", UUID(uuidString: parent.lastPathComponent) != nil,
              parent.deletingLastPathComponent().standardizedFileURL == Self.directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: parent)
    }
}
