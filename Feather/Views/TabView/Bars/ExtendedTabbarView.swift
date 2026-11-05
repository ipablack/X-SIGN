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
	@AppStorage("Feather.tabCustomization") var customization = TabViewCustomization()
	
	var body: some View {
		TabView {
			Tab {
				TabEnum.view(for: .today)
			} label: {
				TabEnum.today.tabLabel
			}
			
			Tab {
				TabEnum.view(for: .games)
			} label: {
				TabEnum.games.tabLabel
			}
			
			Tab {
				TabEnum.view(for: .sources)
			} label: {
				TabEnum.sources.tabLabel
			}
			
			Tab {
				TabEnum.view(for: .library)
			} label: {
				TabEnum.library.tabLabel
			}
			
			Tab(role: .search) {
				TabEnum.view(for: .search)
			} label: {
				TabEnum.search.tabLabel
			}
		}
		.tabViewStyle(.sidebarAdaptable)
		.tabViewCustomization($customization)
		.environment(\.layoutDirection, .rightToLeft)
	}
}
