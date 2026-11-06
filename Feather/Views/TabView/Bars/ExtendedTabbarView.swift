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

    var body: some View { TabbarView() }
}
