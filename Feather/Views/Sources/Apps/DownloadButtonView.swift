import SwiftUI
import Combine
import AltSourceKit

struct DownloadButtonView: View {
    let url: URL?
    let provenance: SourceAppProvenance?
    @ObservedObject private var downloads = DownloadManager.shared

    init(url: URL?, provenance: SourceAppProvenance?) {
        self.url = url.flatMap { XSignManagedSource.httpsURL($0.absoluteString) }
        self.provenance = provenance
    }

    init(sourceURL: URL?, source: ASRepository?, app: ASRepository.App) {
        self.init(url: app.currentDownloadUrl,
            provenance: source.flatMap { SourceAppProvenance(sourceURL: sourceURL, repository: $0, app: app) })
    }

    var body: some View {
        if let url {
            let id = DownloadManager.sourceImportID(for: url)
            if let download = downloads.getDownload(by: id) {
                progressButton(download).id(ObjectIdentifier(download))
            } else if downloads.didCompleteSourceImport(id) {
                Menu {
                    Button(xsignText("إعادة الاستيراد")) { start(url, id: id) }
                } label: {
                    Label(xsignText("تم الاستيراد"), systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                }
                .xsignGlassButton()
            } else {
                Button(xsignText("استيراد")) { start(url, id: id) }
                    .font(.subheadline.weight(.semibold))
                    .xsignGlassButton()
            }
        } else {
            Text(xsignText("التنزيل غير متاح")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func start(_ url: URL, id: String) {
        _ = downloads.startDownload(from: url, id: id, sourceProvenance: provenance)
    }

    private func progressButton(_ download: Download) -> some View {
        XSignSourceImportProgress(download: download) { downloads.cancelDownload(download) }
    }
}

private struct XSignSourceImportProgress: View {
    let download: Download
    let cancel: () -> Void
    @State private var fraction = 0.0

    var body: some View {
        Button(action: cancel) {
            ZStack {
                Circle().strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 2)
                Circle().trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "stop.fill").font(.caption2)
            }
            .frame(width: 30, height: 30)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(xsignText("إلغاء تنزيل التطبيق")))
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
        .onReceive(download.$progress.combineLatest(download.$unpackageProgress)) { progress, unpacking in
            fraction = min(1, max(0, 0.7 * progress + 0.3 * unpacking))
        }
    }
}
