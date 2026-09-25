//
//  BSBackgroundTasks.swift
//  Feather
//
//  The part of "keep working in the background" that survives the process.
//
//  The silent audio hold keeps the app scheduled while it has work, and that is
//  what carries a signing job and the install hand-off after it. It cannot,
//  however, survive the process being *taken away*: memory pressure at the wrong
//  moment, a crash, or the user swiping the app out of the switcher ends
//  everything held inside it, and the install the user was waiting for is left
//  half-done with nothing to say why.
//
//  So there are two more things here.
//
//  A journal — `BSJobJournal`. The transfer that is in flight is written down:
//  where it came from, which package it has already staged on disk, how many
//  times it has been tried. It is cleared only when the job is genuinely over,
//  so anything still in it at launch is, by definition, a job that was
//  interrupted. It lives behind a lock rather than on the main actor because the
//  transfer writes to it from URLSession's own queue, where hopping to the main
//  actor to note that a file arrived is not something a download should have to
//  do.
//
//  A processing request — `BSBackgroundTasks`. While work is running the app
//  asks the system for a `BGProcessingTask`, and that request outlives the
//  process: it is what lets iOS wake the app later to finish what it was doing.
//  It is also the switch the user is looking at — Settings ▸ Background App
//  Refresh is the system's permission for exactly this, which is why the app
//  declares the `processing` and `fetch` background modes and not only `audio`.
//  Turning that switch off does not stop signing; it stops the app being woken
//  to finish a job it was killed in the middle of.
//
//  Registration happens in `didFinishLaunching`, because a handler registered
//  after launch returns is a handler iOS refuses to run.
//

import Foundation
import UIKit
import BackgroundTasks
import OSLog

/// Work that was in flight, written down so it can be picked up.
struct BSPendingJob: Codable {
	/// The package's remote URL, as handed to the transfer. Empty for a job that
	/// has no transfer of its own — a re-sign of something already on disk.
	var url: String
	/// The transfer's own identifier.
	var transferID: String
	/// The app it will become, when the caller knew.
	var bundleID: String?
	var name: String?
	/// The package staged on disk once the bytes have arrived. When this is
	/// set, resuming means signing what is already here instead of fetching it
	/// again.
	var localPackagePath: String?
	/// The library record a signing job belongs to, for work that is not a
	/// transfer: a re-sign, a renewal, an install from a notification. Signing is
	/// minutes of CPU inside this process and a kill in the middle of it leaves
	/// nothing on disk to find — this is what tells the next launch which app was
	/// being signed.
	var signingUUID: String?
	/// How many times this job has been picked up after an interruption.
	var attempts: Int = 0

	/// Whether picking this up needs the network. A staged package does not; a
	/// re-sign does not; a transfer that never arrived does.
	var needsNetwork: Bool {
		localPackagePath == nil && signingUUID == nil
	}
}

/// The record of the job in flight, on disk and behind a lock.
///
/// Written before a transfer starts and cleared when the whole job is over,
/// which is what makes "still in the journal at launch" and "interrupted" the
/// same statement. It is deliberately not main-actor state: `URLSession` calls
/// its delegate on its own queue, and a download should not have to reach the
/// main actor to say that a file has arrived.
final class BSJobJournal: @unchecked Sendable {
	static let shared = BSJobJournal()

	private static let log = Logger(subsystem: "app.batsign.ios", category: "background")
	/// The old home of the journal. UserDefaults is written through cfprefsd,
	/// and on a hard kill — the exact event this journal exists to survive — the
	/// daemon's cache and the disk can part ways, losing the record. It is read
	/// once here as a migration and never written again.
	private static let legacyKey = "BatSign.pendingJob"
	/// The journal lives in its own file, written atomically by this process
	/// alone: no daemon between the write and the disk, so a kill mid-download
	/// leaves either the old record or the new one, never nothing.
	private static var fileURL: URL = {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		try? FileManager.default.createDirectoryIfNeeded(at: base)
		return base.appendingPathComponent("pending-job.json")
	}()

	private let lock = NSLock()
	private var _pending: BSPendingJob?

	init() {
		_pending = Self._load()
	}

	var pending: BSPendingJob? {
		lock.lock(); defer { lock.unlock() }
		return _pending
	}

	/// A transfer has started.
	func record(transfer id: String, url: URL, bundleID: String?, name: String?) {
		lock.lock(); defer { lock.unlock() }

		var pending = BSPendingJob(url: url.absoluteString, transferID: id, bundleID: bundleID, name: name)
		// The same package being started again keeps the count it came back
		// with, so an URL that kills the app every time is not retried for ever.
		if _pending?.url == url.absoluteString {
			pending.attempts = _pending?.attempts ?? 0
		}
		_pending = pending
		Self._save(pending)
	}

