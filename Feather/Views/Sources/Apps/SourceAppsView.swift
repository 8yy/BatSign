//
//  SourceAppsView.swift
//  Feather
//
//  One source's catalogue. It is drawn exactly like the Apps tab — the same
//  rows, the same pill, the same large title that collapses on scroll — so a
//  source's page and the catalogue can never look like two different apps.
//
//  It used to be a UIKit table with `ignoresSafeArea`, which is why it read as
//  the old design and why going into it had none of the standard navigation
//  behaviour. This is the same data on the storefront's own components.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import UIKit

// MARK: - Sort
extension SourceAppsView {
	enum SortOption: String, CaseIterable {
		case `default` = "default"
		case name
		case date

		var displayName: String {
			switch self {
			case .default:	.localized("Default")
			case .name:		.localized("Name")
			case .date:		.localized("Date")
			}
		}
	}
}

// MARK: - View
struct SourceAppsView: View {
	@AppStorage("Feather.sortOptionRawValue") private var _sortOptionRawValue: String = SortOption.default.rawValue
	@AppStorage("Feather.sortAscending") private var _sortAscending: Bool = true

	@State private var _sortOption: SortOption = .default
	@State private var _searchText = ""
	@State private var _sourceContexts: [SourceRepositoryContext]?

	@ObservedObject private var _bulk = BSBulkSign.shared

	/// Whether apps are being picked to fetch and sign as one run.
	@State private var _isSelecting = false
	/// The picked apps, by the catalogue's own row id.
	@State private var _selection: Set<String> = []

	var object: [AltSource]
	@ObservedObject var viewModel: SourcesViewModel

	private var _navigationTitle: String {
		if object.count == 1 {
			object.first?.name ?? .localized("Unknown")
		} else {
			.localized("%lld Sources", arguments: object.count)
		}
	}

	/// Built from the same index the Apps tab uses, then narrowed by the search
	/// field and ordered by the sort menu. Filtering is a plain loop over an
	/// already-flattened array — no repository is walked per keystroke.
	private var _items: [BSAppItem] {
		var items = BSAppIndex.build(sources: object, repositories: viewModel.sources)

		let query = _searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		if !query.isEmpty {
			items = items.filter {
				$0.app.currentName.localizedCaseInsensitiveContains(query)
					|| ($0.app.developer ?? "").localizedCaseInsensitiveContains(query)
					|| ($0.app.category ?? "").localizedCaseInsensitiveContains(query)
			}
		}

		switch _sortOption {
		case .default:
			break
		case .name:
			items.sort {
				$0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending
			}
		case .date:
			items.sort {
				($0.app.currentDate?.date ?? .distantPast) < ($1.app.currentDate?.date ?? .distantPast)
			}
		}

		if _sortOption != .default, !_sortAscending {
			items.reverse()
		}
		return items
	}

