//
//  DownloadManager.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import Foundation
import Combine
import UIKit.UIImpactFeedbackGenerator
import UserNotifications
import OSLog

class Download: Identifiable, @unchecked Sendable {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0

	/// The transfer's own bytes, which is the only thing a progress ring over a
	/// download may report. The legacy blend below is for the download header,
	/// which narrates transfer *and* unpacking as one bar; a ring that stops at
	/// 70% the moment the file is complete is not a storefront's ring.
	var transferProgress: Double {
		onlyArchiving ? unpackageProgress : progress
	}

	/// True once this transfer has nothing left to move.
	var hasFinishedTransferring: Bool {
		transferProgress >= 0.999
	}

	var overallProgress: Double {
		onlyArchiving
		? unpackageProgress
		: (0.3 * unpackageProgress) + (0.7 * progress)
	}

	/// The transfer's own rate, in bytes a second, refreshed as bytes arrive.
	///
	/// A bar at 40% says nothing about whether the wait is ten seconds or ten
	/// minutes, and that is the question a person watching an install asks. The
	/// rate is measured over a window rather than per callback, because
	/// URLSession delivers bytes in bursts and an unwindowed rate swings between
	/// meaningless extremes.
	private var _rateWindowStart: Date?
	private var _rateWindowBytes: Int64 = 0
	private(set) var bytesPerSecond: Double = 0

	/// How long a rate window is. Long enough to smooth a burst, short enough
	/// that a link which speeds up or stalls is visible within a second or two.
	private static let rateWindow: TimeInterval = 1.0

	/// Fold a fresh byte count into the rate estimate.
	func noteTransfer(bytes: Int64) {
		let now = Date()
		guard let start = _rateWindowStart else {
			_rateWindowStart = now
			_rateWindowBytes = bytes
			return
		}
		let elapsed = now.timeIntervalSince(start)
		guard elapsed >= Self.rateWindow else { return }

		let delta = bytes - _rateWindowBytes
		_rateWindowStart = now
		_rateWindowBytes = bytes
		guard delta > 0 else {
			// A window with nothing in it is a stall, and saying so is honest.
			// The next window with bytes in it puts the rate back.
			bytesPerSecond = 0
			_rateMeasuredAt = now
			return
		}
		let measured = Double(delta) / elapsed
		// Smoothed, so one slow tick does not swing the number being read.
		bytesPerSecond = bytesPerSecond == 0
			? measured
			: (bytesPerSecond * 0.6) + (measured * 0.4)
		_rateMeasuredAt = now
	}

	/// When the rate was last computed from real bytes.
	private var _rateMeasuredAt: Date?

	/// How long a rate is still a reading.
	///
	/// Longer than the window it is measured over, so a slow link is never
	/// called stopped, and short enough that a transfer which has gone silent is
	/// not still advertising a speed. See `formattedSpeed`.
	private static let rateLifetime: TimeInterval = 5

	/// Whether the rate in hand still describes what is happening.
	///
	/// The estimate is only recomputed from bytes that arrive, so a transfer
	/// that stops moving keeps the last rate it computed — for ever, because
	/// nothing runs to clear it. "60% · 1.3 MB/s" on a download that stopped a
	/// minute ago is the same lie as a parked percentage: a figure presented as
	/// live that nobody is still measuring. It reads zero once it is older than
	/// any real window, so both the speed and the ETA computed from it fall
	/// away together.
	var rateIsCurrent: Bool {
		guard let at = _rateMeasuredAt else { return false }
		return Date().timeIntervalSince(at) < Self.rateLifetime
	}

	/// "3.2 MB/s", or nil while there is nothing honest to say.
	var formattedSpeed: String? {
		guard rateIsCurrent, bytesPerSecond > 1024 else { return nil }
		return "\(Self.byteFormatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
	}

	/// "about 2 min left", or nil while the rate or the remaining bytes are
	/// unknown. Deliberately coarse: a precise-looking countdown that jumps
	/// around is worse than an honest estimate.
	var formattedETA: String? {
		guard rateIsCurrent, bytesPerSecond > 1024, totalBytes > 0, bytesDownloaded < totalBytes else { return nil }
		let seconds = Double(totalBytes - bytesDownloaded) / bytesPerSecond
		guard seconds.isFinite, seconds > 1 else { return nil }
		if seconds < 60 { return "less than a minute left" }
		let minutes = Int((seconds / 60).rounded())
		if minutes < 60 { return "about \(minutes) min left" }
		let hours = Int((Double(minutes) / 60).rounded())
		return "about \(hours) hr left"
	}

	/// One formatter for every byte count the transfer half prints, so the
	/// island and the in-app bar cannot disagree about how big something is.
	static let byteFormatter: ByteCountFormatter = {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		return formatter
	}()

	/// The task moving this transfer's bytes.
	///
	/// A `URLSessionTask`, not a download task: the refetch that saves a
	/// transfer whose finished file was reclaimed streams its bytes through a
	/// data task, and every path that cancels work — the row's cancel button,
	/// the stall sweep, the job being stopped from the card — must reach it
	/// through this same property.
	var task: URLSessionTask?
	var resumeData: Data?
	/// Whether this transfer has already been retried on the background session
	/// after failing in-process without moving a byte. One retry, once — a second
	/// attempt that also moves no bytes is a real network failure, and retrying it
	/// for ever is how a stuck download becomes a stuck app.
	var didRetryInBackground = false
	/// How many times this transfer has been picked up again after its bytes
	/// stopped moving, with the range the system kept for it. Separate from
	/// `didRetryInBackground`, which is about a transfer that never started.
	var resumeAttempts = 0
	#if DEBUG
	/// Set by the `-killmidway` drill, so a socket can be taken away in the
	/// middle of a transfer the way a suspension takes it.
	var didKillMidway = false
	/// The byte count a revival started from, logged once on the first tick
	/// that follows it — the evidence that a stopped download carried on
	/// rather than starting over.
	var revivedFromBytes: Int64?
	#endif
	/// Set once this transfer has been handed to the import/signing pipeline, so
	/// a late duplicate callback — the background session can deliver the same
	/// finished file twice across a wake-up — cannot import the package twice.
	var didStartProcessing = false

	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
	var sourceProvenance: SourceAppProvenance?
	/// What the caller calls this transfer, when it knows better than the URL
	/// does. An app update is known by the name of the app it is updating; the
	/// URL it comes from is a file name, and a card titled with a file name is a
	/// card the user cannot place.
	let displayName: String?
	/// The bundle identifier this transfer will end up as, when the caller knows
	/// it. The live status is one card for the whole job, and the job's second
	/// half — signing and installing — addresses the app by its bundle id. The
	/// card is started under that name when it is known, so both halves reach
	/// the same card instead of the install half talking to nothing.
	let bundleID: String?

	/// The size the *source* declared for this package, when it declared one.
	///
	/// `URLSession`'s own total is the authority and is used whenever the server
	/// sends a length. It frequently does not: a chunked response, a redirect to
	/// a CDN that streams, a mirror with no `Content-Length` — and then
	/// `totalBytesExpectedToWrite` is `-1` for the whole transfer. Dividing by
	/// nothing made every fraction 0, so the island sat on "0%" from the first
	/// byte to the last while the file was demonstrably arriving, and the detail
	/// under it read "Connecting…" for a transfer that had been connected for
	/// minutes. The repository already knows how big the package is; a download
	/// with no length of its own borrows that one.
	var declaredBytes: Int64

	/// The size to divide by: what the server said, else what the source said.
	/// Zero means the fraction genuinely is unknown, and the card says so
	/// instead of claiming zero.
	var expectedBytes: Int64 {
		if totalBytes > 0 { return totalBytes }
		return declaredBytes > 0 ? declaredBytes : 0
	}

