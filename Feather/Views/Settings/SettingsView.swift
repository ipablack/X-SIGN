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

	@ObservedObject private var ownerRemote = XSignRemoteManager.shared
    @State private var syncingOwner = false

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
					NavigationLink(destination: InstallationView()) {
						Label(.localized("Installation"), systemImage: "arrow.down.circle")
					}
				} footer: {
					Text("إعداد التثبيت المحلي وخيارات تعديل التطبيقات.")
				}
                Section {
                    NavigationLink(destination:XSignAppUpdateView()) { Label("تحديث XSign",systemImage:"arrow.down.circle.fill") }
                }
                Section {
                    HStack { Text("مراجعة لوحة التحكم"); Spacer(); Text(String(ownerRemote.currentRevisionID)).foregroundStyle(.secondary) }
                    Text(ownerRemote.remoteSyncStatus).font(.footnote).foregroundStyle(.secondary)
                    if let date = ownerRemote.lastRemoteSync {
                        Text(date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        guard !syncingOwner else { return }
                        syncingOwner = true
                        Task {
                            await ownerRemote.fetchRemoteConfig()
                            syncingOwner = false
                        }
                    } label: { Label(syncingOwner ? "جارٍ المزامنة…" : "مزامنة إعدادات IPA BLACK", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(syncingOwner)
                } footer: {
                    Text("تصل إعدادات المظهر والمصادر والتحديثات من IPA BLACK. قارن رقم المراجعة مع المنشور في اللوحة.")
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
