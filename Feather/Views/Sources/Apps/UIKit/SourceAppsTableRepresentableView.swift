//
//  SourceAppsTableView.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import AltSourceKit

// MARK: - Representable
struct SourceAppsTableRepresentableView: UIViewRepresentable {
	var sourceContexts: [SourceAppsView.SourceRepositoryContext]
	@Binding var searchText: String
	@Binding var sortOption: SourceAppsView.SortOption
	@Binding var sortAscending: Bool
	var onSelect: (SourceAppsView.SourceAppRoute) -> Void

	func makeUIView(context: Context) -> UITableView {
		let tableView = UITableView(frame: .zero, style: .plain)
		tableView.delegate = context.coordinator
		tableView.dataSource = context.coordinator
		tableView.register(XSignSourceAppTableCell.self, forCellReuseIdentifier: "AppCell")
		tableView.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: "SectionHeader")

		tableView.allowsSelection = true
		tableView.rowHeight = UITableView.automaticDimension
		tableView.estimatedRowHeight = 92

		if
			let firstSource = sourceContexts.first,
			sourceContexts.count == 1,
			let news = firstSource.repository.news,
			!news.isEmpty
		{
			let header = UIHostingController(rootView: SourceNewsView(news: news))
			context.coordinator.newsHost = header
			header.view.translatesAutoresizingMaskIntoConstraints = true
			header.view.backgroundColor = .clear
			let fixedHeight: CGFloat = 161
			let width = tableView.bounds.width
			header.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: fixedHeight))

			DispatchQueue.main.async {
				tableView.tableHeaderView = header.view
			}
		}

		tableView.alpha = 0

		UIView.transition(with: tableView,  duration: 0.5, options: [.transitionCrossDissolve], animations: {
			tableView.alpha = 1
		}, completion: nil)

		return tableView
	}

	func updateUIView(_ tableView: UITableView, context: Context) {
		context.coordinator.uiTableView = tableView

		let sourcesChanged = context.coordinator.sourceContexts != sourceContexts
		let searchChanged = context.coordinator.searchText != searchText
		let sortOptionChanged = context.coordinator.sortOption != sortOption
		let sortDirectionChanged = context.coordinator.sortAscending != sortAscending

		context.coordinator.sourceContexts = sourceContexts
		context.coordinator.searchText = searchText
		context.coordinator.sortOption = sortOption
		context.coordinator.sortAscending = sortAscending

		if sourcesChanged || searchChanged || sortOptionChanged || sortDirectionChanged {
			context.coordinator.invalidateCache()
		}
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(
			sourceContexts: sourceContexts,
			searchText: searchText,
			sortOption: sortOption,
			sortAscending: sortAscending,
			onSelect: onSelect
		)
	}
}

// MARK: - Representable Extension: Coordinator
extension SourceAppsTableRepresentableView { class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
	var sourceContexts: [SourceAppsView.SourceRepositoryContext]
	var searchText: String
	var sortOption: SourceAppsView.SortOption
	var sortAscending: Bool
	let onSelect: (SourceAppsView.SourceAppRoute) -> Void
	var newsHost: UIHostingController<SourceNewsView>?

	private var _groupedAppsByNameFirstLetter: [String: [SourceAppEntry]] = [:]
	private var _groupedAppsByDate: [String: [SourceAppEntry]] = [:]
	private var _sortedSectionTitles: [String] = []

	private var _cachedSortedApps: [SourceAppEntry] = []
	weak var uiTableView: UITableView?

	private var _allAppsWithSource: [SourceAppEntry] {
		sourceContexts.flatMap { context in
			context.repository.apps.map {
				SourceAppEntry(
					sourceURL: context.sourceURL,
					source: context.repository,
					app: $0
				)
			}
		}
	}

	private var _sortedApps: [SourceAppEntry] {
		if !_cachedSortedApps.isEmpty {
			return _cachedSortedApps
		}
		_cachedSortedApps = _calculateSortedApps()
		return _cachedSortedApps
	}

