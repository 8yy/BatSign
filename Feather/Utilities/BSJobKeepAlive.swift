//
//  BSJobKeepAlive.swift
//  Feather
//
//  Keeps the app running while it still has work to do.
//
//  A signing job is not a download. Downloading is URLSession's business and
//  survives being suspended; signing is minutes of CPU work inside this
//  process, and the install hand-off is a local server that has to answer
//  installd *after* the user has left the app. Suspended in the middle of
//  either and the job simply stops — which is what "I left the app and it
//  never finished installing" is.
//
//  Three holds, deliberately:
//
//  * The audio session is the real one. With the `audio` background mode
//    declared, a playing session keeps the process scheduled for as long as
//    the work lasts, which is the only thing on iOS that reliably outlives the
//    30-second grace period.
//  * A background-task assertion sits underneath it, covering the moment
//    before the player is up and the moment after it is torn down — the two
//    windows where the process would otherwise be suspendable.
//  * A processing request is left with the system so that if this process is
//    taken away anyway — memory pressure at the wrong moment, a crash, the
//    user swiping the app away — what is left of the job is picked up rather
//    than lost. That is the only hold that matters after a kill, and it is the
//    one the Background App Refresh switch in Settings governs.
//
//  Holds are ref-counted by reason, so the download that just finished cannot
//  drop the hold the signing job has already taken over.
//
//  And the holds are checked. The version of this file that did not work took
//  the audio hold and *believed* it: a phone call, another app taking the
//  output or a route change stopped the session, the flag went on saying it was
//  up, and the job was suspended on the first lock with nothing in the log to
//  say why. There is now a watchdog on the main actor that re-asks, every few
//  seconds, whether the process is actually held, and puts back whatever is
//  not. Holding is a fact to be checked, not a state to be remembered.
//

import UIKit
import OSLog

@MainActor
final class BSJobKeepAlive {
	static let shared = BSJobKeepAlive()

	private static let log = Logger(subsystem: "app.batsign.ios", category: "keepalive")

	/// Who is holding the app up. A `Set` of reasons rather than a counter, so
	/// the same reason taken twice is still one hold and cannot be released
	/// once too often.
	private var holders: Set<String> = []

	private var assertion: UIBackgroundTaskIdentifier = .invalid
	private var isAudioRunning = false
	private var watchdog: Task<Void, Never>?
	/// How many verification passes have run, for the once-a-minute report.
	private var verifyTick = 0

	/// How often the holds are verified while work is running.
	///
	/// Short enough that a session lost to a phone call is back before the job
	/// notices, long enough to cost nothing: it is one check on the main actor
	/// and, when everything is already held, no work at all.
	private let watchdogInterval: TimeInterval = 5

	/// How many times the assertion may be re-armed in a row.
	///
	/// The assertion is the fallback, not the mechanism — the audio session is
	/// what actually keeps the process scheduled — but "fallback" cannot mean
	/// "gives up after a minute". A signing job runs for minutes and the install
	/// hand-off after it waits on a system fetch of a whole package; expiring in
	/// the middle of either is precisely the interruption this class exists to
	/// prevent. So the budget is only there to stop an endless loop when nothing
	/// is holding any more, and it is reset every time a hold is taken.
	private var rearmBudget = 240

	/// Names for the phases that hold the app up. Kept here so a typo cannot
	/// leave a hold behind that nothing ever releases.
	enum Reason {
		static let download = "download"
		static let job = "job"
		/// The install server, which keeps answering after the queue drains.
		static let installer = "installer"
		/// Following that hand-off to its end.
		///
		/// A separate reason from `installer` on purpose, even though the two are
		/// held over roughly the same window. Holds are a set, so two callers
		/// naming themselves the same thing are one hold — and the first of them to
		/// let go would drop it while the other still needed it. The server and the
		/// watcher have genuinely different lifetimes, so they say so.
		static let landing = "install-landing"
		static let manualInstall = "manual-install"
		/// The moment a result is shown before the live card is taken down.
		///
		/// The take-down is a task, and a task cannot run in a suspended process.
		/// The install lands while the user is on the Home Screen — that is what
		/// the hand-off is for — so without a hold over the hold, the island would
		/// be left showing "Installed" by an app that was suspended before it
		/// could take it away. Named separately from the others because it is the
		/// last thing to let go, not part of the job.
		static let finale = "finale"
	}

	private init() {}

	var isHolding: Bool { !holders.isEmpty }

	/// Whether the silent session is actually up right now. For diagnostics.
	var isHeldBySystem: Bool {
		#if targetEnvironment(macCatalyst)
		return isAudioRunning
		#else
		return isAudioRunning && BackgroundAudioManager.shared.isRunning
		#endif
	}

	/// Hold the app up. Safe to call repeatedly with the same reason.
	func begin(_ reason: String) {
		let wasEmpty = holders.isEmpty
		holders.insert(reason)
		guard wasEmpty else {
			Self.log.debug("keepalive: +\(reason, privacy: .public) (already held)")
			return
		}
		Self.log.notice("keepalive: hold taken by \(reason, privacy: .public)")
		_start()
	}

	/// Release one hold. The app is let go only when the last one goes.
	func end(_ reason: String) {
		holders.remove(reason)
		guard holders.isEmpty else {
			Self.log.debug("keepalive: -\(reason, privacy: .public) (\(self.holders.count) still holding)")
			return
		}
		Self.log.notice("keepalive: last hold released by \(reason, privacy: .public)")
		_stop()
	}

	/// Belt and braces for a hard teardown: a job that was killed mid-flight
	/// must not leave the audio session running for the rest of the process.
	func endAll() {
		holders.removeAll()
		_stop()
	}

