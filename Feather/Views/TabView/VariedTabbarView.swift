//
//  VariedTabbarView.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import SwiftUI

struct VariedTabbarView: View {
	@Binding var selection: TabEnum
	
	var body: some View {
		if #available(iOS 18, *) {
			ExtendedTabbarView(selection: $selection)
		} else {
			TabbarView(selectedTab: $selection)
		}
	}
}
