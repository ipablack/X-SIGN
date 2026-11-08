import SwiftUI
import UIKit
import NukeUI
import AltSourceKit

struct XSignAppStoreProductPage: View {
    let item: AppStoreAppItem
    @State private var metadata: AppleStoreRichMetadata?
    @State private var loading = true
    @State private var versionsPresented = false
    @State private var sharing = false
    @State private var screenshot: XSignProductScreenshot?
    @State private var notesExpanded = false
    @AppStorage("Feather.userTintColor") private var tintHex = "#005BBB"

    private var screens: [URL] {
        let urls = metadata?.screenshots.isEmpty == false ? metadata!.screenshots : item.screenshots
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }
    private var developer: String { metadata?.sellerName ?? item.app.developer ?? "—" }
    private var description: String {
        if let value = item.app.currentDescription, !value.isEmpty, !AppStoreBilingualEngine.isInternalSourceNote(value) { return value }
        return metadata?.description ?? "لا يتوفر وصف لهذا الإصدار."
    }
    private var notes: String? {
        if let value = item.app.currentAppVersion?.localizedDescription, !value.isEmpty,
           !AppStoreBilingualEngine.isInternalSourceNote(value) { return value }
        return metadata?.releaseNotes
    }
    private var size: String {
        let versionSize = (item.app.currentAppVersion?.size).flatMap { Int64(exactly: $0) }
        let bytes = item.app.size ?? versionSize ?? metadata?.fileSizeBytes
        guard let bytes, bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private var languages: String? {
        guard let codes = metadata?.languageCodes, !codes.isEmpty else { return nil }
        let locale = Locale(identifier: "ar")
        return codes.prefix(5).map { locale.localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: "، ")
            + (codes.count > 5 ? " و\(codes.count - 5) أخرى" : "")
    }

    var body: some View {
        let screenshots = screens
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 24) {
                header.padding(.horizontal, 18).padding(.top, 10)
                separator
                statistics
                if !screenshots.isEmpty || loading {
                    separator
                    previews(screenshots)
                }
                separator
                whatsNew.padding(.horizontal, 18)
                separator
                XSignTranslatableDescription(text: description, accentColor: Color(hex: tintHex))
                    .padding(.horizontal, 18)
                separator
                information.padding(.horizontal, 18).padding(.bottom, 36)
            }
        }
        .background(AppStoreTheme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(false)
        .sheet(isPresented: $versionsPresented) { versionHistory }
        .sheet(isPresented: $sharing) {
            if let url = metadata?.storeURL { XSignPublicStoreShare(url: url) }
        }
        .fullScreenCover(item: $screenshot) { selected in
            XSignProductScreenshots(urls: screenshots, selected: selected.url)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task(id: item.id) {
            loading = true
            metadata = await AppStoreLiveMetadataBridge.shared.fetchMetadata(bundleID: item.app.id,
                appName: item.app.currentName, iconURL: item.app.iconURL, skipLookup: item.app.skipAppStoreLookup == true)
            loading = false
        }
    }

    private var separator: some View { Divider().padding(.horizontal, 18) }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AppStoreIconView(url: item.app.iconURL, bundleID: item.app.id, appName: item.app.currentName, size: 112)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.app.currentName).font(.title2.bold()).lineLimit(2)
                Text(item.arabicSubtitle).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                HStack {
                    AppStore2026DownloadButton(app: item.app)
                    Spacer()
                    if metadata?.storeURL != nil {
                        Button { sharing = true } label: { Image(systemName: "square.and.arrow.up").font(.title3) }
                            .accessibilityLabel("مشاركة صفحة App Store")
                    }
                }
            }
        }
    }

    private var statistics: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                AppStoreStatBadge(topTitle: "تقييم App Store",
                    mainValue: metadata?.rating.map { String(format: "%.1f", $0) } ?? "—",
                    bottomText: metadata?.rating == nil ? "غير متوفر" : "App Store")
                Divider().frame(height: 36)
                AppStoreStatBadge(topTitle: "العمر", mainValue: metadata?.contentRating ?? "—", bottomText: "سنة")
                Divider().frame(height: 36)
                AppStoreStatBadge(topTitle: "الفئة", mainValue: item.category.rawValue, bottomText: "التصنيف")
                Divider().frame(height: 36)
                AppStoreStatBadge(topTitle: "الحجم", mainValue: size, bottomText: "iOS")
            }.padding(.horizontal, 18)
        }
    }

    private var whatsNew: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("ما الجديد").font(.title2.weight(.bold))
                Spacer()
                if item.app.versions?.isEmpty == false {
                    Button("سجل الإصدارات") { versionsPresented = true }.font(.subheadline)
                }
            }
            HStack {
                Text("الإصدار \(item.app.currentVersion ?? "—")")
                Spacer()
                if let text = metadata?.releaseDate, let date = ISO8601DateFormatter().date(from: text) {
                    Text(date, style: .relative)
                }
            }.font(.subheadline).foregroundStyle(.secondary)
            if let notes {
                Text(notes).font(.system(size: 15)).lineSpacing(3).lineLimit(notesExpanded ? nil : 3)
                if !notesExpanded && notes.count > 140 { Button("المزيد") { notesExpanded = true }.font(.subheadline) }
            }
        }
    }

    private func previews(_ screenshots: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("معاينة").font(.title2.bold()).padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(screenshots, id: \.self) { url in
                        Button { screenshot = XSignProductScreenshot(url: url) } label: {
                            XSignProductScreenshotImage(url: url)
                                .frame(width: min(UIScreen.main.bounds.width * 0.62, 280), height: 440)
                                .background(AppStoreTheme.controlSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }.buttonStyle(.plain).accessibilityLabel("فتح لقطة الشاشة")
                    }
                    if screenshots.isEmpty && loading {
                        ProgressView().frame(width: min(UIScreen.main.bounds.width * 0.62, 280), height: 440)
                    }
                }.padding(.horizontal, 18)
            }
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("المعلومات").font(.title2.weight(.bold)).padding(.bottom, 2)
            if let seller = metadata?.sellerURL {
                Link(destination: seller) { AppStoreInfoRow(label: "المطور", value: developer) }
            } else {
                AppStoreInfoRow(label: "المطور", value: developer)
            }
            AppStoreInfoRow(label: "الحجم", value: size)
            AppStoreInfoRow(label: "الفئة", value: item.category.rawValue)
            if let minimum = metadata?.minimumOSVersion { AppStoreInfoRow(label: "التوافق", value: "يتطلب iOS \(minimum) أو أحدث") }
            if let languages { AppStoreInfoRow(label: "اللغات", value: languages) }
            if let age = metadata?.contentRating { AppStoreInfoRow(label: "التصنيف العمري", value: age) }
            AppStoreInfoRow(label: "الإصدار", value: item.app.currentVersion ?? "—")
        }
    }

    private var versionHistory: some View {
        XSignNavigationView {
            List {
                ForEach(Array((item.app.versions ?? []).enumerated()), id: \.offset) { _, version in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(version.version).font(.headline)
                        if let text = version.localizedDescription { Text(text).font(.subheadline) }
                    }.padding(.vertical, 8)
                }
            }.navigationTitle("سجل الإصدارات").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { versionsPresented = false } } }
        }
    }
}

private struct XSignProductScreenshot: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct XSignProductScreenshotImage: View {
    let url: URL
    var body: some View {
        LazyImage(url: url) { state in
            if let image = state.image { image.resizable().scaledToFit() }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.processors([.resize(size: CGSize(width: 700, height: 1400))])
    }
}

private struct XSignProductScreenshots: View {
    let urls: [URL]
    @State var selected: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        XSignNavigationView {
            TabView(selection: $selected) {
                ForEach(urls, id: \.self) { url in XSignProductScreenshotImage(url: url).tag(url) }
            }.tabViewStyle(.page(indexDisplayMode: .always)).background(AppStoreTheme.background)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
    }
}

private struct XSignPublicStoreShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
