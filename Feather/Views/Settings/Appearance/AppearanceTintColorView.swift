//
//  AppearanceTintColorView.swift
//  Feather
//

import SwiftUI
import AltSourceKit

struct AppearanceTintColorView: View {
    @AppStorage("Feather.userTintColor") private var selectedColorHex: String = "#005BBB"
    @AppStorage("Feather.hasCustomTintColor") private var hasCustomTintColor = false

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: selectedColorHex) },
            set: { color in
                hasCustomTintColor = true
                selectedColorHex = color.toHex()
            }
        )
    }

    var body: some View {
        ColorPicker("لون التطبيق", selection: colorBinding, supportsOpacity: false)
    }
}
