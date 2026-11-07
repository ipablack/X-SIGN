import SwiftUI
import NimbleViews

struct ArchiveView: View {
    @AppStorage("Feather.compressionLevel") private var compressionLevel = 0

    var body: some View {
        NBList(.localized("Archive & Compression")) {
            Section {
                Picker(selection: $compressionLevel) {
                    Text("أسرع تجهيز").tag(0)
                    Text("حجم أقل").tag(8)
                } label: {
                    Label(.localized("Compression Level"), systemImage: "archivebox")
                }
            } footer: {
                Text("ضغط أقل يجهّز التطبيق أسرع، وضغط أعلى يقلّل حجم الملف المؤقت للتثبيت.")
            }
        }
        .onAppear { if ![0, 8].contains(compressionLevel) { compressionLevel = 0 } }
    }
}
