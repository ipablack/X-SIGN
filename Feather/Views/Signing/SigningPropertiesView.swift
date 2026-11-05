//
//  SigningAppPropertiesView.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct SigningPropertiesView: View {
	@Environment(\.dismiss) var dismiss
	
	@State private var text: String = ""
	
	var saveButtonDisabled: Bool {
		text.trimmingCharacters(in: .whitespacesAndNewlines) == initialValue || validationMessage != nil
	}

    private var validationMessage: String? { XSignAppMetadata.errorMessage(for: text, field: field) }
	
	var title: String
	var initialValue: String 
	@Binding var bindingValue: String?
    var field: XSignAppMetadata.Field = .name
    var originalValue: String? = nil
	
	// MARK: Body
	var body: some View {
		NBList(title) {
			TextField(initialValue, text: $text)
				.textInputAutocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(field == .version ? .numbersAndPunctuation : .default)
            if text != initialValue, let message = validationMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            if let originalValue {
                Button("استخدام القيمة الأصلية: \(originalValue)") {
                    bindingValue = nil
                    dismiss()
                }.font(.footnote)
            }
		}
		.toolbar {
			NBToolbarButton(
				.localized("Save"),
				style: .text,
				placement: .topBarTrailing,
				isDisabled: saveButtonDisabled
			) {
				if !saveButtonDisabled {
					bindingValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
					dismiss()
				}
			}
		}
		.onAppear {
			text = initialValue
		}
	}
}