	init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false,
		bundleID: String? = nil,
		displayName: String? = nil,
		sourceProvenance: SourceAppProvenance? = nil,
		declaredBytes: Int64 = 0
	) {
		self.id = id
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.bundleID = bundleID
		self.displayName = displayName
		self.sourceProvenance = sourceProvenance
		self.fileName = url.lastPathComponent
		self.declaredBytes = max(declaredBytes, 0)
	}

	/// What the live card calls this transfer.
	var cardName: String {
		if let displayName, !displayName.isEmpty { return displayName }
		return DownloadManager.displayName(for: url)
	}

	/// The name the live card is keyed by: the bundle id when the caller knew
	/// it, and the transfer's own id otherwise.
	var liveID: String { bundleID ?? id }
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()

	/// The transfer half of the pipeline, in the console.
	///
	/// Whether a relaunch continued a download or started a second copy of it is
	/// invisible from inside the app — both look like a progress bar moving — so
	/// the one moment that difference is decided is said out loud.
	private static let log = Logger(subsystem: "app.batsign.ios", category: "download")

	@Published var downloads: [Download] = []

	/// Bumped whenever a transfer's own numbers move.
	///
	/// `Download`'s progress is published on the `Download`, and a view that only
	/// observes the manager would never see a byte arrive — which is exactly why
	/// the storefront's ring used to sit still while a file downloaded. One
	/// counter on the manager gives every observer a tick to redraw on.
	@Published private(set) var progressRevision: UInt64 = 0

	func progressDidMove() {
		progressRevision &+= 1
	}

	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}

	private var _session: URLSession!

	/// Where a downloaded package waits to be unpacked.
	///
	/// Deliberately *not* the temporary directory. That is scratch space the
	/// app empties on launch — a cache reset that is right for caches and wrong
	/// for a package: a job interrupted between the last byte arriving and the
	/// signature being applied leaves its staged package here, and the next
	/// launch is the moment it is supposed to be picked up and signed. Clearing
	/// the directory it lives in turned "resume this job" into "download it
	/// again", and for a package whose URL has since gone away, into "lose it".
	/// Application Support belongs to this app and nothing else clears it.
	static var stagingDirectory: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("FeatherDownloads", isDirectory: true)
	}

	/// Where staged packages lived before the move out of `temporaryDirectory`.
	/// Read once, at recovery, so a job interrupted across the upgrade is still
	/// picked up rather than re-fetched.
	static var legacyStagingDirectory: URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("FeatherDownloads", isDirectory: true)
	}

	/// The transfers, readable from any queue.
	///
	/// `downloads` is what the storefront observes, and it is main-actor state.
	/// URLSession calls its delegate on a queue of its own — `download(for:)`
	/// runs there — and reaching into the published array from off the main
	/// actor is a data race against every view enumerating it. The registry
	/// holds the same objects behind a lock, so the transfer half can find its
	/// own work without touching what the UI is reading.
	private let _registryLock = NSLock()
	private var _registry: [Download] = []

	private func register(_ download: Download) {
		_registryLock.lock(); defer { _registryLock.unlock() }
		guard !_registry.contains(where: { $0 === download }) else { return }
		_registry.append(download)
	}

	private func unregister(_ download: Download) {
		_registryLock.lock(); defer { _registryLock.unlock() }
		_registry.removeAll { $0 === download }
	}

	private func registered(task: URLSessionTask) -> Download? {
		_registryLock.lock(); defer { _registryLock.unlock() }
		return _registry.first { $0.task === task }
	}

	private func registered(url: URL) -> Download? {
		_registryLock.lock(); defer { _registryLock.unlock() }
		return _registry.first { $0.url == url }
	}

	private func registered(id: String) -> Download? {
		_registryLock.lock(); defer { _registryLock.unlock() }
		return _registry.first { $0.id == id }
	}

	/// What the registry holds, for the one log line that has to explain why a
	/// finished file could not be matched to a transfer.
	var _registryDescription: String {
		_registryLock.lock(); defer { _registryLock.unlock() }
		guard !_registry.isEmpty else { return "empty" }
		return _registry
			.map { "\($0.id.prefix(8)):\($0.url.absoluteString)" }
			.joined(separator: " | ")
	}

	/// Every transfer, for the paths that used to walk `downloads`.
	var allDownloads: [Download] {
		_registryLock.lock(); defer { _registryLock.unlock() }
		return _registry
	}

	#if !targetEnvironment(macCatalyst)
	/// The transfer holds the app up while it runs; the signing job that follows
	/// it takes its own hold, so the gap between the two is never suspendable.
	///
	/// The hold is what keeps the process scheduled, and it is enough — but on
	/// iOS 26 it is no longer the whole story. `BGContinuedProcessingTask` is the
	/// system's own mechanism for work the user started and is watching, and it
	/// is taken alongside this hold (in `BSJobKeepAlive`, once for the whole job
	/// rather than once per phase) so that the app is running with the system's
	/// permission rather than on the sufferance of a background mode.
	///
	/// It used to be taken from here, once per transfer, with the package's file
	/// name as its title and nothing said when the download ended — which is what
	/// put a second, stale card beside this app's own and got the mechanism taken
	/// out. The difference now is that there is one grant for the whole job and
	/// the card it drives is fed the same phase and the same fraction as the
	/// island: the two surfaces cannot disagree because they are told the same
	/// thing at the same moment.
	private func _updateBackgroundAudioState() {
		let hasTransfers = !downloads.isEmpty
		Task { @MainActor in
			if hasTransfers {
				BSJobKeepAlive.shared.begin(BSJobKeepAlive.Reason.download)
			} else {
				BSJobKeepAlive.shared.end(BSJobKeepAlive.Reason.download)
			}
		}
	}
	#endif

	/// The transfer is over, or gone: out of the list the views read and out of
	/// the registry the delegate queue reads.
	///
	/// Main-actor only, like the list itself. Every removal goes through here so
	/// the two cannot drift apart — a transfer left in the registry is a
	/// callback that still finds an owner for work that has ended.
	@MainActor
	private func _drop(_ download: Download) {
		_disarmStallCheck(for: download)
		_lastByteAt[download.id] = nil
		unregister(download)
		guard let index = downloads.firstIndex(where: { $0 === download }) else { return }
		downloads.remove(at: index)
		Self.log.notice("download: dropped \(download.id.prefix(8), privacy: .public) — \(self.downloads.count, privacy: .public) left in memory, [\(self._registryDescription, privacy: .public)] in the registry")

		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif

		_stopStallSweepIfIdle()
	}

	// MARK: - Failing out loud

	/// The transfer is over and it did not deliver.
	///
	/// One place, so that no path can end quietly. All of them used to: the
	/// island card faded within seconds, nothing was written to the activity
	/// log, and nothing was said in the app or outside it — so a download that
	/// died for any reason at all was indistinguishable from one that was never
	/// started. The name, the reason, and the record come from here.
	///
	/// Called from the delegate's own queue as well as from the main actor; the
	/// reporting itself lands on the main actor.
	@MainActor
	private func _fail(_ download: Download, reason: String) {
		let name = download.cardName
		let identifier = download.liveID
		Self.log.error("download: failed \(download.id.prefix(8), privacy: .public) — \(reason, privacy: .public)")
		LiveStatus.finish(success: false, appName: name, detail: reason, appID: identifier)
		AutoSignManager.shared.announceDownloadFailed(name: name, identifier: identifier, message: reason)
		// The job is over and it did not work: the grant the system gave for it
		// goes back as an unsuccessful one, from the place that knows.
		BSJobKeepAlive.shared.failed()
		// And it is over for the journal too. A failure is an ending, not an
		// interruption: left on file, the next launch reads it as work that was
		// cut off and picks it up — a second attempt at something the user has
		// already been told failed, and a second popup to go with it.
		//
		// Keyed to this transfer: the single-slot record may already belong to
		// the next download, and an unkeyed clear deletes that one's staged
		// package while its import is reading it.
		BSJobJournal.shared.clearIf(transferID: download.id)
	}

	/// The bytes are here. Recorded before the import begins, so that a package
	/// which later fails to sign is not confused with one that never arrived.
	@MainActor
	private func _noteDelivered(_ download: Download) {
		AutoSignManager.shared.announceDownloadFinished(name: download.cardName)
	}

	/// How long a transfer may move nothing before it is treated as stalled.
	///
	/// A task can be accepted by the background daemon and never run — on a
	/// device with background refresh off, or after a relaunch into a session
	/// the daemon no longer has — and nothing is ever delivered: no bytes, and
	/// no error either. The ring then sits at 0% for as long as the app is open,
	/// which is the "it says downloading and never downloads" report. The first
	/// byte of a real download arrives in a second or two; a whole minute of
	/// nothing is a task that is not running.
	static let stallDeadline: TimeInterval = 60

	@MainActor
	private var _stallChecks: [String: DispatchWorkItem] = [:]

	/// Watch a transfer for its first byte.
	@MainActor
	private func _armStallCheck(for download: Download) {
		_stallChecks[download.id]?.cancel()
		let id = download.id
		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			self._stallChecks[id] = nil
			self._stallCheckFired(id: id)
		}
		_stallChecks[id] = work
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallDeadline, execute: work)
	}

	@MainActor
	private func _disarmStallCheck(for download: Download) {
		_stallChecks[download.id]?.cancel()
		_stallChecks[download.id] = nil
	}

	/// How long a running transfer may move no bytes before it is declared dead.
	///
	/// The first-byte deadline above does not cover a connection that dies
	/// mid-body: the bytes began, the delegate stopped firing, and with a
	/// default session there is no resource timeout to speak of for days. The
	/// island then holds its last fraction for ever — "streaming" is exactly
	/// what it stops doing. A sweep every quarter of the window compares the
	/// last byte stamp of each running transfer against the clock; whichever
	/// one has been silent for the whole window is failed with that as the
	/// reason, so a dead connection can never leave a frozen card behind.
	static let midTransferStallWindow: TimeInterval = 90

	/// The moment each running transfer last moved a byte, by transfer id.
	/// Written from the byte tick on the main actor and read by the stall
	/// sweep, which also lives on the main actor.
	@MainActor
	private var _lastByteAt: [String: Date] = [:]

	/// The refetch in flight — the session that writes a reclaimed download's
	/// bytes into a file this app owns — and how many times each transfer has
	/// needed one.
	@MainActor private var _rescue: DownloadRescue?
	@MainActor private var _rescueAttempts: [String: Int] = [:]

	@MainActor
	private var _stallSweep: Timer?

	@MainActor
	private func _ensureStallSweep() {
		guard _stallSweep == nil else { return }
		_stallSweep = Timer.scheduledTimer(
			withTimeInterval: Self.midTransferStallWindow / 4,
			repeats: true
		) { [weak self] _ in
			Task { @MainActor [weak self] in self?._sweepSilentTransfers() }
		}
	}

	@MainActor
	private func _stopStallSweepIfIdle() {
		guard downloads.isEmpty else { return }
		_stallSweep?.invalidate()
		_stallSweep = nil
		_lastByteAt.removeAll()
	}

	@MainActor
	private func _noteByteArrival(for download: Download) {
		_lastByteAt[download.id] = Date()
		_ensureStallSweep()
	}

	/// How long a running transfer may go without a byte and still have its
	/// fraction presented as live progress.
	///
	/// Longer than any healthy callback gap — a throttled or slow link still
	/// reports every second or two — and short enough that a transfer which
	/// died while the screen was locked is not shown as moving by the time the
	/// user has looked at the island again.
	static let liveSilenceWindow: TimeInterval = 10

	/// Whether this transfer has moved a byte recently enough that its fraction
	/// still describes work in progress.
	///
	/// It reads the same stamp the stall sweep keeps, so the two cannot disagree
	/// about whether a transfer is moving. A transfer that went under with the
	/// screen — the socket died while the app was suspended — is silent by this
	/// measure, which is the point: its last fraction must not be handed to the
	/// card as though it were live.
	@MainActor
	func isTransferMoving(_ download: Download) -> Bool {
		guard download.progress < 0.999 else { return false }
		guard let last = _lastByteAt[download.id] else { return false }
		return Date().timeIntervalSince(last) < Self.liveSilenceWindow
	}

	/// Look for stopped transfers now, instead of at the sweep's next tick.
	///
	/// The sweep is a main-runloop timer, and a suspended app runs no timers: a
	/// transfer that died during a lock-screen stretch is therefore not noticed
	/// until a full sweep interval after the user is back, with the card parked
	/// on its last number for all of it. The moment the app is up again is
	/// exactly when that question can be asked, so it is asked here. The sweep's
	/// own window is untouched — a healthy slow transfer is still not swept —
	/// so all this changes is *when* a genuine stop is noticed.
	@MainActor
	func recheckStalledTransfers() {
		guard !downloads.isEmpty else { return }
		_sweepSilentTransfers()
	}

	/// Fail every transfer that has moved no bytes for the whole window.
	///
	/// A stall is not an ending. The bytes that did arrive are the user's, the
	/// system kept the range they cover, and a transfer that has been paid for
	/// once is picked up again from where it stopped — which is the whole of
	/// "the download stops at a random number". Only a transfer that will not
	/// move whatever is asked of it is failed, and only after the attempts run
	/// out.
	@MainActor
	private func _sweepSilentTransfers() {
		let deadline = Date().addingTimeInterval(-Self.midTransferStallWindow)
		for download in downloads where download.progress < 0.999 {
			guard let last = _lastByteAt[download.id], last < deadline else { continue }
			// Stamped before anything is taken down, so the next pass of the
			// sweep does not fire again over the revival that is about to run.
			_lastByteAt[download.id] = Date()
			Self.log.error("download: \(download.id.prefix(8), privacy: .public) has moved no bytes for \(Int(Self.midTransferStallWindow))s at \(download.bytesDownloaded, privacy: .public) bytes — picking it up again")
			_takeBack(download)
		}
		_stopStallSweepIfIdle()
	}

	/// Take a stopped transfer's task back, keeping the range it reached.
	///
	/// A download task is asked for its resume data, which is the range the
	/// server already sent and the system already has; anything else — the
	/// refetch stream, a task with no range — is simply cancelled, and the
	/// revival starts the request again.
	@MainActor
	private func _takeBack(_ download: Download) {
		guard let task = download.task else {
			_revive(download, after: 0)
			return
		}

		if let downloadTask = task as? URLSessionDownloadTask {
			downloadTask.cancel(byProducingResumeData: { data in
				DispatchQueue.main.async { [weak self] in
					if let data, !data.isEmpty {
						download.resumeData = data
					}
					self?._revive(download, after: 0)
				}
			})
			return
		}

		task.cancel()
		_revive(download, after: 0.5)
	}

	/// How many times a transfer whose bytes stopped is picked up again.
	///
	/// A download that has already been paid for is not thrown away at whatever
	/// fraction it reached: the socket that died is replaced by a new one, and
	/// the bytes past it are the same bytes. Four attempts, each asking for the
	/// range the system kept, ride out a suspension, a handover between
	/// networks, and a mirror that dropped the connection.
	static let resumeAttempts = 4

	/// Pick a stopped transfer up again, from where it stopped.
	@MainActor
	private func _revive(_ download: Download, after delay: TimeInterval) {
		guard download.resumeAttempts < Self.resumeAttempts else {
			let moved = Download.byteFormatter.string(fromByteCount: download.bytesDownloaded)
			Self.log.error("download: \(download.id.prefix(8), privacy: .public) stopped \(download.resumeAttempts, privacy: .public) times, last at \(moved, privacy: .public) — giving up")
			_fail(download, reason: "The connection kept dropping after \(moved). Try again on a steadier network.")
			_drop(download)
			return
		}
		download.resumeAttempts += 1
		let attempt = download.resumeAttempts

		let start: () -> Void = { [weak self] in
			guard let self else { return }
			// Somebody ended it in the meantime — the row's cancel, the job
			// stopped from the card. A revival must not resurrect that.
			guard self.downloads.contains(where: { $0 === download }) else { return }

			let task: URLSessionDownloadTask
			if let data = download.resumeData, !data.isEmpty {
				task = self._session.downloadTask(withResumeData: data)
			} else {
				// No range to ask for — a server that does not support them, or a
				// task that never got far enough to have one. Starting over is the
				// only thing left, and it is still better than a frozen card.
				task = self._session.downloadTask(with: download.url)
			}
			download.resumeData = nil
			download.task = task
			task.resume()
			#if DEBUG
			download.revivedFromBytes = download.bytesDownloaded
			#endif

			Self.log.notice("download: \(download.id.prefix(8), privacy: .public) picked up again from \(download.bytesDownloaded, privacy: .public) bytes (attempt \(attempt, privacy: .public))")
			LiveStatus.update(
				phase: .downloading,
				appName: download.cardName,
				progress: download.transferProgress,
				detail: "Resuming…",
				progressKnown: download.expectedBytes > 0,
				force: true,
				appID: download.liveID,
				mode: CompressionMode.stored.label
			)
			// The silence window starts now, so a revival that moves nothing is
			// noticed like any other stopped transfer rather than waiting out a
			// window that was already half spent.
			self._noteByteArrival(for: download)
			self._armStallCheck(for: download)
		}

		if delay > 0 {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: start)
		} else {
			start()
		}
	}

	/// The deadline passed with nothing to show for it.
	///
	/// The first time, the same answer the delegate's zero-byte failure gets:
	/// the URL is asked for again through the background session, whose daemon
	/// owns a socket of its own and keeps it open across a suspension. The
	/// second time there is nothing left to try, and the user is told — with the
	/// row going back to "Get" rather than a ring that means "waiting for ever".
	@MainActor
	private func _stallCheckFired(id: String) {
		guard let download = downloads.first(where: { $0.id == id }), download.bytesDownloaded == 0 else { return }

		download.task?.cancel()

		guard download.didRetryInBackground else {
			download.didRetryInBackground = true
			let retry = backgroundSession.downloadTask(with: download.url)
			download.task = retry
			retry.resume()
			LiveStatus.update(
				phase: .downloading,
				appName: download.cardName,
				progress: 0,
				detail: "Connecting…",
				// A retry starts at no bytes, which is a real fraction only when
				// there is a size to divide by. Without one, "0%" is the same lie
				// the transfer's own ticks refuse to tell.
				progressKnown: download.expectedBytes > 0,
				force: true,
				appID: download.liveID,
				mode: CompressionMode.stored.label
			)
			_armStallCheck(for: download)
			return
		}

		_fail(download, reason: "The download never started. Check the connection and try again.")
		_drop(download)
	}

	override init() {
		super.init()

		// A transfer runs in this process, exactly as it does in Feather, which is
		// the implementation this one is measured against.
		//
		// The other way round was tried and is a trap: a task handed to the
		// background daemon can be *accepted and never run* — no bytes, no error,
		// nothing to react to — while the row sits at "Connecting…" until the app
		// is killed. That is the "it downloads and then nothing happens" this app
		// was reported for, and it is reproducible: the daemon is free to hold a
		// task for as long as it likes, so there is no callback to fall back on.
		// A default session has no such middleman. Its sockets belong to the app,
		// and a request either goes out or fails where it can be seen and said.
		//
		// What that costs is suspension: the app must be kept up for the length of
		// the job, which is what the holds do — the audio session, the background
		// assertion, and on iOS 26 the continued-processing task that the system
		// grants for exactly this ("user-initiated work that outlives the
		// foreground"). The bytes, the extraction, the signing and the install
		// hand-off all happen under those holds, so switching apps or locking the
		// screen does not break the chain.
		let configuration = URLSessionConfiguration.default
		configuration.allowsCellularAccess = true
		configuration.httpMaximumConnectionsPerHost = 4
		// A phone that walks out of Wi-Fi reach, or whose screen locks as the
		// network hands over to cellular, must not become a dead download: with
		// this set, the request waits for the network to come back and carries on
		// from where it stopped, instead of failing at whatever number it had
		// reached.
		configuration.waitsForConnectivity = true

		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
	}

	/// The transfer that can keep arriving while the app cannot: a background
	/// session belonging to a system daemon.
	///
	/// It is not the way a download starts here — see `init` — but it is not
	/// useless either. A task the in-process session fails on without having
	/// moved a single byte is retried once through this session, because that
	/// failure is the network refusing the app rather than the server refusing
	/// the transfer, and the daemon is a second, independent socket that
	/// survives the app being suspended. It is the same one-shot retry as
	/// before, pointed the other way: the reliable path first, the durable one
	/// as the answer to it failing.
	private var _backgroundSession: URLSession?

	private var backgroundSession: URLSession {
		if let _backgroundSession { return _backgroundSession }

		let configuration: URLSessionConfiguration
		#if targetEnvironment(macCatalyst)
		configuration = .default
		#else
		configuration = .background(withIdentifier: "app.batsign.ios.transfer")
		configuration.sessionSendsLaunchEvents = true
		configuration.isDiscretionary = false
		configuration.waitsForConnectivity = false
		#endif
		configuration.allowsCellularAccess = true
		configuration.httpMaximumConnectionsPerHost = 4

		let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
		_backgroundSession = session
		return session
	}

	/// The handler iOS hands over when it has woken the app for a background
	/// session. It is called when there is nothing left for the session to
	/// deliver, and until then the app must stay up — otherwise the package that
	/// just arrived is dropped instead of signed.
	private var _backgroundCompletion: (() -> Void)?

	func attachBackgroundCompletion(_ handler: @escaping () -> Void) {
		_backgroundCompletion = handler
	}

	func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		DispatchQueue.main.async { [weak self] in
			self?._backgroundCompletion?()
			self?._backgroundCompletion = nil
		}
	}

	/// The transfer a callback belongs to.
	///
	/// Matching on the task itself is the ordinary case. The fallback matters
	/// after the app was killed and woken by the system: the in-memory list is
	/// gone, the task object iOS hands back is a new one, and the only thing the
	/// two have in common is the URL they are both about. Without this, a
	/// download that completed in the background would be delivered to a delegate
	/// that could not recognise it and quietly dropped — which is exactly the
	/// "app from a source never appears in the library and never signs" bug: the
	/// package was fully downloaded, then thrown away at this guard.
	///
	/// The journal is checked before the live list for the same reason: a
	/// relaunch has an empty list and a journal entry naming the transfer, and
	/// the journal — written before the first byte moved — is the record that
	/// survives the kill. The rebuilt entry is appended to `downloads` so
	/// progress ticks and the remove-on-completion path reach it like any other
	/// transfer; the store views then recognise the import by URL as usual.
	private func download(for task: URLSessionTask) -> Download? {
		if let task = task as? URLSessionDownloadTask, let match = registered(task: task) {
			return match
		}
		guard let url = task.originalRequest?.url ?? task.currentRequest?.url else { return nil }
		// The download the system is finishing is the one whose URL is still
		// being worked on; a URL that appears twice is the same transfer, because
		// `startDownload` refuses to begin a second one for it.
		if let live = registered(url: url) {
			return live
		}
		// Nobody in memory — the wake-up case. Rebuild the transfer from the
		// journal, which carries the transfer's id and bundle id but not its
		// store provenance; the import below then links the Library entry by URL
		// exactly as a foreground store download does.
		guard let pending = BSJobJournal.shared.pending,
		      pending.url == url.absoluteString else { return nil }

		let rebuilt = Download(
			id: pending.transferID,
			url: url,
			bundleID: pending.bundleID,
			displayName: pending.name
		)
		register(rebuilt)
		// Into the published list on the main actor, so the views follow it —
		// and into the registry above, which is how the transfer half reaches it
		// from the queue this call is running on.
		DispatchQueue.main.async { [weak self] in
			guard let self, !self.downloads.contains(where: { $0 === rebuilt }) else { return }
			self.downloads.append(rebuilt)

			#if !targetEnvironment(macCatalyst)
			self._updateBackgroundAudioState()
			#endif
		}
		return rebuilt
	}

	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		bundleID: String? = nil,
		displayName: String? = nil,
		sourceProvenance: SourceAppProvenance? = nil,
		expectedBytes: Int64 = 0
	) -> Download {
		let requestHasSourceProvenance = sourceProvenance != nil
		if let existingDownload = downloads.first(where: {
			$0.url == url && ($0.sourceProvenance != nil) == requestHasSourceProvenance
		}) {
			// The resumed transfer may have been started before the caller knew
			// how big the package was; the size it knows now is the one the card
			// needs to move off an unmeasurable bar.
			if existingDownload.declaredBytes == 0, expectedBytes > 0 {
				existingDownload.declaredBytes = expectedBytes
			}
			resumeDownload(existingDownload)
			return existingDownload
		}

		let download = Download(
			id: id,
			url: url,
			bundleID: bundleID,
			displayName: displayName,
			sourceProvenance: sourceProvenance,
			declaredBytes: expectedBytes
		)

		// Written down before a byte moves. The journal is what makes a transfer
		// that is interrupted — by a kill, by memory pressure, by the user
		// swiping the app away — something to pick up instead of something to
		// explain. It is cleared only when the whole job is over.
		BSJobJournal.shared.record(
			transfer: id,
			url: url,
			bundleID: bundleID,
			name: download.cardName
		)

		// Registered and listed *before* the task is resumed. A transfer that
		// completes quickly — a cached response, a file on the local network —
		// can deliver its callbacks before this function returns, and a delegate
		// that cannot find the transfer it belongs to drops the finished package.
		// That is the whole of "it downloaded and then nothing happened".
		register(download)
		downloads.append(download)

		let task = _session.downloadTask(with: url)
		download.task = task
		task.resume()

		// A task that is accepted and never runs delivers neither bytes nor an
		// error, so the deadline is the only thing that can notice.
		DispatchQueue.main.async { [weak self] in
			self?._armStallCheck(for: download)
		}

		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif

		LiveStatus.begin(
			appID: download.liveID,
			appName: download.cardName,
			detail: "Starting…",
			queued: max(downloads.count - 1, 0),
			bundleID: bundleID,
			mode: CompressionMode.stored.label
		)

		return download
	}

	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		register(download)
		downloads.append(download)

		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif

		LiveStatus.begin(
			appID: download.id,
			appName: download.cardName,
			detail: "Packaging…",
			queued: max(downloads.count - 1, 0),
			mode: CompressionMode.stored.label
		)

		return download
	}

	/// What the live status calls the transfer. The URL's own file name is all the
	/// manager has to go on, and an identifier is friendlier to read than nothing.
	static func displayName(for url: URL) -> String {
		let base = url.deletingPathExtension().lastPathComponent
		let cleaned = base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
		return cleaned.isEmpty ? url.host ?? "App" : cleaned
	}

	/// A staged package name the importer can actually open.
	///
	/// The transfer names its file after whatever the server or URL called it,
	/// and a storefront's download URL is not obliged to end in `.ipa`: an
	/// endpoint, a record id, a bare token — anything at all. Unpacking decides
	/// whether a file is a zip by its extension alone, and a package staged as
	/// `download` is refused before a byte of it is read. The refusal is even
	/// reported as a missing file, because that is the error an unrecognised
	/// extension raises — for a file that is demonstrably sitting on disk.
	///
	/// What the user sees is the bug this exists to stop: the download they
	/// watched to 100% disappears, and the app never appears in the Library.
	///
	/// Nothing about the transfer changes here — the bytes are an IPA because
	/// the job was an install. Only the name is made to say so.
	static func importablePackageName(_ proposed: String) -> String {
		let archiveExtensions: Set<String> = ["ipa", "tipa", "zip", "cbz"]
		// The last component, so a name from a header can never introduce a
		// directory component and stage the package somewhere else.
		let cleaned = (proposed as NSString).lastPathComponent
			.trimmingCharacters(in: .whitespacesAndNewlines)

		guard !cleaned.isEmpty, cleaned != "." else { return "package.ipa" }

		let fileExtension = (cleaned as NSString).pathExtension.lowercased()
		return archiveExtensions.contains(fileExtension) ? cleaned : "\(cleaned).ipa"
	}

	/// Adopt the transfers the system is still running for this app.
	///
	/// A relaunch is not a reason to fetch the package a second time. The
	/// transfer belongs to the background daemon, not to this process: when the
	/// app is opened again mid-download — or woken by the system — the same task
	/// is usually still moving bytes, and asking for the URL again starts a
	/// *second* copy of the same file. That is the download a user watches start
	/// over from zero beside another one quietly filling the disk, and on a slow
	/// link it is also twice the data.
	///
	/// So before anything is started the background session is asked what it is
	/// already running, and what it names is re-attached to a transfer the app can
	/// show and follow. Progress, cancellation and the end of the download all
	/// then arrive through the delegate for it, exactly as if this process had
	/// started it in the first place.
	///
	/// Only the background session is asked: an in-process transfer dies with the
	/// process that owns it, so there is nothing of it to adopt. This is the path
	/// a relaunch takes when a retry was handed to the daemon.
	@MainActor
	func adoptRunningTransfers() async {
		let tasks = await backgroundSession.allTasks
		let running = tasks.compactMap { $0 as? URLSessionDownloadTask }
		guard !running.isEmpty else { return }

		let pending = BSJobJournal.shared.pending
		var adopted = 0

		for task in running {
			guard let url = task.originalRequest?.url ?? task.currentRequest?.url else { continue }

			// Already known: point it at the task the system is actually running,
			// which is not the object this process holds after a relaunch.
			if let existing = downloads.first(where: { $0.url == url }) {
				existing.task = task
				continue
			}

			let isJournalled = pending?.url == url.absoluteString
			let download = Download(
				id: (isJournalled ? pending?.transferID : nil) ?? UUID().uuidString,
				url: url,
				bundleID: isJournalled ? pending?.bundleID : nil,
				displayName: isJournalled ? pending?.name : nil
			)
			download.task = task
			register(download)
			downloads.append(download)
			adopted += 1

			// An adopted task stalls like any other — the daemon hands back what
			// it was running, and sometimes that is nothing at all.
			_armStallCheck(for: download)

			LiveStatus.begin(
				appID: download.liveID,
				appName: download.cardName,
				detail: "Resuming…",
				queued: max(downloads.count - 1, 0),
				bundleID: download.bundleID,
				mode: CompressionMode.stored.label
			)
		}

		guard adopted > 0 else { return }

		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif

		Self.log.notice("download: re-attached to \(adopted, privacy: .public) transfer(s) the system was still running")
	}

	func resumeDownload(_ download: Download) {
		// A resume can be the first thing that happens after the app was killed
		// with the transfer half-done, so the live card is started here too.
		LiveStatus.begin(
			appID: download.liveID,
			appName: download.cardName,
			detail: "Resuming…",
			queued: max(downloads.count - 1, 0),
			bundleID: download.bundleID,
			mode: CompressionMode.stored.label
		)

		// Already moving. "Resume" a download the system is still transferring and
		// the request is issued a second time, which is the same duplicate this
		// class goes out of its way to avoid everywhere else.
		if let task = download.task, task.state == .running || task.state == .suspended {
			Self.log.notice("download: already running — leaving it alone")
			return
		}

		// In the published list, because a resume can be the first thing that
		// happens to a transfer this process has just rebuilt from the journal.
		if !downloads.contains(where: { $0 === download }) {
			register(download)
			downloads.append(download)
		}

		// Three ways to get the bytes moving again, and the last one is the
		// fallback rather than an omission: resume data when the system kept it,
		// the task's own URL when there is a task to ask, and the transfer's URL
		// when neither exists — which is the state a rebuilt-from-journal entry
		// is in. Without that last branch a resume did nothing at all: the card
		// said "Resuming…" and the bytes never moved, which is one of the shapes
		// of "I tapped it and nothing happened".
		if let resumeData = download.resumeData {
			let task = _session.downloadTask(withResumeData: resumeData)
			download.task = task
			task.resume()
		} else {
			let url = download.task?.originalRequest?.url ?? download.url
			let task = _session.downloadTask(with: url)
			download.task = task
			task.resume()
		}

		DispatchQueue.main.async { [weak self] in
			self?._armStallCheck(for: download)
		}

		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif
	}

	func cancelDownload(_ download: Download) {
		download.task?.cancel()
		_removeProgressNotification(for: download)
		// A cancelled transfer is over on purpose. Nothing to pick up — but only
		// *this* transfer's record, never the one a concurrent download owns.
		BSJobJournal.shared.clearIf(transferID: download.id)

		DispatchQueue.main.async { [weak self] in
			self?._disarmStallCheck(for: download)
			self?._lastByteAt[download.id] = nil
		}

		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
			downloads.remove(at: index)

			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		}
		unregister(download)

		// A cancel must never leave a bar sitting in the island: the last transfer
		// going away ends the card, anything still running takes it over.
		//
		// The hand-off is keyed to the cancelled transfer, not to "whatever is
		// up". An unkeyed `end()` took down the card of a *different* job — a
		// signing or an install in flight — and the island froze on that job's
		// last frame for the rest of it, because every push after was discarded
		// as belonging to a card that no longer existed.
		if let next = downloads.last {
			LiveStatus.update(
				phase: .downloading,
				appName: next.cardName,
				progress: next.transferProgress,
				detail: "",
				queued: max(downloads.count - 1, 0),
				force: true,
				appID: next.liveID,
				mode: CompressionMode.stored.label
			)
		} else {
			LiveStatus.end(appID: download.liveID)
		}
	}

	/// Whether a transfer id names work the user asked for by hand.
	///
	/// Two prefixes are in use for the same action — the Updates tab starts a
	/// manual update under `BatSignManualUpdate_`, the Library under
	/// `FeatherManualDownload_` — and this used to recognise only the second.
	/// A manual update started from Updates was therefore invisible to
	/// `manualDownloads`, and to the download header that reads it: the header
	/// the user watches said nothing while the app they tapped was fetching.
	func isManualDownload(_ string: String) -> Bool {
		string.contains("FeatherManualDownload") || string.contains("BatSignManualUpdate")
	}

	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}

	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}

	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}

	/// Clears the per-transfer notification an older build used to post.
	///
	/// Progress is a live activity now, and it must not also be a notification:
	/// re-posting a request under the same identifier *re-alerts* rather than
	/// quietly replacing, so the old code produced a fresh banner at 10%, then
	/// 20%, then 30% — a stream of notifications narrating a download the island
	/// was already showing. Nothing posts these any more; this only sweeps away
	/// anything an upgrading install left behind.
	func _removeProgressNotification(for download: Download) {
		let identifiers = ["signos.download.\(download.id)"]
		let center = UNUserNotificationCenter.current()
		center.removeDeliveredNotifications(withIdentifiers: identifiers)
		center.removePendingNotificationRequests(withIdentifiers: identifiers)
	}
}

