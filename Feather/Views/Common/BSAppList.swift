//
//  BSAppList.swift
//  Feather
//
//  BatSign's Apps list: the row shape from the BatSign design — icon, name,
//  category underneath, GET pill on the trailing edge, hairline between rows —
//  and the flattened index that feeds it.
//
//  The index is the reason this file exists as its own type: the old search
//  walked every source and rebuilt an array of every app on *every* keystroke.
//  Here it is built once per source-set change and filtered in a plain loop.
//

import SwiftUI
import AltSourceKit
import NimbleViews

// MARK: - Item

struct BSAppItem: Identifiable, Hashable {
	/// The stored source, so a row can name it and tint from it without a second
	/// lookup per row.
	let storedSource: AltSource
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App

	var id: String {
		"\(sourceURL?.absoluteString ?? "")|\(app.currentUniqueId)"
	}

	static func == (lhs: BSAppItem, rhs: BSAppItem) -> Bool { lhs.id == rhs.id }

	func hash(into hasher: inout Hasher) { hasher.combine(id) }

	/// What sits under the name: the source's own category when it has one,
	/// the developer when it doesn't, and the source's name as a last resort.
	var subtitle: String {
		if let category = app.category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty {
			return category
		}
		if let developer = app.developer?.trimmingCharacters(in: .whitespacesAndNewlines), !developer.isEmpty {
			return developer
		}
		return source.name ?? sourceURL?.host ?? "App"
	}
}

// MARK: - Index

enum BSAppIndex {
	// MARK: Cache

	private static let _lock = NSLock()
	private static var _cachedKey = ""
	private static var _cachedItems: [BSAppItem] = []

	/// The catalogue is the same list for the Apps tab and the search tab, so it
	/// is built once and handed to both rather than twice in parallel.
	static func cached(for key: String) -> [BSAppItem]? {
		_lock.lock()
		defer { _lock.unlock() }
		return _cachedKey == key ? _cachedItems : nil
	}

	static func cache(_ items: [BSAppItem], for key: String) {
		_lock.lock()
		_cachedKey = key
		_cachedItems = items
		_lock.unlock()
	}

	// MARK: Build

	/// Flattens every source into one row per app.
	///
	/// One row per app is the whole point. Plenty of repositories — AppTesters
	/// is the loud example, 9,049 entries across 785 bundle ids — publish every
	/// historical build as its own entry, so a straight flatten shows the same
	/// name twenty times over. A store lists an app once and keeps its older
	/// builds behind it, so duplicates collapse onto the newest build of that
	/// bundle id, and entries that publish no id are dropped rather than listed
	/// as “Unknown”.
	static func build(sources: [AltSource], repositories: [AltSource: ASRepository]) -> [BSAppItem] {
		var newest: [String: BSAppItem] = [:]
		newest.reserveCapacity(1024)

		for source in sources {
			guard let repository = repositories[source] else { continue }
			for app in repository.apps {
				guard let key = app.id, !key.isEmpty else { continue }

				let item = BSAppItem(
					storedSource: source,
					sourceURL: source.sourceURL,
					source: repository,
					app: app
				)

				guard let existing = newest[key] else {
					newest[key] = item
					continue
				}

				let held = existing.app.currentDate?.date ?? .distantPast
				let candidate = app.currentDate?.date ?? .distantPast

				if candidate > held {
					newest[key] = item
				} else if candidate == held, existing.app.currentName == "Unknown", app.currentName != "Unknown" {
					// Same build, but one entry carries the name and the other does
					// not. Prefer the one that can be read.
					newest[key] = item
				}
			}
		}

		let items = newest.values.sorted {
			$0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending
		}
		return items
	}

	static func filter(_ items: [BSAppItem], query: String, limit: Int = 80) -> [BSAppItem] {
		var results: [BSAppItem] = []
		for item in items {
			let name = item.app.currentName
			let developer = item.app.developer ?? ""
			let category = item.app.category ?? ""

			let matches = name.localizedCaseInsensitiveContains(query)
				|| developer.localizedCaseInsensitiveContains(query)
				|| category.localizedCaseInsensitiveContains(query)

			if matches {
				results.append(item)
				if results.count >= limit { break }
			}
		}
		return results
	}
}

// MARK: - Row

/// One row of the catalogue. Deliberately the same row the storefront uses,
/// with the same pill: an app has to report the same state wherever it is
/// listed, or the button starts lying on whichever screen the user happens to
/// be looking at.
struct BSAppRow: View {
	let item: BSAppItem
	var showsChevron: Bool = false
	var showsPill: Bool = true

	var body: some View {
		BSStoreRow(
			storedSource: item.storedSource,
			sourceURL: item.sourceURL,
			repository: item.source,
			app: item.app,
			showsSeparator: false,
			showsChevron: showsChevron,
			showsPill: showsPill
		)
	}
}

/// The list itself: rows and their hairlines, nothing else. Used by the Apps tab
/// and by search, so a result and a catalogue row can never drift apart.
struct BSAppList: View {
	let items: [BSAppItem]

	/// When set, rows are *picked* rather than opened.
	///
	/// A source's catalogue is where a multi-sign run usually starts — the apps
	/// are not in the Library yet — and picking them here has to be the same
	/// gesture as picking them there. The GET pill goes away in this mode: the
	/// row answers one question, and the answer is not "download this one".
	var picking: Binding<Set<String>>? = nil

	var body: some View {
		LazyVStack(spacing: 0) {
			ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
				if let picking {
					Button {
						BSHaptics.tap()
						let id = item.id
						withAnimation(.snappy(duration: 0.2)) {
							if picking.wrappedValue.contains(id) {
								picking.wrappedValue.remove(id)
							} else {
								picking.wrappedValue.insert(id)
							}
						}
					} label: {
						_pickingRow(item, picked: picking.wrappedValue.contains(item.id))
					}
					.buttonStyle(.plain)
				} else {
					NavigationLink {
						SourceAppsDetailView(
							sourceURL: item.sourceURL,
							source: item.source,
							app: item.app
						)
					} label: {
						BSAppRow(item: item)
					}
					.buttonStyle(.plain)
				}

				if index < items.count - 1 {
					// Inset to the row's own leading edge, the way the App Store
					// runs its separators under the icon rather than past it.
					Rectangle()
						.fill(BSStore.separator)
						.frame(height: 0.5)
						.padding(.leading, 16)
				}
			}
		}
	}

	/// One row, while apps are being picked: the tick in the leading gutter the
	/// system uses for this, then the row itself with its pill switched off.
	private func _pickingRow(_ item: BSAppItem, picked: Bool) -> some View {
		HStack(spacing: 4) {
			Image(systemName: picked ? "checkmark.circle.fill" : "circle")
				.font(.system(size: 22, weight: .regular))
				.foregroundStyle(picked ? BS.accent : Color.secondary.opacity(0.45))
				.padding(.leading, 12)
				.padding(.trailing, 4)

			BSAppRow(item: item, showsPill: false)
		}
		.contentShape(Rectangle())
	}
}
