//
//  TabbarView.swift
//  feather
//
//  Created by samara on 5/17/24.
//

import SwiftUI

struct TabbarView: View {
	@State private var selectedTab: TabEnum = .today
    @State private var searchQuery = ""
    @ObservedObject private var remote=XSignRemoteManager.shared
    private var tabs: [TabEnum] {
        guard let dashboard=remote.config?.dashboard, let order=dashboard.tab_order else { return TabEnum.defaultTabs }
        if dashboard.catalog_profile == nil, order == ["today","apps","games","search","library"] {
            return TabEnum.defaultTabs
        }
        var seen=Set<TabEnum>()
        let result=order.compactMap { value -> TabEnum? in
            let key=value == "apps" ? "sources" : value
            guard let tab=TabEnum(rawValue:key),TabEnum.defaultTabs.contains(tab),seen.insert(tab).inserted else { return nil }
            return tab
        }
        return result.isEmpty ? TabEnum.defaultTabs : result
    }

	var body: some View {
		Group {
            if #available(iOS 26.0, *), tabs.contains(.search) {
                modernTabs(usesTabSearch: true)
                    .searchable(text: $searchQuery, prompt: "الألعاب والتطبيقات والمزيد…")
                    .tabViewSearchActivation(.automatic)
            } else if #available(iOS 18.0, *) { modernTabs(usesTabSearch: false) }
            else { legacyTabs }
        }
		.environment(\.layoutDirection, .rightToLeft)
        .onChange(of:tabs) { value in if !value.contains(selectedTab), let first=value.first { selectedTab=first } }
    }

    @available(iOS 18.0, *)
    private func modernTabs(usesTabSearch: Bool) -> some View {
        TabView(selection: $selectedTab) {
            ForEach(tabs, id: \.rawValue) { tab in
                Tab(value: tab, role: tab == .search ? .search : nil) {
                    if usesTabSearch && tab == .search {
                        AppStoreSearchView(tabSearchQuery: $searchQuery)
                    } else { TabEnum.view(for: tab) }
                } label: { tab.tabLabel }
            }
        }
    }

    private var legacyTabs: some View {
		TabView(selection: $selectedTab) {
			ForEach(tabs, id: \.rawValue) { tab in
				TabEnum.view(for: tab)
					.tabItem {
						tab.tabLabel
					}
					.tag(tab)
			}
		}
	}
}
