import SwiftUI

struct XSignPackageContentsView: View {
    let app: any AppInfoPresentable
    @State private var contents: [String] = []
    @State private var failed = false
    @State private var loading = true

    var body: some View {
        List {
            if loading { ProgressView() }
            else if failed { Text(xsignText("تعذّر قراءة حزمة التطبيق.")) }
            else if contents.isEmpty { Text(xsignText("لا توجد مكتبات أو إضافات داخل الحزمة.")) }
            ForEach(contents, id: \.self) { path in
                Label(path, systemImage: path.hasSuffix(".dylib") ? "shippingbox" : "puzzlepiece.extension")
                    .font(.footnote)
            }
        }
        .xsignListBackground()
        .navigationTitle(xsignText("محتويات الحزمة"))
        .task {
            defer { loading = false }
            guard let folder = Storage.shared.getAppDirectory(for: app) else { failed = true; return }
            let worker = Task.detached(priority: .utility) {
                var result: [String] = []
                try XSignIPAExtractor.validateTree(folder) { item in
                    if ["dylib", "framework", "appex", "bundle"].contains(item.pathExtension.lowercased()) {
                        result.append(item.pathComponents.dropFirst(folder.pathComponents.count).joined(separator: "/"))
                    }
                }
                return result.sorted()
            }
            do {
                contents = try await withTaskCancellationHandler(operation: { try await worker.value },
                    onCancel: { worker.cancel() })
            } catch { failed = !Task.isCancelled }
        }
    }
}
