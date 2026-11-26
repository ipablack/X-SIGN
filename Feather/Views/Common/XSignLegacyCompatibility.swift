import SwiftUI
import PhotosUI
import NimbleExtensions

// Keep iOS 15 support explicit. Do not lower deployment targets without these paths.
struct XSignNavigationView<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content=content() }
    @ViewBuilder var body: some View {
        if #available(iOS 16, *) { NavigationStack { content } }
        else { NavigationView { content }.navigationViewStyle(.stack) }
    }
}

struct XSignLabeledContent<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title=title;self.content=content()
    }
    init(_ title: String, value: String) where Content == Text {
        self.title=title;self.content=Text(value)
    }
    var body: some View {
        HStack(alignment:.firstTextBaseline) {
            Text(xsignText(title));Spacer(minLength:12);content.foregroundColor(.secondary)
        }
    }
}

extension View {
    @ViewBuilder func xsignToolbarTitleMenu<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbarTitleMenu(content: content)
        } else {
            self.toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu(content: content) { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    @ViewBuilder func xsignCompactSheet(height: CGFloat) -> some View {
        if #available(iOS 16, *) {
            self.presentationDetents([.height(height)]).presentationDragIndicator(.visible)
        } else { self }
    }
    @ViewBuilder func xsignDismissKeyboardOnScroll() -> some View {
        if #available(iOS 16, *) { self.scrollDismissesKeyboard(.interactively) }
        else { self }
    }
}

struct XSignInstallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.xsignInstallPill()
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension View {
    func xsignInstallPill() -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .xsignGlassControl(in: Capsule())
    }
}

// PHPicker keeps photo-library access scoped to the single item the user chooses.
struct XSignPhotoPicker: UIViewControllerRepresentable {
    let selected: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected:selected) }
    func makeUIViewController(context:Context) -> PHPickerViewController {
        var config=PHPickerConfiguration();config.filter = .images;config.selectionLimit=1
        let picker=PHPickerViewController(configuration:config);picker.delegate=context.coordinator
        return picker
    }
    func updateUIViewController(_ controller:PHPickerViewController,context:Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let selected: (UIImage?) -> Void
        init(selected:@escaping(UIImage?)->Void) { self.selected=selected }
        func picker(_ picker:PHPickerViewController,didFinishPicking results:[PHPickerResult]) {
            picker.dismiss(animated:true)
            guard let provider=results.first?.itemProvider,provider.canLoadObject(ofClass:UIImage.self) else { return }
            provider.loadObject(ofClass:UIImage.self) { [selected] object,_ in
                DispatchQueue.main.async { selected(object as? UIImage) }
            }
        }
    }
}

extension View {
    func xsignPageBackground() -> some View {
        background(AppStoreTheme.background.ignoresSafeArea())
    }

    func xsignSurface(radius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(AppStoreTheme.cardSurface, in: shape)
            .overlay { shape.strokeBorder(AppStoreTheme.outline).allowsHitTesting(false) }
    }

    @ViewBuilder func xsignGlassControl<S: Shape>(
        in shape: S, tint: Color? = nil, interactive: Bool = true
    ) -> some View {
        modifier(XSignSystemGlass(shape: shape, tint: tint, interactive: interactive))
    }

    @ViewBuilder func xsignGlassButton() -> some View {
        if #available(iOS 26.0, *) { buttonStyle(.glass) }
        else { buttonStyle(.bordered).buttonBorderShape(.capsule) }
    }

    @ViewBuilder func xsignProminentGlassButton() -> some View {
        if #available(iOS 26.0, *) { buttonStyle(.glassProminent) }
        else { buttonStyle(.borderedProminent).buttonBorderShape(.capsule) }
    }

    @ViewBuilder func xsignListBackground() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
                .xsignPageBackground()
        } else {
            xsignPageBackground()
        }
    }
}


private struct XSignSystemGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                content.glassEffect(.regular.tint(tint), in: shape)
            }
        } else {
            content.background(tint ?? AppStoreTheme.controlSurface, in: shape)
        }
    }
}

enum XSignLanguage: String, CaseIterable, Identifiable, Sendable {
    case arabic = "ar"
    case english = "en"
    case kurdish = "ckb"

    nonisolated static let storageKey = "xsign.interfaceLanguage"

    static var current: Self {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .arabic
    }

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var direction: LayoutDirection { self == .english ? .leftToRight : .rightToLeft }

    var name: String {
        switch self {
        case .arabic: return "عربي"
        case .english: return "ENGLISH"
        case .kurdish: return "کوردی"
        }
    }
}

func xsignText(_ key: String, language: XSignLanguage = .current) -> String {
    String.localized(key, languageCode: language.rawValue)
}

struct XSignLanguageMenu: View {
    @AppStorage(XSignLanguage.storageKey) private var selection = ""

    var body: some View {
        Menu {
            Picker("لغة التطبيق", selection: $selection) {
                ForEach(XSignLanguage.allCases) { language in
                    Text(verbatim: language.name).tag(language.rawValue)
                }
            }
        } label: {
            HStack {
                Label("لغة التطبيق", systemImage: "globe")
                Spacer()
                Text(verbatim: (XSignLanguage(rawValue: selection) ?? .arabic).name)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
    }
}

struct XSignLanguagePicker: View {
    let onContinue: (XSignLanguage) -> Void
    @State private var preview: XSignLanguage = {
        for identifier in Locale.preferredLanguages {
            guard let code = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first else { continue }
            switch code {
            case "ar": return .arabic
            case "ckb", "ku": return .kurdish
            case "en": return .english
            default: continue
            }
        }
        return .english
    }()

    init(onContinue: @escaping (XSignLanguage) -> Void) {
        self.onContinue = onContinue
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    FRAppIconView(size: 62).accessibilityHidden(true)
                    Text(verbatim: "XSign").font(.title2.weight(.bold))
                    Spacer()
                    Image(systemName: "globe")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: text("اختر لغة XSign"))
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: text("يمكنك تغيير اللغة لاحقًا من الإعدادات."))
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    ForEach(XSignLanguage.allCases) { language in
                        Button {
                            preview = language
                        } label: {
                            HStack {
                                Text(verbatim: language == .english ? "English" : language.name)
                                Spacer(minLength: 12)
                                Image(systemName: preview == language ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(preview == language ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                            }
                            .font(.headline)
                            .padding(16)
                            .frame(minHeight: 54)
                            .background(AppStoreTheme.controlSurface, in: RoundedRectangle(cornerRadius: 16))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(preview == language ? [.isSelected] : [])
                    }
                }
            }
            .frame(maxWidth: 480)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                onContinue(preview)
            } label: {
                Label(text("متابعة"), systemImage: "arrow.forward")
                    .font(.headline)
                    .frame(maxWidth: 480, minHeight: 46)
            }
            .xsignProminentGlassButton()
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(AppStoreTheme.background)
        }
        .background {
            LinearGradient(colors: [Color.accentColor.opacity(0.16), AppStoreTheme.background],
                startPoint: .topTrailing, endPoint: .center).ignoresSafeArea()
        }
        .environment(\.locale, preview.locale)
        .environment(\.layoutDirection, preview.direction)
    }

    private func text(_ key: String) -> String { xsignText(key, language: preview) }
}
