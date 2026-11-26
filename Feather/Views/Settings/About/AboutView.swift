//
//  AboutView.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleJSON

// MARK: - Extension: Model
extension AboutView {
	struct CreditsModel: Codable, Hashable {
		let name: String
		let desc: String
		let imageUrl: String
	}
}

// MARK: - View
struct AboutView: View {
    private static let foundersChannel = URL(string: "https://t.me/hl00ss")!
	@State private var _credits: [CreditsModel] = [
		.init(
			name: "IPA BLACK",
			desc: "مؤسس xsign",
			imageUrl: "https://up6.cc/2026/10/179293542479681.jpeg"
		),
		.init(
			name: "حـور",
			desc: "مصممة الهوية البصرية",
			imageUrl: "https://up6.cc/2026/10/179293542483323.jpeg"
		)
	]
	
	// MARK: Body
	var body: some View {
        NBList(xsignText("حول XSign")) {
			Section {
				VStack {
					FRAppIconView(size: 72)
					
					Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "XSign")
						.font(.largeTitle.bold())
						.foregroundStyle(Color.accentColor)
					
					HStack(spacing: 4) {
						Text(.localized("Version"))
						Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
					}
					.font(.footnote)
					.foregroundStyle(.secondary)
				}
			}
			.frame(maxWidth: .infinity)
			.listRowBackground(EmptyView())
			
            NBSection(xsignText("المؤسسون")) {
				ForEach(_credits, id: \.name) { credit in
                    Link(destination: Self.foundersChannel) {
                        _credit(name: credit.name, desc: xsignText(credit.desc), imageUrl: credit.imageUrl)
                    }
				}
				.transition(.slide)
			}
		}
	}
}

// MARK: - Extension: view
extension AboutView {
	@ViewBuilder
	private func _credit(
		name: String,
		desc: String,
		imageUrl: String
	) -> some View {
		HStack {
			if let url = URL(string: imageUrl) {
				FRIconCellView(
					title: name,
					subtitle: desc,
					iconUrl: url,
					size: 45,
					isCircle: true
				)
			}
		}
	}
}
