//
//  SettingsView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import NimbleViews
import UIKit
import Darwin
import IDeviceSwift

// MARK: - View
struct SettingsView: View {
    
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Settings")) {
			Form {
				_feedback()
                
				Section {
					NavigationLink(destination: AppearanceView()) {
						Label(.localized("Appearance"), systemImage: "paintbrush")
					}
				}
                
				NBSection(.localized("Features")) {
					NavigationLink(destination: ConfigurationView()) {
						Label(.localized("Signing Options"), systemImage: "signature")
					}
					NavigationLink(destination: ArchiveView()) {
						Label(.localized("Archive & Compression"), systemImage: "archivebox")
					}
					NavigationLink(destination: InstallationView()) {
						Label(.localized("Installation"), systemImage: "arrow.down.circle")
					}
				} footer: {
					Text(.localized("Configure the apps way of installing, its zip compression levels, and custom modifications to apps."))
				}
                
				Section {
					NavigationLink(destination: ResetView()) {
						Label(.localized("Reset"), systemImage: "trash")
					}
				} footer: {
					Text(.localized("Reset the applications sources, certificates, apps, and general contents."))
				}
			}
		}
	}
}

// MARK: - View extension
extension SettingsView {
	@ViewBuilder
	private func _feedback() -> some View {
		Section {
			NavigationLink(destination: AboutView()) {
				Label {
					Text(verbatim: .localized("About %@", arguments: Bundle.main.name))
				} icon: {
					FRAppIconView(size: 23)
				}
			}
		}
	}
}
