//
//  SigningEntitlementsView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//

import SwiftUI
import NimbleViews
import UniformTypeIdentifiers // إضافة مكتبة الأنواع

// إضافة الامتداد لتعريف الأنواع المفقودة وحل الخطأ
extension UTType {
    static var plist: UTType {
        UTType(filenameExtension: "plist") ?? .propertyList
    }
    
    static var entitlements: UTType {
        UTType(filenameExtension: "entitlements") ?? .plainText
    }
}

// MARK: - View
struct SigningEntitlementsView: View {
	@State private var _isAddingPresenting = false
	
	@Binding var bindingValue: URL?
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Entitlements")) {
			if let ent = bindingValue {
				Text(ent.lastPathComponent)
					.swipeActions() {
						Button(.localized("Delete")) {
							FileManager.default.deleteStored(ent) { _ in
								bindingValue = nil
							}
						}
					}
			} else {
				Button(.localized("Select entitlements file")) {
					_isAddingPresenting = true
				}
			}
		}
		.sheet(isPresented: $_isAddingPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes:  [.xmlPropertyList, .plist, .entitlements],
				onDocumentsPicked: { urls in
					guard let selectedFileURL = urls.first else { return }
					
					FileManager.default.moveAndStore(selectedFileURL, with: "FeatherEntitlement") { url in
						bindingValue = url
					}
				}
			)
			.ignoresSafeArea()
		}
	}
}