	/// A signing job has started, with no transfer of its own.
	///
	/// Recorded only when the journal is empty. A transfer's record is the
	/// precious one — it is the only thing that knows where a part-downloaded
	/// package came from, and it cannot be reconstructed — whereas a signing job
	/// can be rediscovered from the Library. So a job that is not a transfer
	/// never displaces one that is; when a transfer's record is already there,
	/// its own staged package is what the signing half will be resumed from.
	@discardableResult
	func record(signing uuid: String, name: String?) -> Bool {
		lock.lock(); defer { lock.unlock() }

		guard _pending == nil else { return false }

		var pending = BSPendingJob(url: "", transferID: uuid, name: name)
		pending.signingUUID = uuid
		_pending = pending
		Self._save(pending)
		Self.log.notice("background: signing job recorded for the journal")
		return true
	}

	/// The package is on disk. Signing can start from here without the network.
	func stage(transfer id: String, package: URL) {
		lock.lock(); defer { lock.unlock() }

		guard var pending = _pending, pending.transferID == id else { return }
		pending.localPackagePath = package.path
		_pending = pending
		Self._save(pending)
		Self.log.notice("background: package staged for the journal")
	}

	/// Note that this job has been picked up, and how many times that has now
	/// happened. Returns the updated record.
	func noteAttempt() -> BSPendingJob? {
		lock.lock(); defer { lock.unlock() }

		guard var pending = _pending else { return nil }
		pending.attempts += 1
		_pending = pending
		Self._save(pending)
		return pending
	}

	/// Clear the record only when it is this transfer's.
	///
	/// The journal is a single slot, and a record can be overwritten by the
	/// next transfer the moment the previous one finishes. Clearing without
	/// asking whose record it is deletes the staged package of a *different*
	/// transfer — one whose bytes have arrived and whose import is already
	/// reading them. A failure or a cancel of transfer A must leave transfer
	/// B's record and package alone.
	@discardableResult
	func clearIf(transferID: String) -> Bool {
		let matches: Bool
		lock.lock()
		matches = _pending?.transferID == transferID
		lock.unlock()

		guard matches else { return false }
		clear(reason: "the transfer it would resume is over")
		return true
	}

	/// The job is over — signed, installed, refused, or cancelled. There is
	/// nothing left to pick up.
	func clear(reason: String) {
		lock.lock()
		let hadWork = _pending != nil
		let staged = _pending?.localPackagePath
		_pending = nil
		lock.unlock()

		guard hadWork else { return }

		// The package was staged for a job that no longer exists, so it is
		// nobody's now. Left behind it is a full copy of every package the app
		// has ever downloaded, kept for ever in a directory the system does not
		// purge — and every one of them was imported from a copy, not moved.
		if let staged {
			try? FileManager.default.removeItem(at: URL(fileURLWithPath: staged))
		}

		try? FileManager.default.removeItem(at: Self.fileURL)
		UserDefaults.standard.removeObject(forKey: Self.legacyKey)
		// The request on file described work that no longer exists. Left
		// behind, it would wake the app to finish something already finished.
		BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BSBackgroundTasks.jobIdentifier)
		Self.log.notice("background: job journal cleared (\(reason, privacy: .public))")
	}

	/// Clear the record only when it is this job's — the signing record that
	/// names the library row, or the transfer record that names the bundle.
	///
	/// The record on file may belong to work that is still in flight — a
	/// second transfer that began while this job was finishing — and that one
	/// must survive. A record that names this job, by contrast, is spent the
	/// moment the hand-off exists: its one purpose is resuming interrupted
	/// work, and resuming a job whose package is already with iOS re-signs an
	/// app that is on its way to the Home Screen — the second prompt, the
	/// second card, and the failure report after a success, all for a job that
	/// is over.
	@discardableResult
	func clearIf(jobUUID: String, bundleID: String?) -> Bool {
		let matches: Bool
		lock.lock()
		if let pending = _pending {
			if let signing = pending.signingUUID {
				matches = signing == jobUUID
			} else if let bundleID, !bundleID.isEmpty {
				matches = pending.bundleID == bundleID
			} else {
				matches = false
			}
		} else {
			matches = false
		}
		lock.unlock()

		guard matches else { return false }
		clear(reason: "the job it would resume is finished")
		return true
	}

	// MARK: - Disk

	private static func _save(_ pending: BSPendingJob) {
		guard let data = try? JSONEncoder().encode(pending) else { return }
		try? data.write(to: fileURL, options: .atomic)
	}

	private static func _load() -> BSPendingJob? {
		if let data = try? Data(contentsOf: fileURL),
		   let pending = try? JSONDecoder().decode(BSPendingJob.self, from: data) {
			return pending
		}
		// One-time migration: a journal written before the file store existed.
		if let data = UserDefaults.standard.data(forKey: legacyKey),
		   let pending = try? JSONDecoder().decode(BSPendingJob.self, from: data) {
			try? data.write(to: fileURL, options: .atomic)
			UserDefaults.standard.removeObject(forKey: legacyKey)
			return pending
		}
		return nil
	}
}