extension DownloadManager: URLSessionDownloadDelegate {

	func handlePachageFile(url: URL, dl: Download) throws {
		Self.log.notice("download: handing \(dl.id.prefix(8), privacy: .public) to the importer — \(url.lastPathComponent, privacy: .public)")
		FR.handlePackageFile(url, download: dl) { err in
			if err != nil {
				let generator = UINotificationFeedbackGenerator()
				generator.notificationOccurred(.error)

				// The package arrived and could not be opened. That is a download
				// that ends with no app in the Library, which is the same
				// disappointment as a failed transfer — and it is reported the
				// same way, with the importer's own reason.
				DispatchQueue.main.async {
					DownloadManager.shared._fail(
						dl,
						reason: err?.localizedDescription ?? "Couldn't open the package"
					)
				}
			} else {
			// An update is re-signed and re-installed the same way a first
			// install is, and it is named as the phase that exists for it: the
			// user tapped "Update" on an app they already have, and the card
			// says which of the two jobs this is. The transfer's own id is what
			// says so — the id the updater starts its downloads under, and the
			// one a manual update shares with it now.
			let isUpdate = dl.id.hasPrefix(BatSignAuto.downloadPrefix)
				|| dl.id.hasPrefix(BatSignAuto.manualUpdatePrefix)
			LiveStatus.update(
				phase: isUpdate ? .updating : .signing,
				appName: dl.cardName,
				progress: 0,
				detail: isUpdate ? "Updating" : "Signing and installing",
				// Signing has no fraction of its own, and a zero handed over
				// without saying so is a zero the island may print.
				progressKnown: false,
				force: true,
				appID: dl.liveID,
				mode: CompressionMode.stored.label
			)
			}

			DispatchQueue.main.async {
				DownloadManager.shared._removeProgressNotification(for: dl)
				DownloadManager.shared._drop(dl)
			}
		}
	}

