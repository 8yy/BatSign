//
//  BSContinuedProcessing.swift
//  Feather
//
//  The system's own answer to "keep working while I use another app".
//
//  The silent audio hold keeps this process scheduled, and it is what carries a
//  signing job and the install hand-off. What it is not is *permission*: it is a
//  background mode being used for something other than what it is for, and the
//  system is entitled to take it away — and does, more with every release. On
//  iOS 26 there is a mechanism meant for exactly this case: `BGContinuedProcessingTask`.
//
//  It is a request to the scheduler that a *user-initiated* piece of work be
//  allowed to run to its end even though the app is no longer frontmost, and it
//  comes with the presentation the user expects: the system draws its own live
//  card — title, subtitle, progress — in the Dynamic Island and on the Lock
//  Screen while the grant is held. Nothing here draws that card; the text below
//  is all this app contributes to it.
//
//  Four rules shape the code, and the first two exist because breaking them puts
//  a failure on the user's Lock Screen that this app cannot clear:
//
//  * The grant is completed successfully, always. `setTaskCompleted(success:)`
//    is not a place to report whether the *job* worked — the scheduler granted
//    background time, the app used it, and the grant did exactly what it
//    promised. Handing it back as a failure makes iOS draw its own failure
//    presentation over this app's work ("task failed" on the island and the Lock
//    Screen), for a job the app has already reported honestly on its own card.
//    That surface is the system's, not this app's: nothing in this codebase can
//    repaint it, dismiss it, or shorten its life. So it is never asked for. A
//    transfer that really did fail says so on the app's own card, in the
//    activity log, and in a notification — which is where the user can act on it.
//
//  * A task is always completed, exactly once, by whoever holds it — and the
//    answer is never made to wait for the main actor. Both halves of that are
//    load-bearing. A task that is merely dropped — the handle nil'd in an
//    expiration handler, a `finish` that finds no task in hand, a process that
//    goes away holding one — is reaped by the system on its own terms, and a
//    reaped task is reported to the user as a failure ("Task failed", on a
//    notification this app cannot take down). So the task is adopted on the
//    scheduler's own queue, its expiration handler is installed there, and the
//    completion goes through a once-only latch that any thread can fire. None of
//    it hops to the main actor first: the main actor is signing an app at
//    exactly the moment a grant arrives or is taken back, and a completion that
//    is waiting behind that is a completion the system has already given up on.
//
//  * One grant for the whole job, not one per phase. Each continued-processing
//    task gets its own system card, so a grant per phase would put a second,
//    stale card beside the one the app already draws. The grant's lifetime is
//    therefore the keep-alive's: taken when the first hold is taken, released
//    when the last one goes, whatever phases happen in between.
//
//  * Say what is actually true. Progress is the transfer's real fraction when
//    there is a transfer, and the title and subtitle follow the phase — the same
//    strings the app's own card shows, from the same call sites in `LiveStatus`.
//    A grant that reports a stalled percentage is one the scheduler is entitled
//    to expire, and rightly.
//
//  If iOS refuses the grant — this simulator, a build the scheduler will not
//  take requests from, a device with the feature off — nothing else changes: the
//  holds go on holding, and the job runs exactly as it did before this file
//  existed. Only the background presentation is missing.
//

import Foundation
import BackgroundTasks
import OSLog

@MainActor
final class BSContinuedProcessing {
	static let shared = BSContinuedProcessing()

	private static let log = Logger(subsystem: "app.batsign.ios", category: "continued")

	/// Whether the system can be asked at all — and whether it should be.
	///
	/// Deliberately false, always. The grant exists to give the app the system's
	/// own background card, and that card is a second island beside the app's:
	/// the user saw both at once — BatSign's card saying "Finishing… 100%" and
	/// the system's card, with the app's full icon, saying "Task failed". The
	/// failure half is the deal-breaker: when the grant is reaped, the system
	/// draws that failure on a surface this app cannot clear, shorten or
	/// repaint. The product decision is therefore one card — the app's own —
	/// and no grant is ever requested. The keep-alive holds are what keep the
	/// process scheduled, and they are untouched: only the system's duplicate
	/// presentation is gone.
	///
	/// A pending request left by an older build is still cancelled at launch
	/// by `releaseLeftover`, which does not consult this switch — a request
	/// the scheduler starts would draw exactly the card this switch exists to
	/// prevent.
	private var isAvailable: Bool {
		false
	}

