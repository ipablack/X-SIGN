//
//  SourcesAddView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import NimbleViews
import AltSourceKit
import NimbleJSON
import OSLog
import UIKit.UIImpactFeedbackGenerator

// MARK: - View
struct SourcesAddView: View {
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	@Environment(\.dismiss) var dismiss

	@State private var _filteredRecommendedSourcesData: [(url: URL, data: ASRepository)] = []
	private func _refreshFilteredRecommendedSourcesData() {
		let filtered = recommendedSourcesData
			.filter { (url, data) in
				let id = data.id ?? url.absoluteString
				return !Storage.shared.sourceExists(id)
			}
			.sorted { lhs, rhs in
				let lhsName = lhs.data.name ?? ""
				let rhsName = rhs.data.name ?? ""
				return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
			}
		_filteredRecommendedSourcesData = filtered
	}

	@State var recommendedSourcesData: [(url: URL, data: ASRepository)] = []
	let recommendedSources: [URL] = []

	@State private var _isImporting = false
	@State private var _sourceURL = ""

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Add Source"), displayMode: .inline) {
			Form {
				NBSection(.localized("Source URL")) {
					TextField(.localized("Enter Source URL"), text: $_sourceURL)
						.keyboardType(.URL)
						.textInputAutocapitalization(.never)
				} footer: {
					Text(.localized("أضف رابط HTTPS لسورس AltStore أو JSON متوافق."))
					Text(verbatim: "[\(String.localized("Learn more about how to setup a repository..."))](https://faq.altstore.io/developers/make-a-source)")
				}

				Section {
					Button {
						_isImporting = true
						_fetchImportedRepositories(UIPasteboard.general.string) {
							dismiss()
						}
					} label: {
						Label(.localized("Import"), systemImage: "square.and.arrow.down")
					}

				} footer: {
					Text(.localized("Supports importing from KravaSign/MapleSign and ESign."))
				}

				if !_filteredRecommendedSourcesData.isEmpty {
					NBSection(.localized("Featured")) {
						ForEach(_filteredRecommendedSourcesData, id: \.url) { (url, source) in
							HStack(spacing: 2) {
								FRIconCellView(
									title: source.name ?? .localized("Unknown"),
									subtitle: url.absoluteString,
									iconUrl: source.currentIconURL
								)
								Button {
									Storage.shared.addSource(url, repository: source) { _ in
										_refreshFilteredRecommendedSourcesData()
									}
								} label: {
									NBButton(.localized("Add"), systemImage: "arrow.down", style: .text)
								}
							}
						}
					} footer: {
						Text(.localized("Open an [issue](https://github.com/claration/Feather/issues) on GitHub if you want your source to be featured."))
					}
				}
			}
			.toolbar {
				NBToolbarButton(role: .cancel)

				ToolbarItem(placement: .confirmationAction) {
					if !_isImporting {
						Button(.localized("Save")) {
							FR.handleSource(_sourceURL) { dismiss() }
						}
						.disabled(_sourceURL.isEmpty)
					} else {
						ProgressView()
					}
				}
			}
			.animation(.default, value: _filteredRecommendedSourcesData.map { $0.data.id ?? "" })
			.task {
				await _fetchRecommendedRepositories()
			}
		}
	}

	private func _fetchRecommendedRepositories() async {
		let fetched = await _concurrentFetchRepositories(from: recommendedSources)
		await MainActor.run {
			recommendedSourcesData = fetched
			_refreshFilteredRecommendedSourcesData()
		}
	}

	private func _fetchImportedRepositories(
		_ code: String?,
		competion: @escaping () -> Void
	) {
		guard let code else { return }

		let handler = ASDeobfuscator(with: code)
		let repoUrls = handler.decode().compactMap { URL(string: $0) }
		guard !repoUrls.isEmpty else { return }

		Task {
			let fetched = await _concurrentFetchRepositories(from: repoUrls)

			let dict = Dictionary(fetched, uniquingKeysWith: { first, _ in first })

			await MainActor.run {
				Storage.shared.addSources(repos: dict) { _ in
					competion()
				}
			}
		}
	}

	private func _concurrentFetchRepositories(
		from urls: [URL]
	) async -> [(url: URL, data: ASRepository)] {
		var results: [(url: URL, data: ASRepository)] = []

		await withTaskGroup(of: (URL, ASRepository)?.self) { group in
			for url in urls {
				group.addTask {
					await withCheckedContinuation { continuation in
						NBFetchService().fetch(from: url) { (result: RepositoryDataHandler) in
							switch result {
							case .success(let repo):
								continuation.resume(returning: (url, repo))
							case .failure(let error):
								Logger.misc.error("Failed to fetch source: \(error.localizedDescription)")
								continuation.resume(returning: nil)
							}
						}
					}
				}
			}
			for await result in group {
				if let (url, repo) = result {
					results.append((url: url, data: repo))
				}
			}
		}

		return results
	}

}