	/// The answer the server gave, or nil when the transfer is not HTTP.
	///
	/// A download is not complete just because URLSession handed the bytes over:
	/// every status has a body, and a 404's body is nine characters that unzip
	/// later as `ZipError error 1` — an error that names the symptom and hides
	/// that the server refused the file. The status is read here, while the
	/// response still exists, so the failure the user reads is the server's own
	/// answer rather than a zip library's complaint about it.
	private func _serverStatus(for task: URLSessionTask) -> Int? {
		(task.response as? HTTPURLResponse)?.statusCode
	}

	/// Whether the file on disk begins with the bytes of a zip archive.
	///
	/// Every installable package — an ipa, a tipa — is a zip. A server that
	/// answers 200 with an error page, a login wall, or a truncated file
	/// delivers bytes that pass the status check above and then die at unzip
	/// with the same symptom-only error. Reading the signature here is what
	/// separates "the package is bad" from "this was never a package", and it
	/// is the difference the user reads.
	private static func _hasZipSignature(at url: URL) -> Bool {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
		defer { try? handle.close() }
		guard let magic = try? handle.read(upToCount: 2), magic.count == 2 else { return false }
		return magic == Data([0x50, 0x4B]) // "PK"
	}

	/// What the user reads when the system takes a finished download back.
	///
	/// The raw error for that failure is a sentence about a
	/// `CFNetworkDownload_*.tmp` file and a folder nobody has ever seen — the
	/// message the user's device has been showing. None of it says what to do.
	/// This does, and it is the only wording any path in this file may use for
	/// that failure.
	static let vanishedDownloadMessage =
		"The finished download could not be found, and BatSign could not fetch it again. Try the download again."