	// MARK: Body
	var body: some View {
		Group {
			if _sourceContexts == nil, !viewModel.isFinished {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if _items.isEmpty {
				ScrollView {
					WSEmptyState(
						icon: "square.grid.2x2",
						title: _searchText.isEmpty ? "No Apps" : "No Matches",
						message: _searchText.isEmpty
							? "This source has not published any apps yet."
							: "No app matches “\(_searchText)”."
					)
					.padding(.horizontal, 16)
					.padding(.top, 40)
				}
			} else {
				ScrollView {
					VStack(alignment: .leading, spacing: 16) {
						// The run, above the catalogue it was picked from. A source's
						// apps are the usual place a multi-sign run starts, and the
						// progress belongs on the screen the person is still looking at.
						BSBulkSignStrip()

						BSAppList(items: _items, picking: _isSelecting ? $_selection : nil)
					}
					.padding(.top, 4)
					.padding(.bottom, 28)
				}
				.scrollIndicators(.hidden)
			}
		}
		.bsScreen()
		.safeAreaInset(edge: .bottom) {
			if _isSelecting {
				BSBulkActionBar(
					count: _selection.count,
					title: _bulkTitle,
					action: _startBulkDownload,
					selectAll: _toggleSelectAll,
					cancel: _endSelecting
				)
			}
		}
		.animation(.snappy(duration: 0.22), value: _isSelecting)
		.navigationTitle(_navigationTitle)
		.navigationBarTitleDisplayMode(.large)
		// The Sources tab hides its own bar so its masthead can lead. A pushed
		// page has to say so explicitly, or it inherits that hidden bar and
		// arrives with no back button.
		.toolbar(.visible, for: .navigationBar)
		.searchable(
			text: $_searchText,
			placement: .navigationBarDrawer(displayMode: .always),
			prompt: Text("Apps, developers")
		)
		.toolbarTitleMenu {
			if let first = _sourceContexts?.first, object.count == 1 {
				if let url = first.repository.website {
					Button(.localized("Visit Website"), systemImage: "globe") {
						UIApplication.open(url)
					}
				}

				if let url = first.repository.patreonURL {
					Button(.localized("Visit Patreon"), systemImage: "dollarsign.circle") {
						UIApplication.open(url)
					}
				}
			}

			Divider()

			Button(.localized("Copy"), systemImage: "doc.on.doc") {
				guard !object.isEmpty else {
					UIAlertController.showAlertWithOk(
						title: .localized("Error"),
						message: .localized("No sources to copy")
					)
					return
				}
				UIPasteboard.general.string = object.compactMap {
					$0.sourceURL?.absoluteString
				}.joined(separator: "\n")
				UIAlertController.showAlertWithOk(
					title: .localized("Success"),
					message: .localized("Sources copied to clipboard")
				)
			}
		}
		.toolbar {
			ToolbarItem(placement: .topBarLeading) {
				if !_items.isEmpty {
					// One word, in the corner the system puts it in: this screen has
					// one mode the other screens do not, and picking several apps to
					// fetch and sign at once is it.
					Button(_isSelecting ? "Done" : "Select") {
						BSHaptics.tap()
						withAnimation(.snappy(duration: 0.22)) {
							_isSelecting.toggle()
							if !_isSelecting { _selection.removeAll() }
						}
					}
					.font(.body.weight(_isSelecting ? .semibold : .regular))
				}
			}

			NBToolbarMenu(
				systemImage: "line.3.horizontal.decrease",
				style: .icon,
				placement: .topBarTrailing
			) {
				_sortActions()
			}
		}
		.onAppear {
			_sortOption = SortOption(rawValue: _sortOptionRawValue) ?? .default
			_load()
		}
		.onChange(of: viewModel.isFinished) { _ in
			_load()
		}
		.onChange(of: _sortOption) { newValue in
			_sortOptionRawValue = newValue.rawValue
		}
	}

	private func _load() {
		let loadedSources = object.compactMap { source -> SourceRepositoryContext? in
			guard let repository = viewModel.sources[source] else { return nil }
			return SourceRepositoryContext(sourceURL: source.sourceURL, repository: repository)
		}
		_sourceContexts = loadedSources
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

// MARK: - Picking several

extension SourceAppsView {
	private var _pickedItems: [BSAppItem] {
		_items.filter { _selection.contains($0.id) }
	}

	private var _bulkTitle: String {
		_selection.count == 1 ? "Download & Sign 1 App" : "Download & Sign \(_selection.count) Apps"
	}

	/// One run: every picked app is fetched and signed, one after another.
	///
	/// The transfers are the app's own download pipeline and the signing is the
	/// app's own queue, so what a single app does when it is fetched from a
	/// source — import, sign, install, live card, outcome popup — is exactly what
	/// each app of the run does. What is different is only that they run in turn
	/// and report their place in the run while they do.
	private func _startBulkDownload() {
		let items = _pickedItems
		guard !items.isEmpty else { return }

		let started = BSBulkSign.shared.downloadAndSign(items, title: _bulkTitle)
		_endSelecting()

		if started == 0 {
			UINotificationFeedbackGenerator().notificationOccurred(.warning)
		}
	}

	private func _toggleSelectAll() {
		withAnimation(.snappy(duration: 0.2)) {
			if _selection.count >= _items.count {
				_selection.removeAll()
			} else {
				_selection = Set(_items.map(\.id))
			}
		}
	}

	private func _endSelecting() {
		withAnimation(.snappy(duration: 0.22)) {
			_isSelecting = false
			_selection.removeAll()
		}
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

extension View {
	@ViewBuilder
	func navigationDestinationIfAvailable<Item: Identifiable & Hashable, Destination: View>(
		item: Binding<Item?>,
		@ViewBuilder destination: @escaping (Item) -> Destination
	) -> some View {
		if #available(iOS 17, *) {
			self.navigationDestination(item: item, destination: destination)
		} else {
			self
		}
	}
}
