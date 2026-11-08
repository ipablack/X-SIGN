//
//  TabbarView.swift
//  feather
//
//  Created by samara on 5/17/24.
//

import SwiftUI

struct TabbarView: View {
    @State private var selectedTab: TabEnum = .today
    @ObservedObject private var remote = XSignRemoteManager.shared

    var body: some View {
        let tabs = TabEnum.visibleTabs(for: remote.config?.dashboard)
        TabView(selection: $selectedTab) {
            ForEach(tabs, id: \.self) { tab in
                TabEnum.view(for: tab)
                    .tabItem { tab.tabLabel }
                    .tag(tab)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { selectVisibleTab(tabs) }
        .onChange(of: tabs, perform: selectVisibleTab)
    }

    private func selectVisibleTab(_ tabs: [TabEnum]) {
        if !tabs.contains(selectedTab), let first = tabs.first { selectedTab = first }
    }
}
