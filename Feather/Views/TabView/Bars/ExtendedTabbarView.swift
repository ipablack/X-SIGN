//
//  ExtendedTabbarView.swift
//  feather
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import Combine
import SwiftUI

@available(iOS 18, *)
struct ExtendedTabbarView: View {
    @AppStorage("Feather.tabCustomization") private var customization = TabViewCustomization()
    private let remote = XSignRemoteManager.shared
    @State private var tabs = TabEnum.visibleTabs(for: XSignRemoteManager.shared.config?.dashboard)
    @Binding var selection: TabEnum
    @State private var searchQuery = ""

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                if tabs.contains(.search) {
                    tabView(tabs, usesNativeSearch: true)
                        .searchable(text: $searchQuery, prompt: "الألعاب والتطبيقات والمزيد…")
                        .tabViewSearchActivation(.automatic)
                } else {
                    tabView(tabs, usesNativeSearch: false)
                }
            } else {
                tabView(tabs, usesNativeSearch: false)
            }
        }

        .onReceive(remote.$config.map { TabEnum.visibleTabs(for: $0?.dashboard) }.removeDuplicates()) { updated in
            if tabs != updated { tabs = updated }
            selectVisibleTab(updated)
        }
    }

    private func tabView(_ tabs: [TabEnum], usesNativeSearch: Bool) -> some View {
        TabView(selection: $selection) {
            ForEach(tabs, id: \.self) { tab in
                Tab(value: tab, role: tab == .search ? .search : nil) {
                    if tab == .search && usesNativeSearch {
                        AppStoreSearchView(tabSearchQuery: $searchQuery)
                    } else {
                        TabEnum.view(for: tab)
                    }
                } label: {
                    tab.tabLabel
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewCustomization($customization)
    }

    private func selectVisibleTab(_ tabs: [TabEnum]) {
        if !tabs.contains(selection), let first = tabs.first { selection = first }
    }
}
