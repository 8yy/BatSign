//
//  DiscoverView.swift
//  Feather
//
//  The storefront home, the App Store's Today: one full-width story card after
//  another as the user scrolls — artwork, eyebrow, big title, summary, and the
//  info strip with its own pill.
//
//  The cards are the whole page. There is no second grid and no section of
//  "shortcuts" competing with them, because the App Store's Today is a feed of
//  stories and nothing else — the sources that feed it live on their own tab.
//

import SwiftUI
import CoreData
import AltSourceKit
import NimbleViews

struct DiscoverView: View {
	@StateObject private var viewModel = SourcesViewModel.shared
	@State private var _isAddingPresenting = false
	@State private var _isSettingsPresenting = false
	@State private var _isUpdatesPresenting = false
	#if DEBUG
	@State private var _debugPage: BSDebugPage?
	#endif

	/// The feed owns the stack. A card pushes onto this path instead of
	/// carrying a link of its own, which is the only arrangement in which every
	/// card responds — including the ones a lazy stack has recycled.
	@State private var _path = NavigationPath()

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	// MARK: Body

		var body: some View {
			NavigationStack(path: $_path) {
				ScrollView {
					LazyVStack(spacing: 18) {
						_masthead()
							.padding(.bottom, 2)

						let cards = _cards
						if cards.isEmpty {
							_emptyFeed()
						} else {
							ForEach(cards, id: \.app.currentUniqueId) { card in
								BSStoryCardLink(
									source: card.source,
									repository: card.repository,
									app: card.app,
									onOpen: { _path.append(_item(for: card)) }
								)
							}
						}

					}
					.padding(.horizontal, 16)
					.padding(.top, 8)
					.padding(.bottom, 28)
				}
				.background { BSStoreGround() }
				.navigationDestination(for: BSAppItem.self) { item in
					SourceAppsDetailView(
						sourceURL: item.sourceURL,
						source: item.source,
						app: item.app
					)
				}
				.navigationTitle("Today")
				.navigationBarTitleDisplayMode(.large)
				.toolbar {
					_cornerControls
				}
				.refreshable {
					await viewModel.fetchSources(_sources, refresh: true)
				}
				.sheet(isPresented: $_isAddingPresenting) {
					SourcesAddView()
				}
				.sheet(isPresented: $_isSettingsPresenting) {
					SettingsView()
				}
				.sheet(isPresented: $_isUpdatesPresenting) {
					UpdatesView()
				}
				#if DEBUG
				.sheet(item: $_debugPage) { page in
					NavigationStack {
						SourceAppsDetailView(
							sourceURL: page.sourceURL,
							source: page.repository,
							app: page.app
						)
					}
				}
				#endif
			}
			.task(id: Array(_sources)) {
				await viewModel.fetchSources(_sources)
			}
			#if DEBUG
			.onAppear {
				if CommandLine.arguments.contains("-settings") { _isSettingsPresenting = true }
				_openDebugPageIfAsked()
			}
			#endif
		}

	}

#if DEBUG
// MARK: - Debug page

extension DiscoverView {
	/// An app page opened by `-apppage`, so the bar's own action pill can be
	/// looked at without a finger.
	///
	/// That pill — the GET that takes the header's place in the top-right corner
	/// once the page has scrolled — only exists in the scrolled state, and no
	/// script can scroll a simulator. The state itself is forced by the page
	/// (`-apppagescrolled`); this is what gets the page on screen.
	struct BSDebugPage: Identifiable {
		let id = UUID()
		let sourceURL: URL?
		let repository: ASRepository
		let app: ASRepository.App
	}

	/// `-apppage <bundle id>`, retried while the sources are still loading: the
	/// repositories arrive asynchronously, and a hook that only worked when it
	/// raced the network is a hook that fails half the time.
	func _openDebugPageIfAsked() {
		guard let index = CommandLine.arguments.firstIndex(of: "-apppage"),
		      CommandLine.arguments.count > index + 1 else { return }
		let wanted = CommandLine.arguments[index + 1]

		Task { @MainActor in
			for _ in 0..<15 {
				for source in _sources {
					guard let repository = viewModel.sources[source] else { continue }
					guard let app = repository.apps.first(where: { $0.id == wanted }) else { continue }
					_debugPage = BSDebugPage(
						sourceURL: source.sourceURL,
						repository: repository,
						app: app
					)
					return
				}
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}
	}
}
#endif

// MARK: - Masthead

extension DiscoverView {
	/// Today's two corner controls: Updates and Settings, as two buttons.
	///
	/// They used to be two adjacent toolbar items, and on iOS 26 the toolbar
	/// draws *one* shared Liquid Glass capsule around adjacent items — measured
	/// on the simulator, the two of them came out as a single 128 pt button with
	/// two glyphs in it, where Sources' lone "+" is a 46 pt circle. The shared
	/// surface is therefore switched off for this position and each control
	/// draws its own circle, which is the same circle this app has always drawn
	/// below iOS 26. Both live in one item so the gap between them is a number
	/// this file chooses rather than one the system decides.
	@ToolbarContentBuilder
	private var _cornerControls: some ToolbarContent {
		if #available(iOS 26.0, *) {
			ToolbarItem(placement: .topBarTrailing) {
				_cornerRow
			}
			.sharedBackgroundVisibility(.hidden)
		} else {
			ToolbarItem(placement: .topBarTrailing) {
				_cornerRow
			}
		}
	}