@MainActor
final class BSBackgroundTasks {
	static let shared = BSBackgroundTasks()

	private static let log = Logger(subsystem: "app.batsign.ios", category: "background")

	/// The identifier this app registers for continued work.
	///
	/// `nonisolated` because the journal needs it to withdraw a request, and the
	/// journal is reached from the transfer's own queue.
	nonisolated static var jobIdentifier: String {
		"\(Bundle.main.bundleIdentifier ?? "app.batsign.ios").job"
	}

	/// How many times an interrupted job is picked up before it is left alone.
	/// A job interrupted twice is either beyond what a retry can fix or is being
	/// interrupted by something a third attempt would only be fighting.
	private let maximumAttempts = 2

	// MARK: - Registration

	/// Register the handlers. Must run before launch finishes.
	static func register() {
		BGTaskScheduler.shared.register(forTaskWithIdentifier: jobIdentifier, using: nil) { task in
			guard let task = task as? BGProcessingTask else {
				task.setTaskCompleted(success: false)
				return
			}
			Task { @MainActor in await shared._handleContinuation(task) }
		}

		log.notice("background: processing handler registered")
	}

	// MARK: - Asking the system to let us finish

	/// Ask for the chance to finish the job that is running.
	///
	/// Submitted when work starts and cancelled when it is over, so the request
	/// on file always describes work that is genuinely outstanding. No power
	/// requirement — a user waiting on an install may well be on battery — and a
	/// network requirement only while the package has not arrived.
	func scheduleJobContinuation() {
		guard let pending = BSJobJournal.shared.pending else { return }

		let request = BGProcessingTaskRequest(identifier: Self.jobIdentifier)
		request.requiresNetworkConnectivity = pending.needsNetwork
		request.requiresExternalPower = false
		// Long enough that the system does not read it as an immediate
		// resubmission of the request already on file, short enough that a job
		// killed at 2% is not waiting an hour to be picked up.
		request.earliestBeginDate = Date(timeIntervalSinceNow: 60)

		do {
			try BGTaskScheduler.shared.submit(request)
			Self.log.notice("background: asked the system to let us finish the job")
		} catch {
			// Refused for the ordinary reasons: a newer request is already on
			// file, or background refresh is off for this app in Settings.
			// Neither is a reason to stop the job running right now — they only
			// cost the recovery *after* a kill — so this is reported, not
			// treated as a failure.
			Self.log.notice("background: continuation request declined — \(error.localizedDescription, privacy: .public)")
		}
	}

