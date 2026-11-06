//
//  SourceAppsView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import UIKit

// MARK: - Extension: View (Enil)
extension SourceAppsView {
	enum SortOption: String, CaseIterable {
		case `default` = "default"
		case name
		case date

		var displayName: String {
			switch self {
			case .default:  .localized("Default")
			case .name: 	.localized("Name")
			case .date: 	.localized("Date")
			}
		}
	}
}

// MARK: - View
struct SourceAppsView: View {
	@AppStorage("Feather.sortOptionRawValue") private var _sortOptionRawValue: String = SortOption.default.rawValue
	@AppStorage("Feather.sortAscending") private var _sortAscending: Bool = true

	@State private var _sortOption: SortOption = .default
	@State private var _selectedRoute: SourceAppRoute?

	@State var isLoading = true
	@State var hasLoadedOnce = false
	@State private var _searchText = ""

	private var _navigationTitle: String {
		if object.count == 1 {
			object[0].name ?? .localized("Unknown")
		} else {
			.localized("%lld Sources", arguments: object.count)
		}
	}

	var object: [AltSource]
	@ObservedObject var viewModel: SourcesViewModel
	@State private var _sourceContexts: [SourceRepositoryContext]?

	// MARK: Body
	var body: some View {
		ZStack {
			if
				let _sourceContexts,
				!_sourceContexts.isEmpty
			{
				SourceAppsTableRepresentableView(
					sourceContexts: _sourceContexts,
					searchText: $_searchText,
					sortOption: $_sortOption,
					sortAscending: $_sortAscending,
					onSelect: {self._selectedRoute = $0}
				)
				.ignoresSafeArea()
			} else {
				ProgressView()
			}
		}
		.navigationTitle(_navigationTitle)
		.searchable(text: $_searchText, placement: .platform())
		.xsignToolbarTitleMenu {
			if
				let _sourceContexts,
				_sourceContexts.count == 1
			{
				if let url = _sourceContexts[0].repository.website {
					Button {
						UIApplication.open(url)
					} label: {
						Label(.localized("Visit Website"), systemImage: "globe")
					}
				}

				if let url = _sourceContexts[0].repository.patreonURL {
					Button {
						UIApplication.open(url)
					} label: {
						Label(.localized("Visit Patreon"), systemImage: "dollarsign.circle")
					}
				}
			}

		}
		.toolbar {
			NBToolbarMenu(
				systemImage: "line.3.horizontal.decrease",
				style: .icon,
				placement: .navigationBarTrailing
			) {
				_sortActions()
			}
		}
		.onAppear {
			if !hasLoadedOnce, viewModel.isFinished {
				_load()
				hasLoadedOnce = true
			}
			_sortOption = SortOption(rawValue: _sortOptionRawValue) ?? .default
		}
		.onChange(of: viewModel.isFinished) { _ in
			_load()
		}
		.onChange(of: _sortOption) { newValue in
			_sortOptionRawValue = newValue.rawValue
		}
		.navigationDestinationIfAvailable(item: $_selectedRoute) { route in
			SourceAppsDetailView(
				sourceURL: route.sourceURL,
				source: route.source,
				app: route.app
			)
		}
	}

	private func _load() {
		isLoading = true

		Task {
			let loadedSources = object.compactMap { source -> SourceRepositoryContext? in
				guard let repository = viewModel.sources[source] else { return nil }
				return SourceRepositoryContext(sourceURL: source.sourceURL, repository: repository)
			}
			_sourceContexts = loadedSources
			withAnimation(.easeIn(duration: 0.2)) {
				isLoading = false
			}
		}
	}

	struct SourceRepositoryContext: Equatable {
		let sourceURL: URL?
		let repository: ASRepository

		static func == (lhs: SourceRepositoryContext, rhs: SourceRepositoryContext) -> Bool {
			lhs.sourceURL == rhs.sourceURL &&
			lhs.repository.id == rhs.repository.id &&
			lhs.repository.name == rhs.repository.name &&
			lhs.repository.apps.map { "\($0.currentUniqueId)|\($0.currentVersion ?? "")" } ==
			rhs.repository.apps.map { "\($0.currentUniqueId)|\($0.currentVersion ?? "")" }
		}
	}

	struct SourceAppRoute: Identifiable, Hashable {
		let sourceURL: URL?
		let source: ASRepository
		let app: ASRepository.App
		let id: String = UUID().uuidString
	}
}

// MARK: - Extension: View (Sort)
extension SourceAppsView {
	@ViewBuilder
	private func _sortActions() -> some View {
		Section(.localized("Filter by")) {
			ForEach(SortOption.allCases, id: \.displayName) { opt in
				_sortButton(for: opt)
			}
		}
	}

	private func _sortButton(for option: SortOption) -> some View {
		Button {
			if _sortOption == option {
				_sortAscending.toggle()
			} else {
				_sortOption = option
				_sortAscending = true
			}
		} label: {
			HStack {
				Text(option.displayName)
				Spacer()
				if _sortOption == option {
					Image(systemName: _sortAscending ? "chevron.up" : "chevron.down")
				}
			}
		}
	}
}

import SwiftUI

extension View {
	@ViewBuilder
	func navigationDestinationIfAvailable<Item: Identifiable & Hashable, Destination: View>(
		item: Binding<Item?>,
		@ViewBuilder destination: @escaping (Item) -> Destination
	) -> some View {
		if #available(iOS 17, *) {
			self.navigationDestination(item: item, destination: destination)
        } else {
            self.background(
                NavigationLink(isActive: Binding(get: { item.wrappedValue != nil },
                    set: { if !$0 { item.wrappedValue=nil } })) {
                    if let value=item.wrappedValue { destination(value) }
                } label: { EmptyView() }.hidden()
            )
        }
    }
}