	private var _cornerRow: some View {
		HStack(spacing: 10) {
			BSCornerButton(glyph: .swap, label: "Updates", standalone: true) {
				_isUpdatesPresenting = true
			}
			BSCornerButton(glyph: .gear, label: "Settings", standalone: true) {
				_isSettingsPresenting = true
			}
		}
	}

	/// The date the feed is signed with. The title itself is the navigation
	/// bar's, so this screen collapses and pushes exactly like the Apps tab
	/// does; the corner controls live in the toolbar for the same reason.
	/// Settings is not a tab in the bar — it opens from here, which is why this
	/// is the only screen in the app with a gear on it.
	private func _masthead() -> some View {
		Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
			.font(BSStore.eyebrowFont)
			.foregroundStyle(BSStore.secondary)
			.frame(maxWidth: .infinity, alignment: .leading)
	}
}

// MARK: - Feed

extension DiscoverView {
	/// A card, in the shape the catalogue pushes: the same value the Apps tab
	/// and search use, so a page opened from Today is the page opened from
	/// anywhere else.
	private func _item(
		for card: (source: AltSource, repository: ASRepository, app: ASRepository.App)
	) -> BSAppItem {
		BSAppItem(
			storedSource: card.source,
			sourceURL: card.source.sourceURL,
			source: card.repository,
			app: card.app
		)
	}

	/// The day's stories: each source's own lead app first, so every repository
	/// is represented at the top of the page, then everything else.
	///
	/// A feed, not a shelf — but also a finite one. Today is a set of stories,
	/// not the catalogue: a repository with nine thousand entries would otherwise
	/// ask this page to consider nine thousand cards, each of which measures its
	/// own artwork and extracts a dominant colour. It is capped, and the
	/// catalogue itself lives on Apps and in search.
	private static let _feedLimit = 60

	private var _cards: [(source: AltSource, repository: ASRepository, app: ASRepository.App)] {
		var seen = Set<String>()
		var cards: [(AltSource, ASRepository, ASRepository.App)] = []

		func push(_ source: AltSource, _ repository: ASRepository, _ app: ASRepository.App) {
			guard cards.count < Self._feedLimit else { return }
			// Keyed on the bundle id, so a repository that lists every historical
			// build of one app contributes one story rather than twenty.
			let key = app.id ?? app.currentUniqueId
			guard seen.insert(key).inserted else { return }
			cards.append((source, repository, app))
		}

		for source in _sources {
			guard let repository = viewModel.sources[source] else { continue }
			if let lead = repository.apps.first { push(source, repository, lead) }
		}

		for source in _sources {
			guard let repository = viewModel.sources[source] else { continue }
			for app in repository.apps { push(source, repository, app) }
		}

		return cards
	}	/// Shown only when there is genuinely nothing to build a feed from. A source
	/// that is merely still loading is not an empty store, so the page stays
	/// quiet and the cards arrive on their own.
	///
	/// Nothing here adds a source: sources are managed on their own tab, and an
	/// "Add Source" row in the middle of a storefront is what made Today read as
	/// a setup screen rather than as the App Store.
	@ViewBuilder
	private func _emptyFeed() -> some View {
		if _sources.isEmpty {
			VStack(spacing: 12) {
				Image(systemName: "sparkles.rectangle.stack")
					.font(.system(size: 34, weight: .regular))
					.foregroundStyle(BSStore.tertiary)
				Text("No Sources")
					.font(.system(size: 20, weight: .bold, design: .rounded))
				Text("Add a repository on the Sources tab and its apps appear here as today's stories.")
					.font(.system(size: 14))
					.foregroundStyle(BSStore.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 24)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 60)
		}
	}
}
