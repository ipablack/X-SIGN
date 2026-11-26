//
//  TabbarView.swift
//  feather
//
//  Created by samara on 5/17/24.
//

import Combine
import SwiftUI

struct TabbarView: View {
    @Binding var selectedTab: TabEnum
    private let remote = XSignRemoteManager.shared
    @State private var tabs = TabEnum.visibleTabs(for: XSignRemoteManager.shared.config?.dashboard)

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(tabs, id: \.self) { tab in
                TabEnum.view(for: tab)
                    .tabItem { tab.tabLabel }
                    .tag(tab)
            }
        }

        .onReceive(remote.$config.map { TabEnum.visibleTabs(for: $0?.dashboard) }.removeDuplicates()) { updated in
            if tabs != updated { tabs = updated }
            selectVisibleTab(updated)
        }
    }

    private func selectVisibleTab(_ tabs: [TabEnum]) {
        if !tabs.contains(selectedTab), let first = tabs.first { selectedTab = first }
    }
}