	func cancelJobContinuation() {
		BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.jobIdentifier)
	}

	// MARK: - Waking up

	/// The system has woken the app to finish what it was doing.
	private func _handleContinuation(_ task: BGProcessingTask) async {
		// The request has been consumed; ask for the next chance before doing
		// anything that can fail, so work interrupted twice is still asked for
		// a third time.
		scheduleJobContinuation()

		guard let pending = BSJobJournal.shared.pending else {
			Self.log.notice("background: woken with nothing to finish")
			task.setTaskCompleted(success: true)
			return
		}

		Self.log.notice("background: woken to finish \(pending.name ?? pending.url, privacy: .public)")

		var expired = false
		task.expirationHandler = {
			Task { @MainActor in expired = true }
		}

		// Whether anything was running when we arrived. `resume` starts the work
		// asynchronously — a staged package is handed to the importer and a
		// transfer is started, both of which take a moment to take their holds —
		// so the wait below cannot be "while something is holding": at this
		// instant nothing is, and the loop would exit before the job it was
		// woken for had begun, reporting success for work that never ran.
		let wasHolding = BSJobKeepAlive.shared.isHolding

		await resume(reason: "woken by the system")

		// Give the resumed job a moment to take its holds. Then the job is not
		// this task's to run to completion: signing and the install hand-off
		// take their own holds, and the process is kept up by them. This waits
		// for the work rather than assuming it, because a task that reports
		// completion while the job is still running is a task the system is free
		// to take away from underneath it.
		var sawHold = wasHolding
		for _ in 0..<20 {
			if BSJobKeepAlive.shared.isHolding { sawHold = true; break }
			if expired { break }
			try? await Task.sleep(nanoseconds: 250_000_000)
		}

		if sawHold {
			while !expired, BSJobKeepAlive.shared.isHolding {
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}

		task.setTaskCompleted(success: !expired)
	}

	// MARK: - Recovery

	/// Pick up whatever the last run left behind.
	///
	/// Called once at launch. Anything in the journal at this point belongs to a
	/// process that is no longer running: this one has not written anything yet,
	/// because `record` is only called when a transfer starts. That is the whole
	/// test — no process identifier, no timestamps to compare, just the fact
	/// that the journal is written before work starts and cleared when it ends.
	func recoverInterruptedJob() {
		guard let pending = BSJobJournal.shared.pending else { return }

		guard pending.attempts < maximumAttempts else {
			Self.log.notice("background: \(pending.name ?? pending.url, privacy: .public) interrupted too often — leaving it")
			// The package is about to be deleted, and "silently" was the part
			// of this that had no excuse: the user watched a download reach
			// 100% and owes nothing to a job that will not be retried. They are
			// told it is gone and why, so re-downloading is a choice and not a
			// mystery.
			let name = pending.name ?? (URL(string: pending.url)?.lastPathComponent ?? "Download")
			AutoSignManager.shared.announceDownloadFailed(
				name: name,
				identifier: pending.bundleID ?? pending.transferID,
				message: "BatSign tried to finish this download several times after interruptions and removed it. Download it again from the source."
			)
			BSJobJournal.shared.clear(reason: "too many interruptions")
			return
		}

		Task { @MainActor in await resume(reason: "picked up at launch") }
	}

	/// Resume a job: sign the package already staged, re-sign an app whose
	/// signing was interrupted, or fetch the package again when there is nothing
	/// local to work from.
	private func resume(reason: String) async {
		guard let pending = BSJobJournal.shared.noteAttempt() else { return }

		// A signing job with no transfer behind it — a renewal, a re-sign, an
		// install the user asked for from a notification. There is no package to
		// find and nothing to fetch: the Library record it names is the whole of
		// the job.
		if let uuid = pending.signingUUID, pending.localPackagePath == nil {
			Self.log.notice("background: \(reason, privacy: .public) — re-signing what was interrupted")
			AutoSignManager.shared.recoverSigning(uuid: uuid, name: pending.name)
			return
		}

		if let path = _stagedPackagePath(for: pending) {
			Self.log.notice("background: \(reason, privacy: .public) — signing the staged package")
			// The transfer's id goes with it so a successful import can retire
			// the journal record it belongs to — without it, every launch
			// re-imported the same package until the attempts cap threw it away.
			FR.handlePackageFile(URL(fileURLWithPath: path), transferID: pending.transferID) { _ in }
			return
		}

		guard let url = URL(string: pending.url) else {
			BSJobJournal.shared.clear(reason: "unreadable url")
			return
		}

		// The bytes may still be on their way: the transfer belongs to the
		// background daemon, and opening the app again does not stop it. Asking
		// the session what it is running — and re-attaching to it — is the
		// difference between continuing a download and starting a second copy of
		// the same file from zero.
		await DownloadManager.shared.adoptRunningTransfers()

		if let live = DownloadManager.shared.downloads.first(where: { $0.url.absoluteString == pending.url }) {
			Self.log.notice("background: \(reason, privacy: .public) — the transfer was still running, re-attached")
			// The card is re-asserted rather than started: the transfer never
			// stopped, so its progress is the truth and a fresh begin would put
			// it back to the first frame of the wave.
			LiveStatus.begin(
				appID: live.liveID,
				appName: live.cardName,
				detail: "Resuming…",
				bundleID: live.bundleID,
				mode: CompressionMode.stored.label
			)
			scheduleJobContinuation()
			return
		}

		Self.log.notice("background: \(reason, privacy: .public) — fetching the package again")
		_ = DownloadManager.shared.startDownload(
			from: url,
			id: pending.transferID,
			bundleID: pending.bundleID,
			displayName: pending.name
		)
	}

	/// Where this job's staged package is now, moving it into the current
	/// staging directory if it was left in the old one.
	///
	/// The staging directory moved out of `temporaryDirectory` — which the app
	/// empties on launch — into Application Support. A job interrupted across
	/// that upgrade has its package at the old path, and the difference between
	/// finding it and not is a whole download.
	private func _stagedPackagePath(for pending: BSPendingJob) -> String? {
		if let path = pending.localPackagePath,
		   FileManager.default.fileExists(atPath: path) {
			return path
		}

		guard let path = pending.localPackagePath else { return nil }

		let legacyDirectory = DownloadManager.legacyStagingDirectory
		let legacy = legacyDirectory.appendingPathComponent((path as NSString).lastPathComponent)
		guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }

		let destinationDirectory = DownloadManager.stagingDirectory
		try? FileManager.default.createDirectoryIfNeeded(at: destinationDirectory)
		let destination = destinationDirectory.appendingPathComponent(legacy.lastPathComponent)
		try? FileManager.default.removeFileIfNeeded(at: destination)
		do {
			try FileManager.default.moveItem(at: legacy, to: destination)
			Self.log.notice("background: moved a staged package out of the launch-cleared directory")
			return destination.path
		} catch {
			Self.log.error("background: couldn't rescue the staged package — \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}
}
