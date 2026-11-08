//
//  ExtendedTabbarView.swift
//  feather
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import SwiftUI

@available(iOS 18, *)
struct ExtendedTabbarView: View {
    @AppStorage("Feather.tabCustomization") private var customization = TabViewCustomization()
    @ObservedObject private var remote = XSignRemoteManager.shared
    @State private var selection: TabEnum = .today
    @State private var searchQuery = ""

    var body: some View {
        let tabs = TabEnum.visibleTabs(for: remote.config?.dashboard)
        Group {
            if #available(iOS 26, *), tabs.contains(.search) {
                tabView(tabs, usesNativeSearch: true)
                    .searchable(text: $searchQuery, prompt: "الألعاب والتطبيقات والمزيد…")
                    .tabViewSearchActivation(.automatic)
            } else {
                tabView(tabs, usesNativeSearch: false)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { selectVisibleTab(tabs) }
        .onChange(of: tabs, perform: selectVisibleTab)
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
