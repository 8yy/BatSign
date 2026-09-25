//
//  BSBulkSign.swift
//  Feather
//
//  Signing several apps as one job.
//
//  Signing is serial by nature — one app at a time, minutes each — and every
//  hard part of doing it in the background already exists and already works:
//  the keep-alive that stops a job dying when the app leaves the screen, the
//  journal that picks a killed job back up, the live card on the island and the
//  Lock Screen, the install hand-off, the outcome popups. What did not exist is
//  a way for a person to say "these eight, please" — and a source's app is not
//  in the Library yet when they say it, so nothing could queue it.
//
//  This is that front half:
//
//    • `sign` takes apps that are already in the Library and queues them.
//    • `downloadAndSign` takes apps from a source, fetches their packages one
//      at a time, and hands each one to the signing queue the moment it lands.
//
//  One transfer at a time is deliberate. The island shows one card; eight
//  transfers racing each other would fight over it, the radio, and the disk,
//  and the run would report whichever app happened to be finishing rather than
//  the one the person is watching. Sequentially, each app gets the card in
//  turn — and the app after it starts downloading while this one signs.
//
//  Progress is read from the queue rather than kept alongside it. A job that
//  ends tells the run so; the run counts its own rows. There is one source of
//  truth about whether an app was signed, and it is the pipeline that signed it.
//

import Foundation
import Combine
import OSLog
import UIKit

// MARK: - The run, as the queue sees it

extension AutoSignManager {
	/// One app's place in a multi-sign run.
	///
	/// Carried on the job, so the card an app produces knows it is one of
	/// several without asking anybody — the same app can be signed on its own
	/// afterwards and the two jobs must not be confused for each other.
	struct Batch: Identifiable, Equatable, Sendable {
		/// The run itself. Every job of one run shares it.
		let id: String
		/// What the user asked for, in the words of the button they pressed.
		let title: String
		let total: Int
		/// This app's place in the run, 1-based.
		let index: Int
		/// The run's own row for this app, so a completion settles the right one.
		let itemID: String

		var position: String { "\(index) of \(total)" }

		/// How many apps of the run are behind this one. This is what the card
		/// shows as the island's "+5 more".
		var remaining: Int { max(total - index, 0) }
	}
}

// MARK: - The run

/// A run of apps signed one after another, as one thing the user asked for.
@MainActor
final class BSBulkSign: ObservableObject {
	static let shared = BSBulkSign()

	private static let log = Logger(subsystem: "app.batsign.ios", category: "bulk")

	// MARK: Model

	enum Stage: Equatable {
		/// Picked, not started. A source app waiting its turn to be fetched.
		case waiting
		/// Its package is being fetched.
		case downloading
		/// Signed or being signed by the queue.
		case signing
		case done
		case failed

		var isSettled: Bool { self == .done || self == .failed }
	}

	struct Item: Identifiable, Equatable {
		let id: String
		let name: String
		var stage: Stage = .waiting
		/// Why it did not land, when it did not.
		var reason: String?
		/// The transfer that will produce this app's package. Source apps only.
		var transferID: String?
		var downloadURL: URL?
		var provenance: SourceAppProvenance?

		/// What the run's strip says for this row.
		var note: String {
			switch stage {
			case .waiting: return "Waiting"
			case .downloading: return "Downloading"
			case .signing: return "Signing"
			case .done: return "Signed"
			case .failed: return reason ?? "Could not be signed"
			}
		}
	}

	struct Run: Equatable {
		let id: String
		let title: String
		var items: [Item]
		var isCancelled = false

		var total: Int { items.count }
		var signed: Int { items.filter { $0.stage == .done }.count }
		var failed: Int { items.filter { $0.stage == .failed }.count }
		var settled: Int { signed + failed }
		var isOver: Bool { settled >= total }
		var progress: Double { total == 0 ? 1 : Double(settled) / Double(total) }
		/// Where the run is, for the strip's own line.
		var position: String { "\(min(settled + 1, total)) of \(total)" }
		var current: Item? { items.first { !$0.stage.isSettled } }
	}

	// MARK: State

	/// The run being worked on, or the last one when it ended with something to
	/// say. Nil when there is nothing to show.
	@Published private(set) var run: Run?

	/// Imports the run is waiting for, by the transfer that will produce them.
	private var _pending: [String: (runID: String, itemID: String)] = [:]
	private var _pump: Task<Void, Never>?

	private init() {}

	// MARK: Starting a run

