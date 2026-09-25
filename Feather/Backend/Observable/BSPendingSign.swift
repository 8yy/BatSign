//
//  BSPendingSign.swift
//  Feather
//
//  The two systems, and the tray one of them needs.
//
//  An app can arrive two ways — fetched from a source, or imported as a file —
//  and until now there was exactly one answer to it: sign it the moment it
//  lands. That is what most people want, and it stays the default.
//
//  It is not what everybody wants. Someone rebuilding a set of apps wants the
//  downloads to finish first: five packages arriving one after another used to
//  become five signing jobs, each starting the moment its own bytes landed, and
//  the person had no say in when the work began. So there is a second system,
//  and it is the user who picks which one runs:
//
//    • One at a time — each app signs the moment it arrives. The default.
//    • Collect — arriving apps wait in a tray. Nothing is signed until the
//      person says so, and then all of them go together as one run.
//
//  The choice governs *arrivals* only. An app somebody taps to sign is signed
//  there and then in either mode, because a tap is not an arrival — it is the
//  answer to the question this file exists to ask.
//
//  What is deliberately left alone: an app the automation updates by itself.
//  Holding that in a tray would leave the person running the build they asked
//  to have replaced, and the update already has switches of its own.
//

import Foundation
import Combine
import CoreData
import OSLog

/// How an app that has just arrived is handled.
enum BSSigningMode: String, CaseIterable, Identifiable, Codable {
	/// Signed as it lands. The default, and the behaviour this app has always
	/// had.
	case oneAtATime
	/// Held in the tray until the person confirms.
	case collect

	var id: String { rawValue }

	var title: String {
		switch self {
		case .oneAtATime: return "One at a Time"
		case .collect: return "Collect, Then Sign Together"
		}
	}
}

/// The apps waiting to be signed together.
///
/// One tray, one owner. It is written to disk on every change, because the
/// whole point of the mode is that a person can fetch several apps over time
/// and sign them at the end — and a list that died with the process would make
/// that a promise the app could not keep.
@MainActor
final class BSPendingSign: ObservableObject {
	static let shared = BSPendingSign()

	/// The mode's own key. Written by Settings, read here.
	static let modeKey = "Feather.signingMode"
	private static let _itemsKey = "Feather.pendingSign.items"

	private static let log = Logger(subsystem: "app.batsign.ios", category: "pending")

	// MARK: Model

	struct Item: Identifiable, Codable, Equatable {
		/// The Library row this app is. The tray holds identities, not bundles:
		/// the app itself is already in the Library, and a second copy of it
		/// here would be a second thing to keep in step.
		let uuid: String
		let name: String
		let identifier: String?
		let arrived: Date

		var id: String { uuid }
	}

	// MARK: State

	/// The apps waiting, oldest first — the order they will be signed in.
	@Published private(set) var items: [Item] = []

	/// Set when the tray was empty and something just landed in it. The root
	/// view shows the confirmation while it is true; the person answers, and
	/// nothing is signed until they do.
	@Published var isAsking = false

	@Published private(set) var mode: BSSigningMode

	/// Whether arrivals are being held rather than signed. The pipeline asks
	/// this before it signs anything that lands.
	var isCollecting: Bool { mode == .collect }

	var count: Int { items.count }
	var isEmpty: Bool { items.isEmpty }

	/// The names, for the strip's one line.
	var names: String { items.map(\.name).joined(separator: " · ") }

	private init() {
		mode = BSSigningMode(
			rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? ""
		) ?? .oneAtATime
		items = Self._read()
		// A row can go — a Reset, a delete, a restore — while an app sits in
		// the tray. The tray is a view of the Library, so it follows the
		// Library rather than outliving it.
		reconcile()
	}

	// MARK: The mode

	func setMode(_ mode: BSSigningMode) {
		guard mode != self.mode else { return }
		self.mode = mode
		UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)

		// Leaving collect with apps waiting does not sign them and does not
		// throw them away: they stay in the tray, where the strip already
		// offers to sign or clear them. Silently signing work the person was
		// about to look at would be the app making their decision, and silently
		// dropping it would be worse.
		if mode == .oneAtATime { isAsking = false }