	/// What the package did after it arrived, so the caller can act on the cause
	/// rather than on a sentence about a file it cannot see.
	enum StagingOutcome {
		/// The bytes the system handed over are now the package in staging.
		case staged
		/// Staging already holds this transfer's package — the duplicate
		/// delivery a wake-up produces. The copy on disk is the download.
		case alreadyStaged
	}

	/// Why a finished file is not in staging.
	enum StagingFailure: Error {
		/// The system reclaimed its temp file before a byte of it could be
		/// saved, and staging holds no copy. Recoverable, and recovered: the
		/// same URL is fetched again into a file this app owns.
		case sourceVanished
		/// The bytes were readable but could not be written where they belong —
		/// no space, no permission, a directory that is not there. Carries the
		/// system's own reason, which is the honest one to repeat.
		case destination(String)
	}

	/// The user-facing sentence for a staging failure.
	static func stagingFailureMessage(_ error: Error) -> String {
		if case StagingFailure.destination(let system) = error, !system.isEmpty {
			return "The package arrived, but BatSign could not save it. \(system)"
		}
		return vanishedDownloadMessage
	}

	/// Put the finished temp file into staging, deciding from the disk rather
	/// than from an error message.
	///
	/// CFNetwork hands the delegate a temp file that exists exactly for the
	/// length of the callback — and, on a device that has just come back from a
	/// suspension or a system update, sometimes not even that. Three things can
	/// be true here: the temp file is present (the normal case), it is gone but
	/// staging already holds this transfer's package (a duplicate delivery whose
	/// first copy landed), or both are gone — the system took the file back,
	/// which is `sourceVanished` and is answered by fetching it again.
	///
	/// The order matters and used to be wrong twice over. The destination is
	/// never removed before the new bytes are safely in staging: it may be the
	/// very package an importer is reading right now, and the old delete-then-
	/// move deleted it and then failed, losing both copies. And the bytes are
	/// *copied* rather than moved, so what the system does to its temp file
	/// after this returns cannot reach the package that was just saved.
	static func _installFinishedFile(
		from location: URL,
		to destination: URL
	) throws -> StagingOutcome {
		let fm = FileManager.default
		let directory = destination.deletingLastPathComponent()
		do {
			try fm.createDirectoryIfNeeded(at: directory)
			_protect(directory)
		} catch {
			throw StagingFailure.destination(error.localizedDescription)
		}

		guard fm.fileExists(atPath: location.path) else {
			// The system has already taken its temp file back. A copy of this
			// transfer's package in staging is still the download.
			if fm.fileExists(atPath: destination.path) { return .alreadyStaged }
			throw StagingFailure.sourceVanished
		}

		let incoming = directory.appendingPathComponent(
			destination.lastPathComponent + ".incoming"
		)
		try? fm.removeItem(at: incoming)

		do {
			try fm.copyItem(at: location, to: incoming)
		} catch {
			// The temp can also be reclaimed between the check and the copy. The
			// disk is the authority, never the error's own claim.
			if fm.fileExists(atPath: destination.path) { return .alreadyStaged }
			if fm.fileExists(atPath: location.path) {
				throw StagingFailure.destination(error.localizedDescription)
			}
			throw StagingFailure.sourceVanished
		}
		_protect(incoming)

		do {
			if fm.fileExists(atPath: destination.path) {
				_ = try fm.replaceItemAt(destination, withItemAt: incoming)
			} else {
				try fm.moveItem(at: incoming, to: destination)
			}
		} catch {
			try? fm.removeItem(at: incoming)
			throw StagingFailure.destination(error.localizedDescription)
		}

		return .staged
	}