	// MARK: - Internals

	private func _start() {
		rearmBudget = 240
		_beginAssertion()
		_startAudio()
		// The same request made in the system's own vocabulary: on iOS 26 this is
		// what asks for the job to be allowed to finish while the user is
		// elsewhere, and it is what draws the card the system shows for it. Taken
		// once for the whole job — the lifetime here is the lifetime of the work,
		// whatever phases happen inside it.
		BSContinuedProcessing.shared.begin()
		// Left with the system as well, so a process that is taken away in
		// spite of both holds has its work picked up rather than lost.
		BSBackgroundTasks.shared.scheduleJobContinuation()
		_startWatchdog()
	}

	/// Re-take both holds without disturbing the holders.
	///
	/// Called when the app comes back to the foreground and on the way out to
	/// the background: an audio session can be deactivated by a phone call,
	/// another app taking the output, or a route change, and a player that has
	/// been stopped does not restart itself. The holders have not changed — the
	/// job is still running — so the holds are simply re-asserted underneath
	/// them.
	func reaffirm() {
		guard isHolding else { return }
		rearmBudget = 240
		_beginAssertion()
		#if !targetEnvironment(macCatalyst)
		if !BackgroundAudioManager.shared.isRunning {
			Self.log.notice("keepalive: reaffirm found the silent hold down — putting it back")
			isAudioRunning = false
			_startAudio()
		}
		#endif
		// The grant can be taken back mid-job — the system is entitled to it, and
		// says so through the expiration handler rather than by refusing to run.
		// Asking again here is the only moment it can be: the app is up, the work
		// is outstanding, and the ask is idempotent when the grant is still held.
		BSContinuedProcessing.shared.begin()
		_startWatchdog()
	}

	private func _stop() {
		watchdog?.cancel()
		watchdog = nil
		_stopAudio()
		_endAssertion()
		// The work is over, so the grant goes back and the system's card goes with
		// it. The outcome is not carried: the grant is completed the same way
		// whether the job worked or not — see BSContinuedProcessing.
		BSContinuedProcessing.shared.finish()
		BSBackgroundTasks.shared.cancelJobContinuation()
	}

	/// The job failed.
	///
	/// The grant is released here exactly as it is on the ordinary ending, and
	/// deliberately so. The failure is the *job's*, and it is reported on the
	/// app's own card, in the activity log and in a notification. Handing the
	/// grant back as a failure told the system to draw its own failure
	/// presentation over that — a card this app can neither repaint nor take
	/// down, which is the "task failed" the island was left showing long after
	/// the app had already said what went wrong.
	func failed() {
		BSContinuedProcessing.shared.finish()
	}

	private func _startAudio() {
		guard !isAudioRunning else { return }
		isAudioRunning = true
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.start()
		#endif
	}

	private func _stopAudio() {
		guard isAudioRunning else { return }
		isAudioRunning = false
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop()
		#endif
	}

	// MARK: - The watchdog

	/// Re-asks whether the process is actually held, and fixes it if it is not.
	///
	/// This is the difference between a hold and a hope. Everything that can
	/// stop the silent session — a call, a route change, another app claiming
	/// the output, a media-services reset, the system deciding to be difficult —
	/// happens without telling us, and the job it was holding simply stops at
	/// the next moment the process is suspended. Checking is cheap; discovering
	/// it from a stalled install is not.
	private func _startWatchdog() {
		guard watchdog == nil else { return }
		watchdog = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: UInt64((self?.watchdogInterval ?? 5) * 1_000_000_000))
				guard !Task.isCancelled, let self, self.isHolding else { return }
				self._verify()
			}
		}
	}

	private func _verify() {
		verifyTick &+= 1
		#if !targetEnvironment(macCatalyst)
		if !BackgroundAudioManager.shared.isRunning {
			Self.log.error("keepalive: silent hold was down — restarting it")
			isAudioRunning = false
			_startAudio()
			// Whatever stopped the player usually took the audio session with
			// it, so it is reactivated here rather than waiting for the
			// assertion to expire and ask.
			BackgroundAudioManager.shared.restart()
		}
		#endif
		if assertion == .invalid {
			Self.log.error("keepalive: background assertion was gone — re-taking it")
			_beginAssertion()
		}
		// Every twelfth tick — once a minute — the state is said out loud rather
		// than at debug level, so a job that is being held can be seen to be held
		// in a device's console instead of only when something goes wrong.
		if verifyTick % 12 == 0 {
			Self.log.notice("keepalive: holding \(self.holders.count, privacy: .public) reason(s), silent hold up")
		} else {
			Self.log.debug("keepalive: holding \(self.holders.count, privacy: .public) reason(s), silent hold up")
		}
	}

	private func _beginAssertion() {
		guard assertion == .invalid else { return }
		assertion = UIApplication.shared.beginBackgroundTask(withName: "app.batsign.job") { [weak self] in
			Task { @MainActor in self?._rearm() }
		}
	}

	private func _rearm() {
		guard isHolding, rearmBudget > 0 else { return }
		rearmBudget -= 1
		_endAssertion()
		_beginAssertion()
		// The assertion expiring usually means the audio session went with it:
		// a call, another app taking the output, a route change. Both are put
		// back, because the job that needed them is still running.
		#if !targetEnvironment(macCatalyst)
		if !BackgroundAudioManager.shared.isRunning {
			Self.log.notice("keepalive: assertion expired, silent hold down — both being re-taken")
			isAudioRunning = false
			_startAudio()
		}
		#endif
	}

	private func _endAssertion() {
		guard assertion != .invalid else { return }
		UIApplication.shared.endBackgroundTask(assertion)
		assertion = .invalid
	}
}
