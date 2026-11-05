//
//  AppearanceView.swift
//  Feather
//

import SwiftUI
import NimbleViews
import UIKit

struct AppearanceView: View {
    @AppStorage("Feather.userInterfaceStyle")
    private var userInterfaceStyle: Int = UIUserInterfaceStyle.unspecified.rawValue

    var body: some View {
        NBList("المظهر") {
            Section {
                Picker("المظهر", selection: $userInterfaceStyle) {
                    Text("النظام").tag(UIUserInterfaceStyle.unspecified.rawValue)
                    Text("فاتح").tag(UIUserInterfaceStyle.light.rawValue)
                    Text("داكن").tag(UIUserInterfaceStyle.dark.rawValue)
                }
                .pickerStyle(.segmented)
            }

            Section {
                AppearanceTintColorView()
            }
        }
    }
}