	/// The App Store's own protection class.
	///
	/// A staged package is written while the app is doing work the system has
	/// agreed it may do in the background — which is exactly when the phone can
	/// be locked. The default class for these directories is already this one;
	/// saying it here is what keeps a lock screen from turning a finished
	/// download into a permission failure on a device whose defaults differ.
	private static func _protect(_ url: URL) {
		try? FileManager.default.setAttributes(
			[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
			ofItemAtPath: url.path
		)
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
#if DEBUG
		// Verification hook: pretend the system reclaimed the temp file before
		// this callback could stage it — the failure the user's device shows.
		// Set by the `-vanishtemp` launch argument; never compiled into a
		// release build.
		if UserDefaults.standard.bool(forKey: "batsign.debug.vanishTemp") {
			try? FileManager.default.removeItem(at: location)
		}
#endif
		guard let download = download(for: downloadTask) else {
			_keepOrphan(downloadTask, location: location)
			return
		}

		// A delivery whose task this transfer has already moved on from is not
		// this transfer's file — and it must never be treated as one.
		//
		// `download(for:)` falls back to matching by URL, which is what makes a
		// wake-up delivery findable after a relaunch. The same fallback hands a
		// transfer a *stale* delivery for its URL: the background session can
		// deliver one finished file twice (once for the wake-up, once on the
		// next launch), and the transfer that is still moving bytes for that URL
		// — an update and a store download of the same app share one — then
		// receives a callback for a file that was already staged, and under a
		// name that is not its own. There is nothing at its destination, and
		// there never would be: the honest reading is not "your download
		// vanished", it is "this delivery is not yours". The bytes are kept,
		// nothing is failed, and the transfer's own delivery proceeds.
		//
		// `didCompleteWithError` has had this guard all along. Its absence here
		// is what turned a duplicate delivery into a failure the user reads.
		if let live = download.task, (downloadTask as URLSessionTask) !== live {
			Self.log.notice("download: a finished file for \(downloadTask.originalRequest?.url?.absoluteString ?? "nil", privacy: .public) belongs to a task \(download.id.prefix(8), privacy: .public) has moved on from — kept, not processed")
			_keepOrphan(downloadTask, location: location)
			return
		}

		// The background session can deliver one finished file twice — once
		// through the wake-up hand-off and once on the next plain launch. The
		// second copy must not become a second import.
		if download.didStartProcessing { return }
		download.didStartProcessing = true

		// A refusal is not a delivery. URLSession completes a 404 as if it were
		// a download — the error is in the body, not in an `error` — so the
		// status is checked here, before the body is allowed to become the
		// package. The user reads the server's answer ("HTTP 404") instead of a
		// zip library complaining later about a nine-byte "Not Found".
		if let status = _serverStatus(for: downloadTask), !(200...299).contains(status) {
			Self.log.error("download: the server answered HTTP \(status, privacy: .public) for \(download.cardName, privacy: .public)")
			let reason = "The server answered HTTP \(status) for this file."
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				self._fail(download, reason: reason)
				self._drop(download)
			}
			return
		}

		DispatchQueue.main.async { [weak self] in
			self?._disarmStallCheck(for: download)
			self?._lastByteAt[download.id] = nil
		}

		do {
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
			// The name the server chose is not necessarily one the unpacker will
			// accept; the job is an install either way. See
			// `importablePackageName(_:)`. The transfer's own id goes in front:
			// two stores serving the same file name must not stage into the
			// same path, where the second completion would delete the first's
			// package while it is being imported.
			let destinationURL = Self.stagingDirectory.appendingPathComponent(
				"\(download.id)-\(Self.importablePackageName(suggestedFileName))"
			)

			let outcome: StagingOutcome
			do {
				outcome = try Self._installFinishedFile(from: location, to: destinationURL)
			} catch StagingFailure.sourceVanished {
				// The bytes are gone with the system's temp file and staging
				// holds no copy of them. That is a fetch to do over, not a
				// failure to announce: the same URL is asked for again, and the
				// answer is written to a file this app owns, which nothing can
				// take back. The card keeps streaming through all of it.
				Self.log.error("download: \(download.id.prefix(8), privacy: .public) — the system reclaimed the finished file before it could be saved; fetching it again")
				DispatchQueue.main.async { [weak self] in
					self?._beginRescue(for: download, suggestedFileName: suggestedFileName)
				}
				return
			} catch {
				let reason = Self.stagingFailureMessage(error)
				Self.log.error("download: \(download.id.prefix(8), privacy: .public) could not be staged — \(error.localizedDescription, privacy: .public)")
				DispatchQueue.main.async { [weak self] in
					guard let self else { return }
					self._fail(download, reason: reason)
					self._drop(download)
				}
				return
			}

			if case .alreadyStaged = outcome {
				Self.log.notice("download: \(download.id.prefix(8), privacy: .public) was delivered twice — using the package already in staging")
			}

			// The status was success and the body still has to be a package.
			// HTML error pages come back with 200, and a connection that died
			// mid-body can leave a file that ends where the network did. Both
			// unzip later as the zip error the user reported; caught here, they
			// are told for what they are instead.
			guard Self._hasZipSignature(at: destinationURL) else {
				Self.log.error("download: the delivered file is not a zip archive — \(destinationURL.lastPathComponent, privacy: .public)")
				// The junk bytes were already moved into staging, and the journal
				// never pointed at them (staging happens a few lines below), so
				// the failure paths' keyed clear cannot see this file. It is
				// removed here: an error page must not sit in staging for ever,
				// and its name is the one a future legitimate download would
				// have been given.
				try? FileManager.default.removeItem(at: destinationURL)
				let reason = "The file the server sent is not an app package."
				DispatchQueue.main.async { [weak self] in
					guard let self else { return }
					self._fail(download, reason: reason)
					self._drop(download)
				}
				return
			}

			// The bytes are here and they are what signing needs, so the journal
			// is pointed at the staged package: a job that dies during signing is
			// resumed from disk rather than fetched a second time.
			BSJobJournal.shared.stage(transfer: download.id, package: destinationURL)

			DispatchQueue.main.async { [weak self] in
				self?._noteDelivered(download)
			}

			// The transfer is done the moment the bytes are here; everything after
			// this is packaging, which has no fraction of its own — so the island
			// is told there is none and shows that instead of a bar at 100%.
			LiveStatus.update(
				phase: .unpacking,
				appName: download.cardName,
				progress: 0,
				detail: "Preparing the package",
				progressKnown: false,
				force: true,
				appID: download.liveID,
				mode: CompressionMode.stored.label
			)

			try handlePachageFile(url: destinationURL, dl: download)
		} catch {
			// A package that reached 100% and then went nowhere must not do it
			// silently: `print` is invisible on a device, so this is said on the
			// same subsystem the rest of the transfer narrates itself on — and on
			// the card the user is actually watching.
			Self.log.error("download: couldn't hand the package over — \(error.localizedDescription, privacy: .public)")
			let reason = error.localizedDescription
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				self._fail(download, reason: reason)
				self._drop(download)
			}
		}
	}

	/// Keep a finished file that no transfer in memory is waiting for.
	///
	/// Three things bring a delivery here: a wake-up that outlived its process,
	/// a duplicate delivery for a task its transfer has moved on from, and a
	/// file whose transfer is still running under another id for the same URL.
	/// The bytes are never thrown away — except when the server refused them —
	/// and the pipeline is started from here when the journal names the job, so
	/// the Library is populated while the user is still watching rather than at
	/// the next launch.
	private func _keepOrphan(_ downloadTask: URLSessionDownloadTask, location: URL) {
		// The server never sent a package. A "Not Found" body kept here is the
		// one that fails at unzip with a zip error on the next launch, when the
		// transfer that could have said why was long gone.
		if let status = _serverStatus(for: downloadTask), !(200...299).contains(status) {
			Self.log.error(
				"download: the server answered HTTP \(status, privacy: .public) for a transfer nobody holds — the file is dropped"
			)
			try? FileManager.default.removeItem(at: location)
			return
		}

		// The task's own number in front keeps two wake-ups that were served the
		// same file name from staging into one path and deleting each other's
		// package.
		let name = Self.importablePackageName(
			downloadTask.response?.suggestedFilename ?? UUID().uuidString
		)
		let keep = Self.stagingDirectory.appendingPathComponent("\(downloadTask.taskIdentifier)-\(name)")

		// The same staging decision as the in-memory path: the temp file is
		// here, or a duplicate delivery already landed at `keep`, or the bytes
		// are gone. The last one is logged loudly and nothing more — there is no
		// row to fail, and the journal still names the URL, so the next launch
		// fetches it again.
		do {
			_ = try Self._installFinishedFile(from: location, to: keep)
		} catch {
			Self.log.error("download: finished file could not be staged — \(error.localizedDescription, privacy: .public) (the journal will refetch it)")
			return
		}

		// The transfer's own record when the journal has one for this URL,
		// and the journal's newest record otherwise: either way the import
		// below links the Library entry the way a foreground download does.
		let pending = BSJobJournal.shared.pending
		let journalMatches = pending.map { downloadTask.originalRequest?.url?.absoluteString == $0.url } ?? false

		Self.log.error("download: finished file with no transfer in memory — task \(downloadTask.taskIdentifier) url \(downloadTask.originalRequest?.url?.absoluteString ?? "nil", privacy: .public) registry [\(self._registryDescription, privacy: .public)] journal \(pending?.url ?? "none", privacy: .public) matches \(journalMatches, privacy: .public)")

		// A transfer still running for this URL will deliver its own copy of
		// this file. Importing this one as well would put a second entry in the
		// Library for one app, so the bytes stay in staging and nothing else is
		// begun.
		if let url = downloadTask.originalRequest?.url, registered(url: url) != nil {
			Self.log.notice("download: a finished file for \(url.absoluteString, privacy: .public) arrived while its transfer is still running — kept, not imported")
			return
		}

		guard let pending, journalMatches || downloadTask.originalRequest == nil else { return }

		// The body the server sent has to be what it claims to be before any of
		// it is promised to the user. A 200 with an error page inside is the
		// same refusal as a 404 — it just lies better, and the zip signature is
		// where the lie ends.
		guard Self._hasZipSignature(at: keep) else {
			Self.log.error("download: the finished file is not a zip archive — dropped")
			try? FileManager.default.removeItem(at: keep)
			return
		}
		BSJobJournal.shared.stage(transfer: pending.transferID, package: keep)

		// A job that already has a package on disk is a job something else is
		// working on — the launch-time recovery has it. Starting a second import
		// of the same app would put two entries in the Library, so the bytes are
		// kept and nothing else is begun.
		guard pending.localPackagePath == nil else {
			Self.log.notice("download: finished file for a job that already has a package — left staged, not imported twice")
			return
		}

		let cardName = pending.name ?? Self.displayName(for: URL(string: pending.url) ?? keep)
		let cardID = pending.bundleID ?? pending.transferID

		// The bytes arrived and this path is the one taking them up, so the
		// timeline gets its line here — the same one the in-memory path writes
		// when it delivers, and never a second copy of it.
		DispatchQueue.main.async {
			AutoSignManager.shared.announceDownloadFinished(name: cardName)
		}
		LiveStatus.begin(
			appID: cardID,
			appName: cardName,
			detail: "Preparing the package",
			bundleID: pending.bundleID,
			mode: CompressionMode.stored.label
		)
		LiveStatus.update(
			phase: .unpacking,
			appName: cardName,
			progress: 0,
			detail: "Preparing the package",
			progressKnown: false,
			force: true,
			appID: cardID,
			mode: CompressionMode.stored.label
		)

		// The same call the launch-time recovery makes, for the same reason:
		// everything needed to sign is on disk, and the app is the only thing
		// that can run it.
		FR.handlePackageFile(keep, transferID: pending.transferID) { error in
			if let error {
				Self.log.error("download: orphaned package failed to import — \(error.localizedDescription, privacy: .public)")
				LiveStatus.finish(
					success: false,
					appName: cardName,
					detail: error.localizedDescription,
					appID: cardID
				)
				DispatchQueue.main.async {
					AutoSignManager.shared.announceDownloadFailed(
						name: cardName,
						identifier: cardID,
						message: error.localizedDescription
					)
				}
				return
			}
			// An update, by the same test the importer uses on the transfer's
			// id: the app is already in the Library and is being re-signed
			// rather than installed for the first time.
			let isUpdate = pending.transferID.hasPrefix(BatSignAuto.downloadPrefix)
				|| pending.transferID.hasPrefix(BatSignAuto.manualUpdatePrefix)
			LiveStatus.update(
				phase: isUpdate ? .updating : .signing,
				appName: cardName,
				progress: 0,
				detail: isUpdate ? "Updating" : "Signing and installing",
				progressKnown: false,
				force: true,
				appID: cardID,
				mode: CompressionMode.stored.label
			)
		}
	}

	// MARK: - Refetching what the system took back

	/// How many times a transfer whose finished file was reclaimed is fetched
	/// again before the user is told. The first attempt is the download that
	/// just finished; one refetch is the recovery.
	static let rescueAttempts = 2

	/// Fetch the transfer again, into a file this app owns.
	///
	/// The finished-file callback is the one moment of a download that is not
	/// ours: the bytes sit in a temp file the system owns and may reclaim the
	/// instant the callback returns — and on a device that has just come back
	/// from a suspension or a system update, it does. The answer to that is not
	/// a better sentence about a temp file. It is to stop depending on it: this
	/// asks for the URL again over a session that hands its bytes to this app as
	/// they arrive, so the package is written by us, where nothing can take it
	/// back. The user watches the card keep streaming, and there is nothing to
	/// report unless the refetch fails too.
	@MainActor
	private func _beginRescue(for download: Download, suggestedFileName: String) {
		let attempts = (_rescueAttempts[download.id] ?? 0) + 1
		_rescueAttempts[download.id] = attempts

		guard attempts <= Self.rescueAttempts else {
			_rescueAttempts[download.id] = nil
			Self.log.error("download: \(download.id.prefix(8), privacy: .public) — the finished file was reclaimed and the refetch did not save it either")
			_fail(download, reason: Self.vanishedDownloadMessage)
			_drop(download)
			return
		}

		let destination = Self.stagingDirectory.appendingPathComponent(
			"\(download.id)-\(Self.importablePackageName(suggestedFileName))"
		)

		// A refetch starts from nothing: the fraction the card was showing
		// belonged to bytes that are not on disk any more, and a bar that sits
		// where it was while the file is fetched again is a lie about the wait.
		download.bytesDownloaded = 0
		download.progress = 0
		progressDidMove()

		LiveStatus.update(
			phase: .downloading,
			appName: download.cardName,
			progress: 0,
			detail: "Fetching it again…",
			progressKnown: download.expectedBytes > 0,
			force: true,
			appID: download.liveID,
			mode: CompressionMode.stored.label
		)

		// A refetch that moves no bytes is a silent transfer like any other, and
		// the sweep is the thing that notices those. Its stamp starts now.
		_lastByteAt[download.id] = Date()
		_ensureStallSweep()

		let rescue = _rescue ?? DownloadRescue()
		_rescue = rescue
		rescue.start(
			download: download,
			destination: destination,
			suggestedFileName: suggestedFileName,
			onProgress: { [weak self] received, expected in
				DispatchQueue.main.async {
					self?._noteRescueProgress(download, received: received, expected: expected)
				}
			},
			onFinish: { [weak self] result in
				DispatchQueue.main.async {
					self?._finishRescue(download, result: result)
				}
			}
		)
	}

	/// The refetch's own byte tick: the same numbers, the same card, the same
	/// rate — a download that is running, reported as one.
	@MainActor
	private func _noteRescueProgress(_ download: Download, received: Int64, expected: Int64) {
		if expected > 0 { download.totalBytes = expected }
		let total = download.expectedBytes
		download.progress = total > 0 ? min(Double(received) / Double(total), 1) : 0
		download.bytesDownloaded = received
		download.noteTransfer(bytes: received)
		_noteByteArrival(for: download)
		progressDidMove()

		LiveStatus.update(
			phase: .downloading,
			appName: download.cardName,
			progress: download.transferProgress,
			detail: Self.transferDetail(download),
			progressKnown: total > 0,
			appID: download.liveID,
			mode: CompressionMode.stored.label
		)
	}

	/// The refetch is over: hand the package on, or say what happened.
	///
	/// The tail from here is the tail of every other delivery — the zip
	/// signature, the journal, the import — because a package saved by the
	/// refetch is the same package, and it must not take a second, subtly
	/// different route into the Library.
	@MainActor
	private func _finishRescue(_ download: Download, result: Result<URL, Error>) {
		_rescueAttempts[download.id] = nil
		_disarmStallCheck(for: download)
		_lastByteAt[download.id] = nil

		switch result {
		case .failure(let error):
			// A refetch this app cancelled is work somebody else has already
			// ended: the row's cancel button, the job stopped from the card, the
			// stall sweep taking back a task that was not running. Those paths
			// report themselves, and a second report is a second failure.
			if (error as NSError).code == NSURLErrorCancelled {
				Self.log.notice("download: the refetch of \(download.id.prefix(8), privacy: .public) was cancelled — nothing to report")
				return
			}
			Self.log.error("download: refetching \(download.id.prefix(8), privacy: .public) failed — \(error.localizedDescription, privacy: .public)")
			_fail(download, reason: Self.rescueFailureMessage(error))
			_drop(download)

		case .success(let saved):
			Self.log.notice("download: \(download.id.prefix(8), privacy: .public) — the refetch saved the package as \(saved.lastPathComponent, privacy: .public)")

			guard Self._hasZipSignature(at: saved) else {
				Self.log.error("download: the refetched file is not a zip archive — \(saved.lastPathComponent, privacy: .public)")
				try? FileManager.default.removeItem(at: saved)
				let reason = "The file the server sent is not an app package."
				_fail(download, reason: reason)
				_drop(download)
				return
			}

			BSJobJournal.shared.stage(transfer: download.id, package: saved)
			_noteDelivered(download)

			LiveStatus.update(
				phase: .unpacking,
				appName: download.cardName,
				progress: 0,
				detail: "Preparing the package",
				progressKnown: false,
				force: true,
				appID: download.liveID,
				mode: CompressionMode.stored.label
			)

			do {
				try handlePachageFile(url: saved, dl: download)
			} catch {
				Self.log.error("download: couldn't hand the refetched package over — \(error.localizedDescription, privacy: .public)")
				_fail(download, reason: error.localizedDescription)
				_drop(download)
			}
		}
	}

	/// What the user is told when the refetch could not save the package either.
	///
	/// Only ever said after the app has already tried again on its own, and the
	/// system's reason rides along because that is the part which says whether
	/// the phone was out of space, off the network, or locked down.
	static func rescueFailureMessage(_ error: Error) -> String {
		let system = error.localizedDescription
		guard !system.isEmpty else { return vanishedDownloadMessage }
		return "BatSign fetched the package again and it still could not be saved. \(system)"
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let download = download(for: downloadTask) else { return }

		DispatchQueue.main.async {
			// Bytes are moving, so the transfer is running and the deadline for
			// its first one has nothing left to watch for — and the mid-transfer
			// stall watch is re-armed on every arrival, so the card can only ever
			// hold a fraction that is being earned right now.
			if totalBytesWritten > 0, download.bytesDownloaded == 0 {
				self._disarmStallCheck(for: download)
			}
			self._noteByteArrival(for: download)

			// The server's length when it gave one, the source's declared size
			// when it did not. A total of zero is the only case where the
			// fraction is genuinely unknowable — and that is reported as
			// unknown rather than as zero, because "0%" on a transfer that is
			// moving is the one thing the card must never say.
			if totalBytesExpectedToWrite > 0 {
				download.totalBytes = totalBytesExpectedToWrite
			}
			let total = download.expectedBytes
			download.progress = total > 0
				? min(Double(totalBytesWritten) / Double(total), 1)
				: 0
			download.bytesDownloaded = totalBytesWritten
			// The rate the user reads is measured here, from the bytes themselves.
			download.noteTransfer(bytes: totalBytesWritten)
			self.progressDidMove()

			#if DEBUG
			// The first tick after a revival: the number it starts from is the
			// proof that the transfer carried on from where it stopped instead of
			// beginning again.
			if let from = download.revivedFromBytes {
				download.revivedFromBytes = nil
				Self.log.notice("download: \(download.id.prefix(8), privacy: .public) resumed at \(totalBytesWritten, privacy: .public) bytes after stopping at \(from, privacy: .public)")
			}

			// Drill: the socket is taken away mid-transfer, the way a suspension
			// or a network handover takes it, so the revival path is watched on a
			// real run instead of reasoned about. Set by `-killmidway`.
			if UserDefaults.standard.bool(forKey: "batsign.debug.killMidway"),
			   !download.didKillMidway,
			   download.expectedBytes > 0,
			   Double(totalBytesWritten) / Double(download.expectedBytes) >= 0.35 {
				download.didKillMidway = true
				Self.log.notice("download: drill — taking \(download.id.prefix(8), privacy: .public) away at \(totalBytesWritten, privacy: .public) bytes")
				self._takeBack(download)
			}
			#endif

			// The island is the progress UI. No notification is posted per tick:
			// the live activity replaces itself in place, a notification does not.
			LiveStatus.update(
				phase: .downloading,
				appName: download.cardName,
				progress: download.transferProgress,
				detail: DownloadManager.transferDetail(download),
				queued: max(self.downloads.count - 1, 0),
				progressKnown: total > 0,
				appID: download.liveID,
				mode: CompressionMode.stored.label
			)
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard let error else { return }

		// A cancellation is this app's own doing — the row's cancel button, the
		// stall check taking back the task that was not running, the job being
		// stopped from the card. The user asked for it or the app already
		// reported why, so it is not a second failure to announce: without this,
		// one stalled download is reported twice, the second time as "cancelled".
		if (error as NSError).code == NSURLErrorCancelled {
			Self.log.notice("download: a task was cancelled — nothing to report")
			return
		}

		// A failure with nobody to own it is still a failure. Dropping it here is
		// how "the download failed" became "nothing happened": the card kept
		// saying what it last said and the journal kept pointing at work that was
		// no longer running. The journal entry is what names the transfer after a
		// relaunch, so it is read here to give the error somewhere to land.
		guard let download = download(for: task) else {
			// Only a URL match may clear the record: a resume-data task reports
			// a nil original request, and treating that as "matches whatever is
			// in the journal" used to delete the staged package of a transfer
			// whose bytes had already arrived. A record that cannot be matched
			// is left for the next launch's recovery, which is the safe answer —
			// it re-fetches or adopts, and it is bounded by the attempts cap.
			guard let pending = BSJobJournal.shared.pending,
			      let url = task.originalRequest?.url,
			      pending.url == url.absoluteString
			else { return }

			let name = pending.name ?? "Download"
			Self.log.error("download: \(name, privacy: .public) failed with no transfer in memory — \(error.localizedDescription, privacy: .public)")
			BSJobJournal.shared.clearIf(transferID: pending.transferID)
			LiveStatus.finish(
				success: false,
				appName: name,
				detail: error.localizedDescription,
				appID: pending.bundleID ?? pending.transferID
			)
			// The app may not be on screen at all: this is the path a transfer
			// killed in the background takes, and there is no card to watch then.
			DispatchQueue.main.async {
				AutoSignManager.shared.announceDownloadFailed(
					name: name,
					identifier: pending.bundleID ?? pending.transferID,
					message: error.localizedDescription
				)
			}
			return
		}

		// A task the transfer has already replaced is not the transfer failing:
		// the stall check cancels the one that was not running and the same URL
		// is already being asked for again in the session that can run it. Its
		// cancel arrives here like any other error, and reporting it would say
		// "download failed" over a transfer that is still going.
		if let live = download.task, (task as? URLSessionDownloadTask) !== live {
			Self.log.notice("download: ignoring a callback from a task \(download.id.prefix(8), privacy: .public) has moved on from")
			return
		}

		// The bytes already arrived; the error belongs to the response, not the
		// transfer. `didFinishDownloadingTo` owns the file from here.
		if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
			download.resumeData = data
		}

		DispatchQueue.main.async {
			// Nothing arrived and it failed. That is not a server's answer — the
			// transfer never got far enough to have one — so the request is made
			// once more through the background session, whose daemon owns its own
			// socket and keeps it open even if this process is suspended a moment
			// later. If that fails too, the stall check ends it and says so.
			if download.bytesDownloaded == 0, !download.didRetryInBackground {
				download.didRetryInBackground = true
				let retry = self.backgroundSession.downloadTask(with: download.url)
				download.task = retry
				retry.resume()
				LiveStatus.update(
					phase: .downloading,
					appName: download.cardName,
					progress: 0,
					detail: "Starting…",
					progressKnown: download.expectedBytes > 0,
					force: true,
					appID: download.liveID,
					mode: CompressionMode.stored.label
				)
				// The retry gets the same deadline: a second task that also
				// moves nothing is the failure, and it must not wait for ever
				// to be called one.
				self._armStallCheck(for: download)
				return
			}

			// The bytes already arrived and the socket carrying them did not
			// survive — a suspension, a handover between networks, a mirror that
			// dropped the connection. The transfer is not over: the system kept
			// the range it had reached, and the request is made again from there.
			// Failing at this point is what "it stops at a random percentage"
			// was, on a phone whose screen locks in the middle of a download
			// every day.
			if download.bytesDownloaded > 0, Self._isRecoverable(error) {
				Self.log.error("download: \(download.id.prefix(8), privacy: .public) lost its connection at \(download.bytesDownloaded, privacy: .public) bytes — \(error.localizedDescription, privacy: .public); picking it up again")
				self._revive(download, after: 1.5)
				return
			}

			// The transfer is over and nothing arrived. Out of the list, and said
			// out loud: the popup in the app, the notification outside it, and
			// the activity log, all with the reason the system gave.
			self._removeProgressNotification(for: download)
			self._fail(download, reason: error.localizedDescription)
			self._drop(download)
		}
	}

	/// Whether the error is the network giving up rather than the server or the
	/// file refusing. Those are the ones worth asking again for, and they are
	/// the ones a download on a phone meets every day.
	private static func _isRecoverable(_ error: Error) -> Bool {
		let ns = error as NSError
		guard ns.domain == NSURLErrorDomain else { return false }
		switch ns.code {
		case NSURLErrorTimedOut,
			NSURLErrorCannotFindHost,
			NSURLErrorCannotConnectToHost,
			NSURLErrorNetworkConnectionLost,
			NSURLErrorDNSLookupFailed,
			NSURLErrorNotConnectedToInternet,
			NSURLErrorInternationalRoamingOff,
			NSURLErrorCallIsActive,
			NSURLErrorDataNotAllowed,
			NSURLErrorSecureConnectionFailed,
			NSURLErrorBadServerResponse:
			return true
		default:
			return false
		}
	}

	/// "12.4 MB of 48.1 MB · 3.2 MB/s", or the size alone while the rate is not
	/// yet known.
	///
	/// The rate rides along with the bytes because the two answer the same
	/// question — how much longer — and the card has room for one line.
	///
	/// A transfer with no total at all still has a rate and a byte count, and
	/// both are real. It used to print "Connecting…" for the whole download —
	/// minutes of it, on a transfer that was plainly moving — because the total
	/// the sentence was built around did not exist.
	static func transferDetail(_ download: Download) -> String {
		guard download.expectedBytes > 0 else {
			guard download.bytesDownloaded > 0 else { return "Connecting…" }
			let done = Download.byteFormatter.string(fromByteCount: download.bytesDownloaded)
			var detail = "\(done) downloaded"
			if let speed = download.formattedSpeed {
				detail += " · \(speed)"
			}
			return detail
		}
		let done = Download.byteFormatter.string(fromByteCount: download.bytesDownloaded)
		let total = Download.byteFormatter.string(fromByteCount: download.expectedBytes)
		var detail = "\(done) of \(total)"
		if let speed = download.formattedSpeed {
			detail += " · \(speed)"
		}
		return detail
	}
}
