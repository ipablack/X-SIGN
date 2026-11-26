import SwiftUI
import NimbleViews

struct ArchiveView: View {
    @AppStorage("Feather.compressionLevel") private var compressionLevel = 0

    @AppStorage(XSignIPAExtractor.Engine.preference) private var engine = XSignIPAExtractor.Engine.zipFoundation.rawValue

    var body: some View {
        NBList(.localized("Archive & Compression")) {
            Section {
                Picker(xsignText("محرك فك الضغط"), selection: $engine) {
                    ForEach(XSignIPAExtractor.Engine.choices, id: \.rawValue) { item in
                        Text(verbatim: item.label).tag(item.rawValue)
                    }
                }
            } footer: {
                Text(xsignText("إذا تعذّر فك الحزمة، اختر محركًا آخر ثم أعد الاستيراد."))
            }
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