	/// The grant in hand, once the scheduler has handed one over.
	///
	/// Held because progress and the displayed text are set on the task inside
	/// it: there is no other handle on the grant. Until it arrives, what the card
	/// should say is kept in `desired` and applied on arrival — the request is
	/// submitted before the job it covers has done anything, so the first
	/// seconds of a download are exactly when it is most likely to be missing.
	///
	/// Cleared by `releaseGrant` and by a grant that the system takes back, so
	/// "in hand" and "already handed back" cannot disagree here. The latch inside
	/// is what makes that true even when both endings arrive at once.
	private var grant: Grant?

	/// Whether a request is with the scheduler and has not been started yet.
	///
	/// The keep-alive reaffirms its holds, which asks for the grant again; without
	/// this, each of those would be a second request for the same identifier,
	/// which the scheduler refuses as a duplicate — a refusal that would be logged
	/// and back off for no reason at all.
	private var isPending = false

	/// The system's task in a box that any thread can hand back, exactly once.
	///
	/// The box exists because of *when* the system asks for the task back. An
	/// expiration handler runs on the scheduler's own queue, and what it has to
	/// do — complete the task — has to happen then, on that queue: a task the
	/// system has expired and not been told about is a task it reports as failed.
	/// Routing that completion through the main actor, as this class used to, put
	/// it behind whatever the app was doing at the time, and what this app is
	/// doing at the time is signing an app. So the completion is thread-safe and
	/// the main actor is left with only the presentation.
	///
	/// It holds the task as `BGTask` rather than as a continued-processing task:
	/// the base class is where `setTaskCompleted` lives, and a type this class
	/// only needs on iOS 26 has no business in a property's signature on a
	/// target that goes further back.
	private final class Grant: @unchecked Sendable {
		private let lock = NSLock()
		private var task: BGTask?

		init(_ task: BGTask) {
			self.task = task
		}

		/// The task, while it is still in hand. Nil once it has gone back, which
		/// is what stops a title or a progress update reaching a spent task.
		var handle: BGTask? {
			lock.lock()
			defer { lock.unlock() }
			return task
		}

		/// Hand the task back. The first caller does it, and only the first:
		/// completing a task twice is a crash, and completing it never is the
		/// failure presentation on the user's Lock Screen.
		@discardableResult
		func complete() -> Bool {
			lock.lock()
			let held = task
			task = nil
			lock.unlock()

			guard let held else { return false }
			held.setTaskCompleted(success: true)
			return true
		}
	}

	/// The latest state to show, whether or not the system has started the task.
	private var desired = Desired()

	private struct Desired {
		var title: String = "BatSign"
		var subtitle: String = "Working"
		/// Nil while the phase has no fraction of its own.
		var progress: Double?
		/// Whether the app is still holding the process up for this job. The
		/// grant exists only while this is true.
		var isHolding: Bool = false
	}

	private init() {}

	// MARK: - The grant

	/// Ask to keep running, and keep the system's card pointed at the job.
	///
	/// Idempotent: the keep-alive calls it for the first hold and on every
	/// reaffirm, so a grant is never doubled up on and never ends under a job
	/// that is still going.
	func begin(title: String? = nil, subtitle: String? = nil) {
		desired.isHolding = true
		if let title { desired.title = title }
		if let subtitle { desired.subtitle = subtitle }

		guard isAvailable else { return }
		guard #available(iOS 26.0, *) else { return }

		// Already granted and running, or already asked for: only the text needs
		// to change, and only if the system has started it.
		if grant != nil || isPending {
			if let grant { _apply(to: grant) }
			return
		}
		_submit()
	}

	/// The phase changed, or the transfer moved. Everything the system card shows
	/// comes through here.
	///
	/// Recorded whether or not a grant is live: the phases of a job begin before
	/// its first hold is taken, and the title the card opens with is the one the
	/// last phase set.
	func publish(phase: String, title: String? = nil, progress: Double? = nil) {
		if let title { desired.title = title }
		desired.subtitle = phase
		desired.progress = progress

		guard #available(iOS 26.0, *), let grant else { return }
		_apply(to: grant)
	}