	/// Sign apps that are already in the Library, one after another.
	///
	/// Forced, and not gated on the automatic-signing preference: this is work
	/// somebody asked for by name, and a preference about automatic work has no
	/// say in it. Same rule a clone follows.
	@discardableResult
	func sign(_ apps: [any AppInfoPresentable], title: String? = nil) -> Int {
		let chosen = apps.filter { $0.uuid != nil }
		guard !chosen.isEmpty else { return 0 }

		var fresh = Run(
				id: UUID().uuidString,
				title: title ?? Self._title(for: chosen.count),
				items: chosen.map { Item(id: $0.uuid ?? UUID().uuidString, name: $0.name ?? "App") }
			)

			// One run, one card. The island is told every name the run will
			// address its apps by, before the first of them starts, so the card it
			// puts up is retargeted from app to app instead of being ended and
			// asked for again — which is a blink on the island per app, and a
			// start request per app against a budget that runs out part-way.
			LiveStatus.declareRun(names: chosen.compactMap { $0.identifier })


		var queued = 0
		for (offset, app) in chosen.enumerated() {
			guard let uuid = app.uuid else { continue }

			// Already on the queue, or in the signer right now. It will be
			// signed — just not by this run, so this run does not wait for it.
			if AutoSignManager.shared.isBusy(uuid) {
				fresh.items[offset].stage = .done
				fresh.items[offset].reason = "It was already being signed"
				continue
			}

			let batch = AutoSignManager.Batch(
				id: fresh.id,
				title: fresh.title,
				total: fresh.items.count,
				index: offset + 1,
				itemID: fresh.items[offset].id
			)

			if AutoSignManager.shared.enqueue(app: app, reason: .autoSign, force: true, batch: batch) {
				fresh.items[offset].stage = .signing
				queued += 1
			} else {
				fresh.items[offset].stage = .failed
				fresh.items[offset].reason = "It could not be queued for signing"
			}
		}

		guard queued > 0 else {
			run = fresh.items.contains(where: { $0.stage == .failed }) ? fresh : nil
			return 0
		}

		run = fresh
		Self.log.notice(
			"bulk: run started — \(fresh.title, privacy: .public) (\(queued, privacy: .public) from the Library)"
		)
		return queued
	}

	/// Fetch apps from a source and sign each one as its package lands.
	///
	/// The whole point of the run in one call: a source app is not in the Library
	/// yet, and the queue can only sign what is. Each package is fetched, and the
	/// import that follows is claimed by this run and handed straight to the
	/// queue — no second tap, no "now sign it" step in between.
	@discardableResult
	func downloadAndSign(_ items: [BSAppItem], title: String? = nil) -> Int {
		let rows = items.compactMap { item -> Item? in
			guard let url = item.app.currentDownloadUrl else { return nil }
			return Item(
				id: item.id,
				name: item.app.currentName,
				transferID: item.app.currentUniqueId,
				downloadURL: url,
				provenance: SourceAppProvenance(
					sourceURL: item.sourceURL,
					repository: item.source,
					app: item.app
				)
			)
		}
		guard !rows.isEmpty else { return 0 }

		run = Run(
				id: UUID().uuidString,
				title: title ?? Self._title(for: rows.count),
				items: rows
			)

			// A source app is addressed by its transfer until its package lands,
			// and by its bundle id after that. Both names belong to the run; the
			// transfer ids are known now and the bundle ids are registered by the
			// queue as each app starts.
			LiveStatus.declareRun(names: rows.compactMap(\.transferID))

			Self.log.notice(
				"bulk: run started — \(rows.count, privacy: .public) from a source, one transfer at a time"
			)
		_startPump()
		return rows.count
	}

	// MARK: The hand-off in

	/// Whether a run is waiting for this transfer's package.
	///
	/// Asked *before* the arriving-app tray, because the two can want the same
	/// package at the same time: a run the person started by name, and a mode
	/// about arrivals nobody has confirmed yet. The run wins, and it has to win
	/// without consuming the claim — the claim is taken by the import itself.
	func isWaiting(for transferID: String) -> Bool {
		_pending[transferID] != nil
	}

	/// The import for a transfer that belongs to a run has landed.
	///
	/// Consumes the claim, so one transfer can only ever feed one job, and
	/// returns the app's place in the run for the queue to put on the card.
	func claim(transferID: String) -> (itemID: String, batch: AutoSignManager.Batch)? {
		guard let pending = _pending.removeValue(forKey: transferID),
			  let run,
			  run.id == pending.runID,
			  let index = run.items.firstIndex(where: { $0.id == pending.itemID })
		else { return nil }

		_set(pending.itemID, stage: .signing)

		return (
			itemID: pending.itemID,
			batch: AutoSignManager.Batch(
				id: run.id,
				title: run.title,
				total: run.total,
				index: index + 1,
				itemID: pending.itemID
			)
		)
	}

	/// An app of a run could not be queued after all. Say so, and keep the run
	/// moving: one app that will not sign is not the other seven's problem.
	func markFailed(_ itemID: String, reason: String) {
		_fail(itemID, reason: reason)
	}

	// MARK: The hand-off back

	/// One app of a run is over, from the queue that signed it.
	func noteFinished(batch: AutoSignManager.Batch, succeeded: Bool) {
		guard run?.id == batch.id else { return }
		_set(batch.itemID, stage: succeeded ? .done : .failed, reason: nil, failedReason: "It could not be signed")
		_settleIfOver()
	}

	// MARK: Control

	/// Whether there is a run with work left in it.
	var isRunning: Bool {
		guard let run else { return false }
		return !run.isOver && !run.isCancelled
	}

