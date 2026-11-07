//
//  TabbarView.swift
//  feather
//
//  Created by samara on 5/17/24.
//

import SwiftUI

struct TabbarView: View {
	@State private var selectedTab: TabEnum = .today
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
		TabView(selection: $selectedTab) {
			ForEach(tabs, id: \.rawValue) { tab in
				TabEnum.view(for: tab)
					.tabItem {
						tab.tabLabel
					}
					.tag(tab)
			}
		}
		.environment(\.layoutDirection, .rightToLeft)
        .onChange(of:tabs) { value in if !value.contains(selectedTab), let first=value.first { selectedTab=first } }
	}
}
