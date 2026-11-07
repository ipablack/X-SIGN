import SwiftUI
import UIKit
import NukeUI
import AltSourceKit

struct XSignAppStoreProductPage: View {
    let item: AppStoreAppItem
    @State private var metadata: AppleStoreRichMetadata?
    @State private var loading = true
    @State private var compactHeader = false
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
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 22)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: XSignProductHeaderOffset.self, value: proxy.frame(in: .named("xsignProduct")).minY)
                    })
                separator
                statistics.padding(.vertical, 16)
                separator
                whatsNew.padding(20)
                if !screens.isEmpty || loading {
                    separator
                    previews.padding(.vertical, 20)
                }
                separator
                XSignTranslatableDescription(text: description, accentColor: Color(hex: tintHex)).padding(20)
                developerRow.padding(.horizontal, 20).padding(.bottom, 20)
                if let rating = metadata?.rating, let count = metadata?.ratingCount, count > 0 {
                    separator
                    ratings(rating, count: count).padding(20)
                }
                separator
                information.padding(20)
            }.padding(.bottom, 24)
        }
        .coordinateSpace(name: "xsignProduct")
        .onPreferenceChange(XSignProductHeaderOffset.self) { compactHeader = $0 < -125 }
        .background(AppStoreTheme.background.ignoresSafeArea())
        .navigationTitle("").navigationBarTitleDisplayMode(.inline).navigationBarHidden(false)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if compactHeader {
                    HStack(spacing: 8) {
                        AppStoreIconView(url: item.app.iconURL, size: 30)
                        Text(item.app.currentName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if compactHeader { AppStore2026DownloadButton(app: item.app, showsFootnote: false) }
            }
        }
        .sheet(isPresented: $versionsPresented) { versionHistory }
        .sheet(isPresented: $sharing) {
            if let url = metadata?.storeURL { XSignPublicStoreShare(url: url) }
        }
        .fullScreenCover(item: $screenshot) { selected in
            XSignProductScreenshots(urls: screens, selected: selected.url)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task(id: item.id) {
            loading = true
            metadata = await AppStoreLiveMetadataBridge.shared.fetchMetadata(bundleID: item.app.id,
                appName: item.app.currentName, iconURL: item.app.iconURL, skipLookup: item.app.skipAppStoreLookup == true)
            loading = false
        }
    }

    private var separator: some View { Divider().padding(.horizontal, 20) }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AppStoreIconView(url: item.app.iconURL, bundleID: item.app.id, appName: item.app.currentName, size: 118)
                .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.app.currentName).font(.system(size: 22, weight: .semibold)).lineLimit(2)
                Text(item.arabicSubtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(alignment: .center) {
                    AppStore2026DownloadButton(app: item.app, showsFootnote: false)
                    Spacer(minLength: 8)
                    if metadata?.storeURL != nil {
                        Button { sharing = true } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 21)) }
                            .accessibilityLabel("مشاركة صفحة App Store")
                    }
                }.padding(.top, 10)
            }.frame(minHeight: 118, alignment: .topLeading)
        }
    }

    private var statistics: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                statistic("التقييمات", value: metadata?.rating.map { String(format: "%.1f", $0) } ?? "—", caption: metadata?.ratingCount.map { "\($0) تقييم" } ?? "غير متوفر")
                Divider().frame(height: 40)
                statistic("العمر", value: metadata?.contentRating ?? "—", caption: "سنة")
                Divider().frame(height: 40)
                statistic("الفئة", value: item.category.rawValue, caption: "التصنيف")
                Divider().frame(height: 40)
                statistic("المطور", value: developer, caption: "الموفّر")
                Divider().frame(height: 40)
                statistic("الحجم", value: size, caption: "حجم التطبيق")
            }.padding(.horizontal, 12)
        }
    }

    private func statistic(_ title: String, value: String, caption: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.65)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.frame(width: 104).padding(.horizontal, 5)
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

    private var previews: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("معاينة").font(.title2.weight(.bold)).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(screens, id: \.self) { url in
                        Button { screenshot = XSignProductScreenshot(url: url) } label: {
                            XSignProductScreenshotImage(url: url)
                                .frame(width: min(UIScreen.main.bounds.width * 0.68, 300), height: 440)
                                .background(AppStoreTheme.cardSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }.buttonStyle(.plain).accessibilityLabel("فتح لقطة الشاشة")
                    }
                    if screens.isEmpty && loading { ProgressView().frame(width: 180, height: 260) }
                }.padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder private var developerRow: some View {
        if let url = metadata?.sellerURL {
            Link(destination: url) { HStack { Text(developer); Spacer(); Image(systemName: "chevron.left") }.font(.subheadline) }
        } else if developer != "—" { Text(developer).font(.subheadline).foregroundStyle(.secondary) }
    }

    private func ratings(_ value: Double, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("التقييمات والمراجعات").font(.title2.weight(.bold))
            HStack(alignment: .bottom, spacing: 16) {
                Text(String(format: "%.1f", value)).font(.system(size: 56, weight: .bold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 3) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: value >= Double(star) ? "star.fill" : value >= Double(star) - 0.5 ? "star.leadinghalf.filled" : "star")
                        }
                    }.font(.subheadline).foregroundStyle(.secondary)
                    Text("\(count) تقييم من App Store").font(.caption).foregroundStyle(.secondary)
                }.padding(.bottom, 8)
            }
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("المعلومات").font(.title2.weight(.bold)).padding(.bottom, 2)
            AppStoreInfoRow(label: "الموفّر", value: developer)
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

private struct XSignProductHeaderOffset: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