	/// The job is over, however it ended. The grant goes back — successfully —
	/// and the system's card goes with it.
	///
	/// There is deliberately no outcome parameter. See the second rule at the top
	/// of this file: a job that failed is still a grant that was used as asked,
	/// and reporting it as a failure is what puts a system-owned failure card on
	/// the Lock Screen for work the app has already finished with.
	func finish() {
		desired.isHolding = false
		desired.progress = nil

		guard #available(iOS 26.0, *) else { return }
		releaseGrant()

		// A request that was never started is not a card, but leaving it queued
		// would let the scheduler start a grant for work that is already over —
		// which is a card with nothing behind it. Cancelling is also a no-op when
		// the grant that just went back was the one that had been started.
		isPending = false
		BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.grantIdentifier)
	}

	// MARK: - State that outlives this class's own fields

	private var isRegistered = false
	/// The identifier is refused for good: it is not in the permitted list, or
	/// this host does not offer continued processing at all. Nothing else depends
	/// on the grant, so this is recorded once and never asked about again.
	private var isUnavailable = false
	/// When the scheduler last refused, and how long to wait before asking again.
	/// The wait doubles per refusal so a host that will never accept the request
	/// stops being asked on every phase change, while a device that becomes
	/// eligible again is still picked up.
	private var lastRefusal: Date?
	private var refusalBackoff: TimeInterval = 30
	private static let refusalCeiling: TimeInterval = 3600

	/// One identifier for the app's job, in the notation the header asks for: the
	/// bundle id, a context, and a token that names the work.
	///
	/// A single token, because there is a single grant — the identifier is what
	/// the system keys the card on, and two of them would be two cards. It is
	/// stable across launches so a job picked up in a new process reuses the same
	/// grant rather than queueing a second one behind it.
	private static var grantIdentifier: String {
		let bundle = Bundle.main.bundleIdentifier ?? "app.batsign.ios"
		return "\(bundle).userTask.job"
	}

	// MARK: - The scheduler

	@available(iOS 26.0, *)
	private func _submit() {
		let identifier = Self.grantIdentifier

		// Registering the same identifier twice is an error the system kills the
		// app for, and the handler stays registered for the life of the process,
		// so this happens exactly once.
		if !isRegistered {
			let registered = BGTaskScheduler.shared.register(
				forTaskWithIdentifier: identifier,
				using: nil
			) { [weak self] task in
				// Adopted here, on the scheduler's own queue, before anything is
				// hopped to the main actor. Two things have to exist from the
				// first moment the task does — a way to hand it back that works
				// from any thread, and an expiration handler that uses it — and
				// waiting for the main actor to provide them is how a task ends
				// up expired with nobody having answered: reported to the user as
				// a failure, on a surface this app cannot clear.
				guard let granted = task as? BGContinuedProcessingTask else {
					task.setTaskCompleted(success: true)
					return
				}

				let grant = Grant(granted)
				granted.expirationHandler = { [weak self] in
					// Handed back on this queue, synchronously: the system has
					// given the app its moment to let go, and this is that moment
					// rather than whenever the main actor next comes free.
					let handedBack = grant.complete()
					Task { @MainActor in
						self?.grantWasTakenBack(grant, handedBack: handedBack)
					}
				}

				Task { @MainActor in self?.adopt(grant) }
			}
			isRegistered = true
			if !registered {
				// The identifier is not covered by BGTaskSchedulerPermittedIdentifiers.
				// Nothing else depends on the grant, so this is reported and the
				// job carries on under the holds.
				Self.log.error("continued: the identifier \(identifier, privacy: .public) is not permitted — grant unavailable")
				isUnavailable = true
				return
			}
			Self.log.notice("continued: handler registered for \(identifier, privacy: .public)")
		}

		guard !isUnavailable else { return }

		// A refusal that is not going to change — this simulator, a build the
		// scheduler will not take requests from, a device with the feature off —
		// is not worth an error in the log every time the app changes state. The
		// retries that matter are the ones after a grant was *held*, and those
		// come with no recent refusal behind them.
		if let lastRefusal, Date().timeIntervalSince(lastRefusal) < refusalBackoff {
			return
		}

		let request = BGContinuedProcessingTaskRequest(
			identifier: identifier,
			title: desired.title,
			subtitle: desired.subtitle
		)
		// The default, said out loud: a job the user asked for and is watching is
		// not to be started "when convenient".
		request.strategy = .queue

		do {
			try BGTaskScheduler.shared.submit(request)
			isPending = true
			lastRefusal = nil
			refusalBackoff = 30
			Self.log.notice("continued: grant requested for “\(self.desired.title, privacy: .public)”")
		} catch {
			// Refused: too many pending requests, or continued processing is not
			// available to this app on this device. Not a failure of the job —
			// only of its background presentation.
			lastRefusal = Date()
			refusalBackoff = min(refusalBackoff * 2, Self.refusalCeiling)
			Self.log.error("continued: grant refused — \(error.localizedDescription, privacy: .public)")
		}
	}

	/// The scheduler started the task: this is the object the system card is
	/// driven by. The task itself was already adopted on the scheduler's queue —
	/// this only takes note of it for the presentation.
	@available(iOS 26.0, *)
	private func adopt(_ grant: Grant) {
		// Work is over by the time this runs and nothing is holding: hand the
		// grant straight back rather than leaving a card up for finished work.
		guard desired.isHolding else {
			if grant.complete() {
				Self.log.notice("continued: grant started after the job ended — handed straight back")
			}
			return
		}

		// The system can take a grant back before this runs — it is entitled to,
		// and the expiration handler has already handed that task over by the
		// time it does. A spent grant is not adopted here: it would sit in
		// `grant` looking held, and every later ask for one would be skipped on
		// the strength of it for the rest of the job.
		guard grant.handle != nil else { return }

		isPending = false
		self.grant = grant
		Self.log.notice("continued: grant active for “\(self.desired.title, privacy: .public)”")
		_apply(to: grant)
	}

	/// The system took the grant back. Not a failure and not the end of the job:
	/// the holds are still in place and the journal still describes the work, so
	/// the transfer and the signing carry on and are picked up from disk if the
	/// process does not survive.
	///
	/// The task was completed in the expiration handler, on the queue that
	/// handler ran on, before this ran at all — that is the part the system
	/// judges. What is left here is bookkeeping, and asking for the grant again
	/// while there is still work, so the job keeps its presentation and the user
	/// watches it move from one grant to the next instead of watching it fail.
	@available(iOS 26.0, *)
	private func grantWasTakenBack(_ grant: Grant, handedBack: Bool) {
		isPending = false
		if let held = self.grant, held === grant {
			self.grant = nil
		}

		guard handedBack else { return }
		Self.log.notice("continued: the system took the grant back — the holds carry the job from here")

		guard desired.isHolding else { return }
		lastRefusal = nil
		refusalBackoff = 30
		_submit()
	}

	/// Hand the grant back and forget it, if there is one in hand.
	@available(iOS 26.0, *)
	private func releaseGrant() {
		guard let held = grant else { return }
		grant = nil
		if held.complete() {
			Self.log.notice("continued: grant released")
		}
	}

	@available(iOS 26.0, *)
	private func _apply(to grant: Grant) {
		// A grant that has already gone back has no task to paint, and no card
		// left to paint it on.
		guard let task = grant.handle as? BGContinuedProcessingTask else { return }

		task.updateTitle(desired.title, subtitle: desired.subtitle)

		guard let progress = desired.progress else { return }
		task.progress.totalUnitCount = 100
		task.progress.completedUnitCount = Int64((min(max(progress, 0), 1) * 100).rounded())
	}

	// MARK: - What a launch finds

	/// Called once, at launch, before any job starts.
	///
	/// A request submitted by a previous process is still on the scheduler's
	/// queue — pending requests outlive the process that asked for them — and if
	/// the scheduler starts it, the system draws a card for work that ended when
	/// that process did. There is no task object to complete here, so the request
	/// itself is cancelled: nothing is orphaned, and no card is drawn for a job
	/// that is not running.
	func releaseLeftover() {
		// Runs regardless of `isAvailable`: a request queued by an older build
		// is still on the scheduler, and if it is started it draws the system's
		// own card — the "Task failed" surface this app cannot clear. There is
		// no task object to complete here, so the request itself is cancelled:
		// nothing is orphaned, and no card is drawn for work that is not
		// running.
		guard #available(iOS 26.0, *) else { return }
		// A grant in hand belongs to this process and is completed, not dropped:
		// dropping it is the reap that reports a failure. At launch there is none —
		// this is here so the call is correct wherever it is made from.
		releaseGrant()
		isPending = false
		BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.grantIdentifier)
	}
}