		Self.log.notice(
			"pending: mode is now \(mode.rawValue, privacy: .public)"
		)
	}

	// MARK: Arriving

	/// An app has landed. True when it was taken into the tray.
	///
	/// False in either of the two cases where the caller should sign it the way
	/// it always has: the person is on the one-at-a-time system, or this app is
	/// already waiting.
	@discardableResult
	func collect(uuid: String, name: String, identifier: String?) -> Bool {
		guard isCollecting, !uuid.isEmpty else { return false }
		guard !items.contains(where: { $0.uuid == uuid }) else { return false }

		let wasEmpty = items.isEmpty
		items.append(Item(uuid: uuid, name: name, identifier: identifier, arrived: Date()))
		_persist()

		Self.log.notice(
			"pending: holding \(name, privacy: .public) — \(self.items.count, privacy: .public) waiting"
		)

		// Asked once, when the tray was empty. A second arrival while the
		// person is still deciding does not interrupt them a second time —
		// the strip says the count — but a tray that fills over days asks
		// again the next time it starts from nothing.
		if wasEmpty { isAsking = true }
		return true
	}

	// MARK: Deciding

	/// Sign everything that is waiting, as one run. The whole of "confirm".
	///
	/// Cleared only for the apps the queue actually took: a run that refused
	/// every job must not empty the tray and leave the work looking done.
	@discardableResult
	func signAll() -> Int {
		guard !items.isEmpty else { return 0 }

		// Read fresh. The app is in the Library; a row fetched from it is the
		// object the pipeline signs, and the tray's copy of a name is only ever
		// a label.
		let uuids = items.map(\.uuid)
		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.predicate = NSPredicate(format: "uuid IN %@", uuids)
		let rows = (try? Storage.shared.context.fetch(request)) ?? []

		guard !rows.isEmpty else {
			// Nothing to sign — every row is gone. Saying so and emptying the
			// tray is the honest end: the apps it named do not exist.
			Self.log.notice("pending: nothing to sign — the rows are gone")
			clear()
			return 0
		}

		// The tray's own order, because that is the order the person built it
		// in and the order they will be watching for.
		let order = Dictionary(uniqueKeysWithValues: uuids.enumerated().map { ($1, $0) })
		let apps = rows
			.map { $0 as any AppInfoPresentable }
			.sorted { (order[$0.uuid ?? ""] ?? .max) < (order[$1.uuid ?? ""] ?? .max) }

		let started = BSBulkSign.shared.sign(apps, title: Self._title(for: apps.count))
		guard started > 0 else { return 0 }

		// Everything the run took, out of the tray. Anything it refused is
		// already reported by the run's own strip, name by name.
		let taken = Set(apps.compactMap { $0.uuid })
		items.removeAll { taken.contains($0.uuid) }
		_persist()
		isAsking = false

		Self.log.notice(
			"pending: signed \(started, privacy: .public) of \(apps.count, privacy: .public) that were waiting"
		)
		return started
	}

	func remove(_ uuid: String) {
		let before = items.count
		items.removeAll { $0.uuid == uuid }
		guard items.count != before else { return }
		_persist()
	}

	func clear() {
		guard !items.isEmpty else { return }
		items.removeAll()
		_persist()
		isAsking = false
		Self.log.notice("pending: tray cleared")
	}

	/// Drop anything whose Library row is no longer there.
	func reconcile() {
		guard !items.isEmpty else { return }

		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.predicate = NSPredicate(format: "uuid IN %@", items.map(\.uuid))
		let existing = Set(((try? Storage.shared.context.fetch(request)) ?? []).compactMap { $0.uuid })

		let before = items.count
		items.removeAll { !existing.contains($0.uuid) }
		guard items.count != before else { return }
		_persist()
		Self.log.notice(
			"pending: \(before - self.items.count, privacy: .public) waiting app(s) are no longer in the Library"
		)
	}

	// MARK: - Storage

	private static func _title(for count: Int) -> String {
		count == 1 ? "Sign 1 App" : "Sign \(count) Apps"
	}

	private func _persist() {
		guard let data = try? JSONEncoder().encode(items) else { return }
		UserDefaults.standard.set(data, forKey: Self._itemsKey)
	}

	private static func _read() -> [Item] {
		guard let data = UserDefaults.standard.data(forKey: _itemsKey),
			  let decoded = try? JSONDecoder().decode([Item].self, from: data)
		else { return [] }
		return decoded
	}
}
