//
//  BSSourcesView.swift
//  Feather
//
//  BatSign's Sources surface. BatSign's own storage, fetching and refresh rules
//  are untouched underneath — this is the list, in BatSign's shape.
//

import SwiftUI
import CoreData
import AltSourceKit
import NimbleViews

struct BSSourcesView: View {
	@StateObject private var _viewModel = SourcesViewModel.shared

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _allSources: FetchedResults<AltSource>

	/// The sources this screen manages: the ones the user added.
	///
	private var _sources: [AltSource] {
		_allSources
	}

	@State private var _isAddingPresenting = false
	@State private var _autoSourceOverrides: [String: Bool] = UserDefaults.standard.dictionary(forKey: "BatSign.sourceAutoUpdate") as? [String: Bool] ?? [:]
	@State private var _refreshDates: [String: Date] = UserDefaults.standard.dictionary(forKey: "BatSign.sourceRefreshDates") as? [String: Date] ?? [:]

	private var _countText: String {
		_sources.count == 1 ? "1 source" : "\(_sources.count) sources"
	}

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					Text(_countText.uppercased())
						.font(BSStore.eyebrowFont)
						.foregroundStyle(BSStore.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)

					if _sources.isEmpty {
							// The storefront's own empty state: one icon, one line, and
							// no blue button. The way in is the corner + in the bar.
							VStack(spacing: 12) {
								Image(systemName: "shippingbox")
									.font(.system(size: 34, weight: .regular))
									.foregroundStyle(BSStore.tertiary)
								Text("No Sources")
									.font(.system(size: 20, weight: .bold, design: .rounded))
								Text("A source is where apps come from. Add one with the + button and its apps appear here.")
								.font(.system(size: 14))
								.foregroundStyle(BSStore.secondary)
								.multilineTextAlignment(.center)
								.padding(.horizontal, 24)
						}
						.frame(maxWidth: .infinity)
						.padding(.vertical, 48)
					}

					if !_sources.isEmpty {
						BSAppListStyleContainer {
							ForEach(Array(_sources.enumerated()), id: \.element.objectID) { index, source in
							NavigationLink {
								SourceAppsView(object: [source], viewModel: _viewModel)
							} label: {
								_sourceRow(source)
							}
							.buttonStyle(.plain)
							.contextMenu {
								_sourceContextMenu(source)
							}

							if index < _sources.count - 1 {
								Rectangle()
									.fill(Color.primary.opacity(0.08))
									.frame(height: 0.5)
									.padding(.leading, 76)
							}
							}
						}
					}
				}
				.padding(.horizontal, 16)
				.padding(.top, 4)
				.padding(.bottom, 28)
			}
			.scrollIndicators(.hidden)
			.bsScreen()
				.navigationTitle("Sources")
				.navigationBarTitleDisplayMode(.large)
				.toolbar {
					ToolbarItem(placement: .topBarTrailing) {
						BSCornerButton(glyph: .plus, label: "Add Source") {
							_isAddingPresenting = true
						}
					}
				}
				.refreshable {
				await _viewModel.fetchSources(_sources, refresh: true)
				_markRefreshed()
			}
			.sheet(isPresented: $_isAddingPresenting) {
				SourcesAddView()
			}
		}
		.task(id: Array(_sources)) {
			await _viewModel.fetchSources(_sources)
			_autoSourceOverrides = UserDefaults.standard.dictionary(forKey: "BatSign.sourceAutoUpdate") as? [String: Bool] ?? [:]
		}
	}

}

// MARK: - The row

extension BSSourcesView {
	private func _sourceRow(_ source: AltSource) -> some View {
		HStack(spacing: 14) {
			WSAppIcon(url: source.iconURL, size: 46, cornerRadius: 10.5)

			VStack(alignment: .leading, spacing: 2) {
				Text(source.name ?? "Source")
					.font(.system(size: 17, weight: .semibold))
					.foregroundStyle(.primary)
					.lineLimit(1)

				Text(verbatim: _caption(source))
					.font(.system(size: 15))
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}

			Spacer(minLength: 8)

			Image(systemName: "chevron.forward")
				.font(.footnote.weight(.semibold))
				.foregroundStyle(.tertiary)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
		.contentShape(Rectangle())
	}

	private func _caption(_ source: AltSource) -> String {
		let count = _viewModel.sources[source]?.apps.count
		let autoOff = !(_autoSourceOverrides[source.identifier ?? ""] ?? true)

		let base: String
		if let count {
			base = count == 1 ? "1 app" : "\(count) apps"
		} else if !_viewModel.isFinished {
			return "Refreshing…"
		} else {
			return "Couldn't refresh"
		}

		let suffix = autoOff ? " • Auto-Updates Off" : ""
		if let last = _refreshDates[source.identifier ?? ""] {
			return "\(base) • \(last.formatted(.relative(presentation: .named)))\(suffix)"
		}
		return base + suffix
	}

	@ViewBuilder
	private func _sourceContextMenu(_ source: AltSource) -> some View {
		let identifier = source.identifier ?? ""
		let autoEnabled = _autoSourceOverrides[identifier] ?? true

		Button {
			let now = !autoEnabled
			_autoSourceOverrides[identifier] = now
			AutoUpdateManager.shared.setSourceAutoUpdate(now, for: source)
		} label: {
			Label(autoEnabled ? "Disable Auto-Updates" : "Enable Auto-Updates", systemImage: "automatic")
		}

		Divider()

		Button(role: .destructive) {
			Storage.shared.deleteSource(for: source)
		} label: {
			Label("Remove Source", systemImage: "trash")
		}
	}

	private func _markRefreshed() {
		for source in _sources {
			_refreshDates[source.identifier ?? ""] = Date()
		}
		UserDefaults.standard.set(_refreshDates, forKey: "BatSign.sourceRefreshDates")
	}
}

/// One glass pane holding a run of rows, the way BatSign groups its lists.
struct BSAppListStyleContainer<Content: View>: View {
	@ViewBuilder var content: Content

	var body: some View {
		LazyVStack(spacing: 0) {
			content
		}
		.bsCard(cornerRadius: BS.radiusCard)
		.padding(.horizontal, -6)
	}
}
