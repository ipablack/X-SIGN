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
                HStack(spacing: 12) {
                    FRAppIconView(size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("XSign").font(.headline)
                        Text("معاينة المظهر واللون").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "paintbrush.pointed.fill").foregroundStyle(Color.accentColor)
                }
                .padding(12)
                .xsignSurface()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
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
        .xsignListBackground()
    }
}
