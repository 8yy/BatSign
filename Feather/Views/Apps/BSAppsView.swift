//
//  BSAppsView.swift
//  Feather
//
//  BatSign's Apps surface: every app from every source, in BatSign's row shape,
//  with the same list backing the search tab.
//
//  Indexing is the whole performance story here. The list of every app is built
//  once whenever the source set changes and then filtered in a loop, instead of
//  being rebuilt from every repository on every keystroke.
//

import SwiftUI
import CoreData
import AltSourceKit
import NimbleViews

struct BSAppsView: View {
	/// The tab it is standing in. The list is the same one; only the heading
	/// differs, so search and the catalogue can never show different rows.
	var title: String = "Apps"

	@StateObject private var _viewModel = SourcesViewModel.shared

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	/// The flattened catalogue, rebuilt whenever the sources themselves change.
	@State private var _index: [BSAppItem] = []
	@State private var _isIndexing = true
	@State private var _query = ""
	@State private var _results: [BSAppItem] = []
	@State private var _searchTask: Task<Void, Never>?

	private var _isSearching: Bool {
		!_query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	private var _displayed: [BSAppItem] {
		_isSearching ? _results : _index
	}

	/// A source that has not been fetched yet is not an empty store. While any
	/// repository is still missing there is nothing honest to say, so the page
	/// keeps its spinner instead of claiming there are no apps.
	private var _isLoadingCatalogue: Bool {
		guard _index.isEmpty, !_sources.isEmpty else { return false }
		return _sources.contains { _viewModel.sources[$0] == nil }
	}

	/// Rebuild key: the stored sources *and* how many apps each loaded repository
	/// is currently reporting.
	///
	/// The second half matters. A cold launch renders before any repository has
	/// been fetched, and an index built from nothing is empty; `isFinished` is a
	/// plain property that publishes nothing, so a key made of it alone never
	/// changed and the empty list stayed empty. Counting each repository's apps
	/// makes the key move the moment a fetch lands.
	private var _indexKey: String {
		let identifiers = _sources.map { $0.identifier ?? $0.sourceURL?.absoluteString ?? "" }
		let loaded = _sources.map { source -> String in
			let count = _viewModel.sources[source]?.apps.count ?? -1
			return "\(source.identifier ?? source.sourceURL?.absoluteString ?? "")#\(count)"
		}
		return identifiers.joined(separator: ",") + "||" + loaded.joined(separator: ",")
	}

	var body: some View {
		NavigationStack {
			Group {
				if (_isIndexing || _isLoadingCatalogue) && _index.isEmpty {
					ProgressView()
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if _index.isEmpty {
					ScrollView {
						WSEmptyState(
							icon: "square.grid.2x2",
							title: "No Apps Yet",
							message: "Add a source and its apps will show up here."
						)
						.padding(.horizontal, 16)
						.padding(.top, 40)
					}
				} else if _displayed.isEmpty {
					ScrollView {
						WSEmptyState(
							icon: "magnifyingglass",
							title: "No Matches",
							message: "No app matches “\(_query)”."
						)
						.padding(.horizontal, 16)
						.padding(.top, 40)
					}
				} else {
					ScrollView {
						BSAppList(items: _displayed)
							.padding(.top, 4)
							.padding(.bottom, 28)
					}
					.scrollIndicators(.hidden)
				}
			}
			.bsScreen()
			.navigationTitle(title)
			.navigationBarTitleDisplayMode(.large)
			.searchable(
				text: $_query,
				placement: .navigationBarDrawer(displayMode: .always),
				prompt: Text("Apps, developers")
			)
			// No "+" here, and none on Search: a source is added from the Sources
			// tab's own top-right button and nowhere else, so the two catalogue
			// surfaces stay read-only.
			.refreshable {
				await _viewModel.fetchSources(_sources, refresh: true)
			}
		}
		.task(id: _indexKey) {
			await _buildIndex()
		}
		.onChange(of: _query) { newValue in
			_debouncedSearch(newValue)
		}
	}

	// MARK: Indexing

	private func _buildIndex() async {
		if _sources.isEmpty {
			_index = []
			_isIndexing = false
			return
		}

		let sources = Array(_sources)

		// A cold launch straight into this tab has nothing loaded, and
		// `isFinished` is `true` whenever nothing is in flight — so asking it
		// whether to fetch is asking the wrong question. Ask the data instead:
		// any source with no repository yet means there is something to fetch.
		// `fetchSources` is idempotent and already guards against overlap.
		if sources.contains(where: { _viewModel.sources[$0] == nil }) {
			await _viewModel.fetchSources(_sources)
		}

		let key = _indexKey
		if let cached = BSAppIndex.cached(for: key) {
			_index = cached
			_isIndexing = false
			if _isSearching {
				_results = BSAppIndex.filter(cached, query: _query.trimmingCharacters(in: .whitespacesAndNewlines))
			}
			return
		}

		// Built on the main actor and not in a detached task. `sources` holds
		// viewContext objects and `build` looks each one up in the repositories
		// dictionary, so that lookup and the `sourceURL` read have to happen where
		// those objects live. The rest of `build` is work over the already-decoded
		// `ASRepository` values, and it is the same build `SourceAppsView` runs
		// synchronously for a single source's page.
		let items = BSAppIndex.build(sources: sources, repositories: _viewModel.sources)

		// An empty catalogue for a source that has simply not finished loading is
		// not a result worth remembering.
		if !items.isEmpty || sources.isEmpty {
			BSAppIndex.cache(items, for: key)
		}
		_index = items
		_isIndexing = false

		if _isSearching {
			_results = BSAppIndex.filter(items, query: _query.trimmingCharacters(in: .whitespacesAndNewlines))
		}
	}

	/// Typing does not filter on the keystroke itself. A short pause is waited
	/// out first, so a fast typist produces one filter rather than six.
	private func _debouncedSearch(_ text: String) {
		_searchTask?.cancel()

		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			_results = []
			return
		}

		let index = _index
		_searchTask = Task {
			try? await Task.sleep(nanoseconds: 120_000_000)
			guard !Task.isCancelled else { return }

			let matches = await Task.detached(priority: .userInitiated) {
				BSAppIndex.filter(index, query: trimmed)
			}.value

			guard !Task.isCancelled else { return }
			_results = matches
		}
	}
}