	init(
		sourceContexts: [SourceAppsView.SourceRepositoryContext],
		searchText: String,
		sortOption: SourceAppsView.SortOption,
		sortAscending: Bool,
		onSelect: @escaping (SourceAppsView.SourceAppRoute) -> Void
	) {
		self.sourceContexts = sourceContexts
		self.searchText = searchText
		self.sortOption = sortOption
		self.sortAscending = sortAscending
		self.onSelect = onSelect
		super.init()

		if sortOption != .default {
			invalidateCache()
		}
	}

	private func _calculateSortedApps() -> [SourceAppEntry] {
		let filtered = _allAppsWithSource.filter {
			searchText.isEmpty ||
			($0.app.id?.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US")) != nil) ||
				($0.app.name?.localizedCaseInsensitiveContains(searchText) ?? false) ||
				($0.app.description?.localizedCaseInsensitiveContains(searchText) ?? false) ||
				($0.app.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false) ||
				($0.app.localizedDescription?.localizedCaseInsensitiveContains(searchText) ?? false)
		}

		switch sortOption {
		case .default:
			_groupedAppsByDate = [:]
			_groupedAppsByNameFirstLetter = [:]
			_sortedSectionTitles = []
			return sortAscending ? filtered : filtered.reversed()
		case .date:
			let sorted = filtered.sorted {
				let d1 = $0.app.currentDate?.date ?? .distantPast
				let d2 = $1.app.currentDate?.date ?? .distantPast
				return sortAscending ? (d1 < d2) : (d1 > d2)
			}

			let formatter = DateFormatter()
			formatter.dateFormat = "MMMM d, yyyy"

			let grouped = Dictionary(grouping: sorted) {
				$0.app.currentDate?.date.stripTime() ?? .distantPast
			}

			let sortedDates = grouped.keys.sorted(by: { sortAscending ? $0 < $1 : $0 > $1 })

			_groupedAppsByDate = grouped.reduce(into: [:]) { result, pair in
				let key = formatter.string(from: pair.key)
				result[key] = pair.value
			}

			_sortedSectionTitles = sortedDates.map { formatter.string(from: $0) }
			return sorted
		case .name:
			let sorted = filtered.sorted {
				let n1 = $0.app.name ?? ""
				let n2 = $1.app.name ?? ""
				let comparison = n1.localizedCaseInsensitiveCompare(n2)
				return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
			}
			_groupedAppsByNameFirstLetter = Dictionary(grouping: sorted) {
				let first = $0.app.name?.trimmingCharacters(in: .whitespacesAndNewlines).first?.uppercased() ?? "#"
				return first.range(of: "[A-Z]", options: .regularExpression) != nil ? first : "#"
			}
			_sortedSectionTitles = _groupedAppsByNameFirstLetter.keys.sorted(by: {
				if $0 == "#" { return false }
				if $1 == "#" { return true }
				return sortAscending ? $0 < $1 : $0 > $1
			})
			return sorted
		}
	}

	func invalidateCache() {
		_cachedSortedApps = _calculateSortedApps()
		if let tableView = uiTableView {
			UIView.transition(with: tableView, duration: 0.3, options: [.transitionCrossDissolve], animations: {
				tableView.reloadData()
			})
		}
	}

	// MARK: TableView

	func numberOfSections(in tableView: UITableView) -> Int {
		switch sortOption {
		case .default: 1
		case .name, .date: _sortedSectionTitles.count
		}
	}

	func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		switch sortOption {
		case .default: _sortedApps.count
		case .name: _groupedAppsByNameFirstLetter[_sortedSectionTitles[section]]?.count ?? 0
		case .date: _groupedAppsByDate[_sortedSectionTitles[section]]?.count ?? 0
		}
	}

