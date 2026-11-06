import SwiftUI

public struct NBNavigationView<Content: View>: View {
    private let title: String
    private let mode: NavigationBarItem.TitleDisplayMode
    private let content: Content
    public init(_ title: String, displayMode: NavigationBarItem.TitleDisplayMode = .automatic,
                @ViewBuilder content: () -> Content) {
        self.title=title;self.mode=displayMode;self.content=content()
    }
    @ViewBuilder public var body: some View {
        if #available(iOS 16, *) {
            NavigationStack { content.navigationTitle(title).navigationBarTitleDisplayMode(mode) }
        } else {
            NavigationView { content.navigationTitle(title).navigationBarTitleDisplayMode(mode) }
                .navigationViewStyle(.stack)
        }
    }
}