	/// Stop the run.
	///
	/// The app being signed is left to finish — signing cannot be stopped
	/// halfway, and a half-written bundle in `Signed/` is worse than a finished
	/// one — and everything not started is dropped: the queued jobs from the
	/// queue, and the transfer in flight from the downloader.
	func cancel() {
		guard var run, !run.isOver else { return }
		run.isCancelled = true

		let dropped = AutoSignManager.shared.cancelQueued(batchID: run.id)
		_cancelInFlightTransfer()

		for index in run.items.indices where !run.items[index].stage.isSettled {
			// The one in the signer is not stopped and not reported as stopped:
			// it will finish, and the queue will say so when it does.
			guard run.items[index].stage != .signing else { continue }
			run.items[index].stage = .failed
			run.items[index].reason = "Cancelled"
		}

		self.run = run
			_pump?.cancel()
			_pump = nil
			_pending.removeAll()
			LiveStatus.releaseRun()

			Self.log.notice(
				"bulk: run cancelled — \(dropped, privacy: .public) job(s) dropped"
			)
	}

	/// Put the run's strip away. The work is not affected: this is the report
	/// being dismissed, not the run being stopped.
	func dismiss() {
		guard run?.isOver ?? false else { return }
		run = nil
	}

	// MARK: - The download funnel

	private func _startPump() {
		_pump?.cancel()
		guard let runID = run?.id else { return }
		_pump = Task { [weak self] in
			await self?._pump(runID: runID)
		}
	}

	/// Feed the transfers, one at a time, until the run has nothing left to
	/// fetch.
	private func _pump(runID: String) async {
		while !Task.isCancelled {
			guard let current = run, current.id == runID, !current.isCancelled, !current.isOver else { return }
			guard let index = current.items.firstIndex(where: { $0.stage == .waiting }) else { return }

			let item = current.items[index]
			guard let url = item.downloadURL, let transferID = item.transferID else {
				_fail(item.id, reason: "This app has no package to download")
				continue
			}

			_set(item.id, stage: .downloading)
				_pending[transferID] = (runID: runID, itemID: item.id)

				// The card follows the run onto this app. It stays the card it
				// already is; what changes is which app of how many it is about.
				LiveStatus.noteRunCurrent(transferID)


			_ = DownloadManager.shared.startDownload(
				from: url,
				id: transferID,
				sourceProvenance: item.provenance
			)

			// The run's own place, on the card the transfer just took. The
			// transfer's own ticks carry the bytes and the mode; this carries
			// which app of how many, and the island renders it as "+\u{2009}N more".
			LiveStatus.update(
				phase: .downloading,
				appName: item.name,
				progress: 0,
				detail: "\(index + 1) of \(current.total)",
				queued: max(current.total - index - 1, 0),
				progressKnown: false,
				force: true,
				appID: transferID,
				mode: CompressionMode.stored.label
			)

			// Wait for the package to land — or for the transfer to go without
			// one. The claim removes the pending entry, so this is the same
			// signal the queue is fed by.
			while !Task.isCancelled {
				if _pending[transferID] == nil { break }

				guard let live = run, live.id == runID, !live.isCancelled else { return }

				if !DownloadManager.shared.downloads.contains(where: { $0.id == transferID }) {
					_pending[transferID] = nil
					_fail(item.id, reason: "The download did not finish")
					break
				}

				try? await Task.sleep(nanoseconds: 400_000_000)
			}
		}
	}

	/// Stops the transfer the run is waiting on, if there is one.
	private func _cancelInFlightTransfer() {
		for (transferID, _) in _pending {
			if let download = DownloadManager.shared.downloads.first(where: { $0.id == transferID }) {
				DownloadManager.shared.cancelDownload(download)
			}
		}
	}

	// MARK: - Rows

	private func _set(
		_ itemID: String,
		stage: Stage,
		reason: String? = nil,
		failedReason: String? = nil
	) {
		guard let run, let index = run.items.firstIndex(where: { $0.id == itemID }) else { return }
		self.run?.items[index].stage = stage
		self.run?.items[index].reason = stage == .failed ? (reason ?? failedReason) : reason
		if stage == .signing || stage == .done { self.run?.items[index].reason = nil }
	}

	private func _fail(_ itemID: String, reason: String) {
		_set(itemID, stage: .failed, reason: reason)
		_settleIfOver()
	}

	/// The run has nothing left to do. A clean run says nothing more — the
	/// cards said it and the app is on the Home Screen — and a run with failures
	/// keeps its strip up, because the names are the only place they are listed.
	private func _settleIfOver() {
		guard let run, run.isOver else { return }

		_pump?.cancel()
		_pump = nil
		_pending.removeAll()
		// The run's apps are separate jobs again, so a card left over from it
		// can no longer be claimed by one of them.
		LiveStatus.releaseRun()

		Self.log.notice(
			"bulk: run finished — \(run.signed, privacy: .public)/\(run.total, privacy: .public) signed, \(run.failed, privacy: .public) failed"
		)

		if run.failed == 0 {
			self.run = nil
		}
	}

	private static func _title(for count: Int) -> String {
		count == 1 ? "Signing 1 app" : "Signing \(count) apps"
	}
}