	func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let cell = tableView.dequeueReusableCell(withIdentifier: "AppCell", for: indexPath)
		guard let entry = entry(at: indexPath) else { return cell }
		let content = SourceAppsCellView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app)
		if #available(iOS 16.0, *) {
			cell.contentConfiguration = UIHostingConfiguration { content }
		} else {
			(cell as? XSignSourceAppTableCell)?.configure(content)
		}
		return cell
	}

	func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)
		guard let entry = entry(at: indexPath) else { return }
		onSelect(SourceAppsView.SourceAppRoute(sourceURL: entry.sourceURL, source: entry.source, app: entry.app))
	}

	func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
		let headerView = tableView.dequeueReusableHeaderFooterView(withIdentifier: "SectionHeader")
		let title: String

		switch sortOption {
		case .default: title = .localized("%lld Apps", arguments: _sortedApps.count)
		case .name, .date: title = _sortedSectionTitles[section]
		}

		if #available(iOS 16.0, *) {
			headerView?.contentConfiguration = UIHostingConfiguration {
				HStack {
					Text(verbatim: title)
					Spacer()
				}
				.font(.headline)
				.padding(.vertical, 2)
			}
		} else {
			headerView?.textLabel?.text = title
			headerView?.textLabel?.font = .preferredFont(forTextStyle: .headline)
			headerView?.textLabel?.adjustsFontForContentSizeCategory = true
		}

		return headerView
	}

	func sectionIndexTitles(for tableView: UITableView) -> [String]? {
		sortOption == .name ? _sortedSectionTitles : nil
	}

	func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
		_sortedSectionTitles.firstIndex(of: title) ?? 0
	}

	func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
		guard let entry = entry(at: indexPath) else { return nil }

		return UIContextMenuConfiguration(
			identifier: nil,
			previewProvider: nil
		) { _ in

			let downloadsMenu = UIMenu(
				title: .localized("Previous Versions"),
				image: UIImage(systemName: "square.and.arrow.down.on.square"),
				children: self._contextActions(for: entry.app, with: { version, url in
					if let url {
						_ = DownloadManager.shared.startDownload(
							from: url,
							id: entry.app.currentUniqueId,
							sourceProvenance: SourceAppProvenance(
								sourceURL: entry.sourceURL,
								repository: entry.source,
								app: entry.app,
								version: version
							)
						)
					}
				}, image: UIImage(systemName: "arrow.down"))
			)

			return UIMenu(children: [downloadsMenu])
		}
	}

	// MARK: Actions

	private func entry(at indexPath: IndexPath) -> SourceAppEntry? {
		let rows: [SourceAppEntry]
		switch sortOption {
		case .default: rows = _sortedApps
		case .name, .date:
			guard _sortedSectionTitles.indices.contains(indexPath.section) else { return nil }
			let title = _sortedSectionTitles[indexPath.section]
			rows = (sortOption == .name ? _groupedAppsByNameFirstLetter[title] : _groupedAppsByDate[title]) ?? []
		}
		guard rows.indices.contains(indexPath.row) else { return nil }
		return rows[indexPath.row]
	}

	private func _contextActions(
		for app: ASRepository.App,
		with action: @escaping (ASRepository.App.Version?, URL?) -> Void,
		image: UIImage?
	) -> [UIAction] {
		if let versions = app.versions, !versions.isEmpty {
			return versions.map { version in
				UIAction(
					title: version.version,
					image: image
				) { _ in
					action(version, version.downloadURL)
				}
			}
		} else {
			return [
				UIAction(
					title: app.currentVersion ?? "",
					image: image
				) { _ in
					action(nil, app.currentDownloadUrl)
				}
			]
		}
	}
}}

private struct SourceAppEntry {
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
}

/// UIHostingConfiguration starts at iOS 16; retain and reuse the iOS 15 host.
private final class XSignSourceAppTableCell: UITableViewCell {
	private var host: UIHostingController<SourceAppsCellView>?

	func configure(_ content: SourceAppsCellView) {
		if let host {
			host.rootView = content
			host.view.invalidateIntrinsicContentSize()
			return
		}
		let controller = UIHostingController(rootView: content)
		host = controller
		controller.view.backgroundColor = .clear
		controller.view.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(controller.view)
		NSLayoutConstraint.activate([
			controller.view.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
			controller.view.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
			controller.view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
			controller.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
		])
		attachHostIfNeeded()
	}

	override func didMoveToWindow() {
		super.didMoveToWindow()
		if window == nil, let host, host.parent != nil {
			host.willMove(toParent: nil)
			host.removeFromParent()
		} else {
			attachHostIfNeeded()
		}
	}

	private func attachHostIfNeeded() {
		guard window != nil, let host, host.parent == nil else { return }
		var responder: UIResponder? = self
		while let current = responder {
			if let parent = current as? UIViewController {
				parent.addChild(host)
				host.didMove(toParent: parent)
				break
			}
			responder = current.next
		}
	}
}
