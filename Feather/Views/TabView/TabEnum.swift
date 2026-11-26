//
//  TabEnum.swift
//  feather
//
//  Created by samara on 22.03.2025.
//

import SwiftUI
import NimbleViews

enum TabEnum: String, CaseIterable, Hashable {
	case today
	case games
	case sources
	case library
	case search
	case settings
	case certificates
	
	var title: String { xsignText(titleKey) }

    private var titleKey: String {
        switch self {
		case .today:        return "اليوم"
		case .games:        return "الألعاب"
		case .sources:     	return "التطبيقات"
		case .library: 		return "التوقيع"
		case .search:       return "بحث"
		case .settings: 	return "الإعدادات"
		case .certificates:	return "الشهادات"
		}
	}
	
	var icon: String {
		switch self {
		case .today:        return "doc.text.image"
		case .games:        return "paperplane.fill"
		case .sources: 		return "square.stack.3d.up.fill"
		case .library: 		return "arcade.stick"
		case .search:       return "magnifyingglass"
		case .settings: 	return "gearshape.fill"
		case .certificates: return "person.text.rectangle"
		}
	}
	
	@ViewBuilder
	var tabLabel: some View {
		switch self {
		case .games:
			Label {
				Text(title)
			} icon: {
				Image("XSignGames").renderingMode(.template)
			}
		case .library:
			Label {
				Text(title)
			} icon: {
				Image("XSignSigning").renderingMode(.template)
			}
		default:
			Label(title, systemImage: icon)
		}
	}
	
	@ViewBuilder
	static func view(for tab: TabEnum) -> some View {
		switch tab {
		case .today:        AppStoreTodayView()
		case .games:        AppStoreGamesView()
		case .sources:      SourcesView()
		case .library:      LibraryView()
		case .search:       AppStoreSearchView()
		case .settings:     SettingsView()
		case .certificates: NBNavigationView(.localized("Certificates")) { CertificatesView() }
		}
	}
	
	static var defaultTabs: [TabEnum] {
		return [
			.today,
			.games,
			.sources,
			.library,
			.search
		]
	}
	
    static func visibleTabs(for dashboard: XSignDashboardConfig?) -> [Self] {
        guard let dashboard, let order = dashboard.tab_order else { return defaultTabs }
        if (dashboard.experience_version ?? 0) < 3, dashboard.catalog_profile == nil, order == ["today", "apps", "games", "search", "library"] {
            return defaultTabs
        }
        var seen = Set<Self>()
        let tabs = order.compactMap { value -> Self? in
            guard let tab = Self(rawValue: value == "apps" ? "sources" : value),
                  defaultTabs.contains(tab), seen.insert(tab).inserted else { return nil }
            return tab
        }
        return tabs.isEmpty ? defaultTabs : tabs
    }

	static var customizableTabs: [TabEnum] {
		return []
	}
}
