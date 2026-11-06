import SwiftUI
import PhotosUI

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
            Text(title);Spacer(minLength:12);content.foregroundColor(.secondary)
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
