//
//  LiveActivityController.swift
//  Feather
//
//  One place owns the live download status shown in the Dynamic Island and on
//  the Lock Screen.
//
//  The rules it holds itself to, because a live activity that misbehaves is
//  worse than none at all:
//
//  * One activity, ever. A second transfer updates the first rather than
//    stacking a second card into the island.
//
//  * Every phase reaches the same card. The job is handed down the pipeline
//    under two identities — the transfer is keyed by the store's own composite
//    id and the install half knows only the bundle id — and a card that ignores
//    one of its own names is a card that never updates and never goes away,
//    which is precisely how an install used to sit in the island saying
//    "Signing" for the whole install.
//
//  * One push in flight at a time, and the newest state always wins. Progress
//    arrives in bursts and ActivityKit is not instantaneous; firing a push per
//    tick and hoping they land in order is what makes an island show 40% while
//    the app is at 90%. Here a burst collapses into the single latest state,
//    which is pushed the moment the previous push returns, so the card is never
//    behind by more than one frame.
//
//  * The card moves while the work does. A live activity cannot loop an
//    animation, so the wave that travels round the island's edge is carried in
//    the state and re-sent as the app has news — once a second while bytes are
//    moving, and on a slow beat while the phase is silent, so a signing stretch
//    drifts rather than standing still. It stops when the work stops, which is
//    the only honest behaviour for a highlight that means "still going".
//
//  * Nothing sits in the island pretending to be live. Every state is stamped
//    with a stale date a minute out, so a card whose app died stops claiming to
//    be moving; anything left over from a previous run is ended on launch *and*
//    on every return to the foreground.
//
//  * The card goes when the work does. A result is held for as long as it takes
//    to read and no longer, and the hold is enforced by a task that is
//    deliberately short — an island left at 100% is the one thing this feature
//    must never do.
//
//  * Every ActivityKit call is asynchronous, so the controller never blocks a
//    transfer, and every call is guarded by the system's own authorisation.
//

import Foundation
import ActivityKit
import OSLog
import UIKit

@available(iOS 16.2, *)
@MainActor
final class LiveActivityController {
	static let shared = LiveActivityController()

	private var activity: Activity<DownloadActivityAttributes>?
	private var lastState: DownloadActivityAttributes.ContentState?

	/// The newest state waiting for the wire, and whether a push is already in
	/// flight. Together these are the coalescing pump: `pending` is overwritten
	/// rather than queued, so a backlog of progress ticks costs one push, not
	/// twenty.
	private var pending: DownloadActivityAttributes.ContentState?
	/// Whether the state waiting for the wire was asked to go out now.
	///
	/// Carried beside the state rather than recomputed at the pump, because the
	/// reason to hurry is the caller's and not the state's: a phase change is
	/// urgent by inspection, and a re-assertion of the phase already up — the
	/// install picking a job back up, a card revived on the way forward — is just
	/// as urgent and looks identical to a progress tick from here.
	private var pendingIsUrgent = false
	/// Whether the next push is the first reading a card has ever carried.
	///
	/// A card opens on the state it was requested with — the name, the mode, and
	/// no fraction, because nothing has been measured yet. The reading that
	/// follows, one byte-count later, is the first true number the card has, and
	/// it is not a burst: holding it behind the rate gap showed 0% for up to a
	/// second on a card whose job was already at 66%, which is the visible lag
	/// this flag removes. One extra push, at the moment the card appears.
	private var firstContentIsFree = false
	private var isPushing = false

	/// Bumped whenever the card is replaced or taken down. A drain that started
	/// against an older generation stops instead of pushing into a card that no
	/// longer exists.
	private var generation = 0

	/// Every name the card currently up answers to.
	///
	/// One job is handed down the pipeline under two identities: the transfer is
	/// keyed by the store's own composite id — the bundle id, a dot, then the
	/// package URL — and the install half knows only the bundle id. They are the
	/// same job, and a card that ignores one of its own names is a card that
	/// never updates and never goes away.
	private var aliases: Set<String> = []

	/// The multi-sign run the island's one card is walking through, and which of
	/// its apps that card is about right now.
	///
	/// A run of eight apps is one thing the user asked for, so it is one card.
	/// Left to the per-job rule below, every app of a run is a different job and
	/// the island did this for each of them in turn: end the card, start another.
	/// That is a visible blink between apps — and, worse, one start request per
	/// app against a budget that does not have room for eight, after which the
	/// system refuses the rest and the island goes quiet for the tail of a run
	/// that is still going. So the run declares itself: `runNames` is every name
	/// its apps are addressed by, and `runCurrent` is the app being worked on.
	/// While a name is current and the card carries a name from the same run, the
	/// two are one job and the card is retargeted in place — new app, new
	/// position, same card, nothing to blink.
	///
	/// `runCurrent` also settles which app a late callback belongs to. The
	/// previous app's install can land after the run has moved on, and an island
	/// card that accepted it would say "Installing" over the app now signing.
	private var runNames: Set<String> = []
	private var runCurrent: String?

	/// A card showing a terminal state, held up long enough to be read before it
	/// is taken away. Kept separate from `activity` so a new transfer can retire
	/// it at once instead of stacking a second card beside it.
	private var lingering: Activity<DownloadActivityAttributes>?
	private var pendingEnd: Task<Void, Never>?

	/// Whether the pipeline still considers a job to be running.
	///
	/// The card can leave the screen while the work carries on — the user swipes
	/// it away, or the system ends it — and when that happens there is nothing in
	/// the ActivityKit state that says whether the job is still going. This does.
	/// It is set when a card is started and cleared the moment the work ends, so
	/// a later phase can tell "the card went" from "the job went" and put one back
	/// in the first case only.
	private var jobIsActive = false

	/// The app the job without a card is for, kept so the card can be asked for
	/// again when there is a chance of being given one.
	private var lastAppID: String?

	/// Set when a card was refused for the one reason that stops being true: the
	/// app was not in the foreground.
	///
	/// ActivityKit only hands a card to a foreground app, so a job that begins
	/// while the app is in the background — an auto-update, an auto-sign, a run
	/// picked up by a continued-processing task — cannot have one, and each ask
	/// is refused. Asking again on every phase change is therefore a refusal per
	/// phase and a card for none of them: the island stays empty for the whole
	/// job and the console fills with errors that say only what the first one
	/// did. The refusal is remembered instead, the asks stop while it holds, and
	/// the card is asked for once more the next time the app comes forward —
	/// which is the first moment the system will say yes.
	private var cardNeedsForeground = false

	/// The phase a revival was last attempted for. A refused request is the
	/// system's answer, and asking it again on every tick of the same phase is
	/// neither going to change it nor free.
	private var reviveAttemptedPhase: DownloadActivityAttributes.ContentState.Phase?

	/// The beat that carries the wave, and whether the app is being kept up for
	/// the result take-down.
	private var beat: Task<Void, Never>?
	private var isHoldingFinale = false

	/// The shortest gap between two pushes. This is a *rate* limit, never a
	/// filter: a state that arrives inside the gap waits its turn instead of
	/// being dropped, so the island can be slow to update but can never be
	/// wrong about where the job got to.
	///
	/// Two seconds. The first value here was a quarter second — four pushes a
	/// second for the whole of a multi-minute transfer — and on a real device
	/// that exhausts the budget ActivityKit holds for Live Activity content
	/// updates. Exhausted, the system silently drops every later update: the
	/// card freezes at whichever fraction it last rendered — reported from a
	/// phone as "it stops at a random number like 58% or 63%" — while the
	/// download itself finishes underneath it. The simulator does not enforce
	/// the budget, which is why the same build measured fine there.
	///
	/// One push every two seconds stays far inside the budget for the whole
	/// life of any job, and the widget's own animation carries the number
	/// between pushes, so two seconds reads as live, not as lag. Phase changes
	/// and results bypass the gap and always go out.
	private let minimumGap: TimeInterval = 2.0

	/// The phase of the last state actually pushed, so a phase change can jump
	/// the rate limit. Those are the moments the user is watching for.
	private var lastPushedPhase: DownloadActivityAttributes.ContentState.Phase?

	/// When the card's own job began — the moment the card was born, adopted
	/// or revived. The push gap widens as a job ages, so a transfer of any
	/// size at any speed keeps a card that moves without ever pushing enough
	/// updates to meet the system's budget.
	private var jobStartedAt: Date?

	/// The push gap for right now, widening on long jobs.
	///
	/// 2 seconds for the first two minutes — the window most transfers live
	/// in — 5 seconds out to ten minutes, and 15 seconds beyond. The widget
	/// animates between readings, so the card reads as live at every one of
	/// those cadences, and the widening is what makes "any ipa size, any
	/// speed" true: a one-hour transfer pushes fewer than four hundred
	/// readings, where a flat 2-second gap would push eighteen hundred.
	private func currentGap() -> TimeInterval {
		guard let started = jobStartedAt else { return 2.0 }
		let elapsed = Date().timeIntervalSince(started)
		if elapsed > 600 { return 15 }
		if elapsed > 120 { return 5 }
		return 2.0
	}

	/// When the last state went out, for the pump's rate limit.
	private var lastPushedAt: Date?

	/// When a real fraction was last handed over, or nil if none ever was.
	///
	/// The beat keeps the card fresh through a silent phase, and freshness is
	/// what tells the system — and the widget — that the numbers on the card are
	/// still being measured. A beat that carried the last fraction forward
	/// therefore kept a *stopped* number alive: every step re-stamped the state,
	/// so the card never went stale and the widget's stale handling never had a
	/// chance to drop the figure. This is the clock that separates "the job is
	/// still running" from "the number on it is still a reading", and it is
	/// stamped only where a genuine measurement arrives.
	private var lastMeasuredAt: Date?

	/// How long a figure stays on the card with no fresh measurement behind it.
	///
	/// Longer than any healthy gap between readings — a slow or throttled link
	/// still reports every second or two, and `LiveActivityController`'s own
	/// cadence tops out at fifteen seconds on a long job — and short enough that
	/// a stopped transfer's number is gone well before a user could read it as
	/// live. A phase with no fraction of its own (signing, preparing) never sets
	/// this, so this can only ever affect a figure that was real when it landed.
	private static let figureLifetime: TimeInterval = 20

	/// How long a state is believed for. Long enough that a normal gap between
	/// updates cannot make a working card look stale, short enough that a card
	/// whose app was killed stops looking live within a minute.
	private let freshness: TimeInterval = 60

	/// How long a result stays up.
	///
	/// A success gets a beat: long enough to read "Installed" and no longer,
	/// because the app is on the Home Screen by then and a card still sitting
	/// there is the one thing this feature must never do. A failure gets long
	/// enough to read why, since that is the only part of it worth waiting for.
	///
	/// The hold is what makes the result visible at all — ending an activity
	/// dismisses its island representation immediately, so a result that is only
	/// pushed at `end` is never actually seen. The `.after` policy underneath is
	/// the backstop for the app dying mid-hold.
	private let successHold: TimeInterval = 2.5
	private let failureHold: TimeInterval = 5

	/// The wave's period: how long the light takes to go once round the card
	/// while the numbers are moving.
	///
	/// Used as a *rate*, not as a seed any more — see `wavePhase`, which advances
	/// from the last wave by however much time has passed, up to a quarter turn.
	/// The views do the rest: each state's step is carried by the implicit
	/// animation the light views hold, so what the eye sees is a hue drifting
	/// rather than a hue being set.
	private let wavePeriod: TimeInterval = 5.6

	/// When the last wave was handed out, for the rate above.
	private var lastWaveAt: Date?

	/// How often a working card is re-asserted so it cannot go stale.
	///
	/// This is a keep-alive first and a breath second: the state it pushes is the
	/// same job with its light advanced a quarter of a turn, so the card cannot
	/// go stale during a silent phase and does not sit perfectly still while it
	/// waits either. Both of those matter and they are the same push.
	///
	/// The cadence is the point. An earlier version pushed a changed state every
	/// 0.7 seconds to carry the wave round the rim, and that is what made the
	/// island blink: every Live Activity update is re-rendered and cross-faded by
	/// the system, so a card updated three times a second pulses — and on the
	/// compact island, where the rim is 22 pt across, the pulse is the only thing
	/// the eye can see. Twenty-five seconds is slow enough that a cross-fade is
	/// invisible, and with a twenty-second glide in the views (see
	/// `BatAura.silentGlide`) slow enough that the movement in between is
	/// continuous rather than stepped.
	private let keepFresh: TimeInterval = 25

	/// Every push the island is handed, in the console, for measuring cadence.
	private static let pushLog = Logger(subsystem: "app.batsign.ios", category: "livecard")

	private init() {
		// A card that was held back for want of a foreground app is asked for
		// again here, because coming forward is the moment the answer changes.
		NotificationCenter.default.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.retryCardInForeground()
			}
		}
	}

	private var isAuthorised: Bool {
		ActivityAuthorizationInfo().areActivitiesEnabled
	}

	/// Whether the "no card will be drawn" refusal has been said out loud.
	///
	/// The guard is the one refusal in this file with no other trace: with Live
	/// Activities switched off, `begin` returns and the island stays empty for a
	/// whole job with nothing anywhere to say why — which reads exactly like a
	/// caller that never called. Said once per process rather than per job, and
	/// only in a debug build, because the answer does not change within a run.
	private var toldAboutAuthorisation = false

	/// Said once, from the place a missing card is born.
	private func refuseWithoutAuthorisation() -> Bool {
		guard !isAuthorised else { return false }
		#if DEBUG
		if !toldAboutAuthorisation {
			toldAboutAuthorisation = true
			Self.pushLog.notice(
				"card: refused — Live Activities are switched off for this app, so no card is drawn for any job. Nothing below this line is a layout or timing problem."
			)
		}
		#endif
		return true
	}

	// MARK: - Lifecycle

	/// Start (or retarget) the activity for a transfer.
	func begin(
		appID: String,
		appName: String,
		detail: String = "",
		queued: Int = 0,
		bundleID: String? = nil,
		mode: String? = nil
	) {
		guard !refuseWithoutAuthorisation() else { return }

		// A new transfer takes the island over completely: a card still showing
		// the previous result goes now, not when its hold expires.
		retireLingering()

		// A different app taking over ends the old card first, so the island
		// never shows a name that no longer matches the bar under it.
		if let current = activity, !isSameJob(appID, as: current) {
			#if DEBUG
			Self.pushLog.notice(
				"card: taking down \(current.attributes.appID, privacy: .public) — \(appID, privacy: .public) is a different job"
			)
			#endif
			takeDown(current)
		}

		// A card already on screen for this job is this job's card, even when the
		// process that started it is gone.
		//
		// The two halves of a job are addressed differently — the transfer by the
		// store's composite id, the install by the bundle id — and a job picked
		// back up after a restart arrives with neither in hand, because the names
		// it learned died with the process that learned them. ActivityKit's own
		// list is the truth about what is up, so the card is taken back from there
		// rather than asked for a second time. Asking again is how the island ends
		// up with two cards — one of them with nobody able to reach it, sitting on
		// "Installing" for the rest of the job it describes.
		//
		// Asked before the aliases below are registered, because the aliases are
		// what tells a card apart from a different job's card, and a name
		// registered for a card that does not exist yet matches everything.
		if activity == nil, !appID.isEmpty {
			activity = _adoptJobCard(for: appID)
		}

		aliases.insert(appID)
		if let bundleID, !bundleID.isEmpty { aliases.insert(bundleID) }
		var state = DownloadActivityAttributes.ContentState(
			phase: .downloading,
			appName: appName,
			progress: 0,
			detail: detail,
			queued: queued,
			mode: mode
		)
		// Nothing has arrived yet, so there is no fraction to claim. The card
		// says "starting" rather than 0% until a byte count says otherwise —
		// a download whose server never declares a size would otherwise open on
		// a percentage it can never move.
		state.progressKnown = false
		state.wave = wavePhase()

		if activity != nil {
			lastState = state
			jobIsActive = true
			enqueue(state)
			startBeat()
			return
		}

		// No reference in hand, but the card for this very job may still be up —
		// a stale one from a suspension, or one left by a run that was killed
		// under it. Adopting it keeps the job on one card; asking for a new one
		// beside it is how the island ends up with two.
		if _adoptJobCard(for: appID) != nil {
			lastState = state
			jobIsActive = true
			reviveAttemptedPhase = nil
			enqueue(state)
			return
		}

		// Whatever else is up belongs to a job that is over — this job is taking
		// the island, and it does not stack its card on top of a dead one.
		let strays = Activity<DownloadActivityAttributes>.activities.filter { candidate in
			candidate.id != lingering?.id && (candidate.activityState == .stale || candidate.activityState == .active)
		}
		for stray in strays {
			end(stray, immediately: true)
		}

		if let requested = requestCard(appID: appID, state: state) {
			activity = requested
			lastState = state
			jobIsActive = true
			reviveAttemptedPhase = nil
			startBeat()
		} else {
			// A refused request (authorisation, the system's own limit, or an app
			// that is not in the foreground) simply means no live card; the
			// in-app progress is unaffected. The job is still marked active and
			// its state still remembered, so the first phase change can try
			// again — and so a card refused only for want of a foreground app can
			// be asked for the moment there is one, opening on this state rather
			// than on whatever phase the job has reached by then.
			activity = nil
			lastState = state
			jobIsActive = true
		}
	}

	/// Ask the system for a card, and say so when it refuses.
	///
	/// A refusal is the one failure with no other trace: ActivityKit throws, the
	/// exception goes nowhere, and the result is an island that stays empty for a
	/// whole job with nothing in the console to explain it. It is logged here at
	/// `.error` so "the card never appeared" is a question with an answer.
	@discardableResult
	private func requestCard(
		appID: String,
		state: DownloadActivityAttributes.ContentState
	) -> Activity<DownloadActivityAttributes>? {
		// The system gives a card to a foreground app only, and that is a fact
		// this process can check for itself rather than infer from a thrown
		// error. A job that begins in the background — an auto-update, an
		// auto-sign, a run picked up by a continued-processing task — is refused
		// once per phase if it asks anyway, which is a card for none of them and
		// a console full of the same refusal. So it does not ask: the want is
		// remembered, and the ask is made again the next time the app is forward,
		// which is the first moment the system will say yes.
		guard UIApplication.shared.applicationState == .active else {
			// Said once per episode rather than once per phase, so the console
			// has the reason without having it ten times.
			let isFirstAsk = !cardNeedsForeground
			cardNeedsForeground = true
			lastAppID = appID
			if isFirstAsk {
				Self.pushLog.notice(
					"card: held back — the system gives a card to a foreground app only, so this one waits for the app to come forward rather than asking again on every phase"
				)
			}
			return nil
		}
		lastAppID = appID
		do {
			let started = try Activity.request(
				attributes: DownloadActivityAttributes(appID: appID),
				content: content(state),
				pushType: nil
			)
			#if DEBUG
			// A card is asked for at the start of a job and again whenever a phase
			// with no card up changes. Each one is a line here, so a card that is
			// being built and taken down in a loop — which is what an island that
			// blinks looks like from the inside — is visible as itself.
			Self.pushLog.notice(
				"card: started \(started.id, privacy: .public) for \(appID, privacy: .public) on \(state.phase.rawValue, privacy: .public)"
			)
			#endif
			cardNeedsForeground = false
			jobStartedAt = Date()
			return started
		} catch {
			Self.pushLog.error(
				"card: request refused — \(error.localizedDescription, privacy: .public)"
			)
			return nil
		}
	}

	/// Ask for the card again, now that there is a chance of being given one.
	///
	/// The refused ask is not thrown away: the job it was for is still the job,
	/// and the state it was refused with is the state the card should open on. So
	/// the card is asked for once more on the way forward and then carries on from
	/// wherever the job has got to, which is what makes an auto-update started in
	/// the background show up on the island at all — late, but true, instead of
	/// never.
	private func retryCardInForeground() {
		guard cardNeedsForeground else { return }
		cardNeedsForeground = false

		guard isAuthorised, jobIsActive, activity == nil, let state = lastState,
		      let appID = lastAppID else { return }

		guard let requested = requestCard(appID: appID, state: state) else {
			#if DEBUG
			Self.pushLog.notice(
				"card: the ask on coming forward was refused too — the job carries on without a card"
			)
			#endif
			return
		}
		#if DEBUG
		Self.pushLog.notice(
			"card: back up on \(state.phase.rawValue, privacy: .public) — the app came forward while the job was still running"
		)
		#endif
		activity = requested
		lastState = state
		reviveAttemptedPhase = nil
		startBeat()
		// The state the card opened on is the live one, not the one that was last
		// pushed, so it goes out as an update: a card that opens on a phase the
		// job has already left would sit on it until the next phase change.
		enqueue(state)
	}

	/// Make sure the card is up, and pointing at this phase.
	///
	/// The signing and install halves run after the transfer has been handed on,
	/// and they can also be the *first* thing to run — a user tapping "install"
	/// from a notification long after the download card went away. Both cases
	/// want the same thing: a card that says what is happening.
	///
	/// So this is `update` with a `begin` underneath it, not "start one if there
	/// is none". A card *is* up by the time the install begins — it is the one
	/// the transfer left behind, still saying "Signing" — and returning early
	/// because a card already existed is what left the island on the wrong phase
	/// for the whole install.
	func ensure(
		appID: String,
		appName: String,
		phase: DownloadActivityAttributes.ContentState.Phase,
		detail: String = "",
		mode: String? = nil,
		/// How many more of the same run are behind this one, when the job is
		/// one app of several. Nil leaves whatever the card already says.
		queued: Int? = nil
	) {
		guard isAuthorised else { return }

		let unknownJob = appID.isEmpty

		if let current = activity {
			if unknownJob || isSameJob(appID, as: current) {
				if !unknownJob { aliases.insert(appID) }
					update(
						phase: phase,
						appName: appName,
						detail: detail,
						queued: queued,
						force: true,
						appID: unknownJob ? nil : appID,
						mode: mode
					)
					startBeat()
					return
			}
			// Some other job's card. The island shows one thing at a time, and
			// it is going to be this.
			#if DEBUG
			Self.pushLog.notice(
				"card: ensure is taking down \(current.attributes.appID, privacy: .public) for \(appID, privacy: .public)"
			)
			#endif
			takeDown(current)
		}

		begin(appID: appID, appName: appName, detail: detail, queued: queued ?? 0, mode: mode)
		// No fraction is handed over, because none was measured: the zero is the
		// card's numeric field, not a reading. Saying so is the whole difference
		// between a bar that fills when the install reports a number and one
		// parked at 0% for the length of a signing stretch the island cannot see
		// into — which is what "the dynamic island is stuck at 0" was.
		update(
			phase: phase,
			appName: appName,
			detail: detail,
			queued: queued,
			progressKnown: false,
			force: true,
			appID: unknownJob ? nil : appID,
			mode: mode
		)
	}

	/// Push new state. `force` is used for phase changes and terminal states.
	func update(
		phase: DownloadActivityAttributes.ContentState.Phase? = nil,
		appName: String? = nil,
		progress: Double? = nil,
		detail: String? = nil,
		queued: Int? = nil,
		progressKnown: Bool? = nil,
		force: Bool = false,
		appID: String? = nil,
		mode: String? = nil
	) {
		guard isAuthorised else { return }

		// A card the user swiped away, or one the system ended, is not a card.
		// Stale is different: the freshness date passed while nothing was pushed
		// — a suspension, a silent phase — but the card is still on screen, and
		// a push with a fresh date of its own is what brings it back to active.
		// Dropping the reference on a stale card was the stranding: the card sat
		// frozen at its last words while every later push built or reached for
		// some other card, and no finish could ever reach it again.
		var card = activity
		if let current = card, current.activityState != .active, current.activityState != .stale {
			activity = nil
			card = nil
		}
		// The reference can also be gone while the card is still up — it went
		// stale in a drain that no longer runs, or the process was restarted
		// under a visible card. The system's own list is the truth; adopt it
		// rather than stack a second card beside it.
		if card == nil, jobIsActive, let adopted = _adoptJobCard(for: appID) {
			card = adopted
		}

		// A late caller reporting on an app the island has already moved past
		// must not paint its own name over the card that is up now.
		if let appID, let current = card, !isSameJob(appID, as: current) {
			#if DEBUG
			// Every one of these is a state the card never hears. They are logged
			// because a card that stops moving has two possible causes — the state
			// never arrived, or it arrived under a name the card does not answer to
			// — and this is the only place that can tell them apart.
			Self.pushLog.notice(
				"card: ignored a push for \(appID, privacy: .public) — the card answers to \(current.attributes.appID, privacy: .public)"
			)
			#endif
			return
		}

		let previous = lastState
		var next = previous ?? DownloadActivityAttributes.ContentState(
			phase: .downloading,
			appName: appName ?? "",
			progress: 0,
			detail: detail ?? "",
			queued: queued ?? 0,
			mode: mode
		)

		if let phase { next.phase = phase }
		if let appName { next.appName = appName }
		if let progress {
			next.progress = min(max(progress, 0), 1)
			// A caller that hands over a fraction means it. The flag exists for
			// the one path that sometimes has nothing to divide by — the
			// transfer — and every other phase is stating a real number.
			next.progressKnown = progressKnown ?? true
			// A figure that is a reading is stamped as one. This is the clock the
			// beat reads to decide whether the number on the card is still a
			// measurement or only a memory of one; see `figureLifetime`.
			if next.progressKnown != false { lastMeasuredAt = Date() }
		} else if let progressKnown {
			next.progressKnown = progressKnown
		}
		// A fraction belongs to the phase that measured it, and to no other. When
		// the job moves on without a new number — the transfer that ended at
		// 100%, the install that has not reported one yet — the figure in hand
		// describes work that is over, and carrying it into the next phase is a
		// claim about work nobody has measured. Two lies came out of that: a card
		// opening the install on the download's 100%, and one opening it on a
		// fabricated 0% for the whole of signing and installing.
		if let phase, phase != previous?.phase, progress == nil {
			next.progressKnown = false
		}
		if let detail { next.detail = detail }
		if let queued { next.queued = queued }
		if let mode { next.mode = mode }

		// The wave rides along with every state but is never a reason to push
		// one: it advances on its own clock, and comparing it here would turn
		// every redundant call into an update. What is compared is the job.
		if let previous {
			var comparable = next
			comparable.wave = previous.wave
			guard comparable != previous else { return }
		}

		next.wave = wavePhase()

		if card == nil {
			// No card on screen and the job still running. The island must not sit
			// empty through work the user can see happening in the app, so this
			// state — a phase change, by construction: a progress tick carries no
			// new phase and cannot reach here with one — starts a fresh card.
			//
			// Once per phase, so a request the system refuses is asked again at
			// the next stage of the job and not once per tick.
			guard jobIsActive,
			      let appID, !appID.isEmpty,
			      let phase, phase.isActive,
			      reviveAttemptedPhase != phase
			else { return }

			reviveAttemptedPhase = phase
			guard let revived = requestCard(appID: appID, state: next) else { return }

			activity = revived
			lastState = next
			aliases.insert(appID)
			startBeat()
			return
		}

		// Nothing is dropped here. The pump keeps one push in flight and always
		// sends the newest state, which is a strictly better answer to a burst
		// than discarding ticks and hoping the last one survives.
		lastState = next
		enqueue(next, urgent: force)
	}

	/// The work finished.
	///
	/// The card stops being live the instant this returns: `activity` is cleared,
	/// so a transfer starting underneath the result gets the slot rather than
	/// stacking beside it. The result itself is held on screen for the moment it
	/// takes to read, and the hold is ended by a task — short by design, because
	/// the island must be empty again by the time the user looks up from the
	/// Home Screen.
	///
	/// `appID` is how a late caller is kept out. The install it was watching may
	/// have finished long after the island moved on to the next transfer, and it
	/// has no business ending a card that is no longer about it.
	func finish(success: Bool, appName: String, detail: String, appID: String? = nil) {
		// The job is over whatever the card did, so a stray update that arrives
		// after this one has no active job to revive.
		jobIsActive = false
		reviveAttemptedPhase = nil

		// The card may not be in hand — it went stale during a suspension, or the
		// process was restarted under it. It is still on screen, and a result
		// that cannot reach it is the island left saying "Signing and installing"
		// after the app is already on the Home Screen. Asked for, adopted, ended.
		guard let current = activity ?? _adoptJobCard(for: appID) else { return }
		if let appID, !appID.isEmpty, !isSameJob(appID, as: current) { return }

		var state = DownloadActivityAttributes.ContentState(
			phase: success ? .finished : .failed,
			appName: appName,
			progress: success ? 1 : (lastState?.progress ?? 0),
			detail: detail,
			queued: 0,
			mode: lastState?.mode
		)
		state.wave = wavePhase()

		// Out of the live slot first, so the next transfer is never held up by
		// the result — and so nothing that arrives during the hold can paint
		// over it.
		activity = nil
		lastState = state
		pending = nil
		pendingIsUrgent = false
		lastPushedAt = nil
		lastPushedPhase = state.phase
		jobStartedAt = nil
		lastMeasuredAt = nil
		aliases = []
		generation += 1

		// A previous result goes now rather than at the end of its own hold.
		retireLingering()

		lingering = current

		let hold = success ? successHold : failureHold
		let deadline = Date().addingTimeInterval(hold)

		// One call, and from here the card is the system's, not this process's:
		// the final state stays on screen until the deadline and is then
		// dismissed, whether or not this app is still running. The old
		// update → sleep → end dance removed the card only if the process
		// survived the sleep — which it usually does not when the install lands
		// while the user is on the Home Screen, and that was the card stuck at
		// 100% with "Installed" written on it, indefinitely, on device.
		//
		// The call itself is still a task, and a task needs a process to run in.
		// The install lands while the user is on the Home Screen *by design*, so
		// the one moment that must not be suspended is this one: the hold keeps
		// the app scheduled until the end has actually been handed over. It is
		// released by the same task, and it is the only hold this file takes.
		holdFinale()

		#if DEBUG
		// The end of the walk, said out loud. Every other state the card is handed
		// is logged where it is pushed; the result is not pushed but *ended*, so a
		// run that finds no "push finished" line cannot tell "the result was never
		// delivered" from "the result is delivered by a different route". This is
		// that route, named, with the deadline the system was given.
		Self.pushLog.notice(
			"card: result \(state.phase.rawValue, privacy: .public) for \(appName, privacy: .public) — held \(hold, privacy: .public)s then dismissed by the system"
		)
		#endif

		pendingEnd = Task { [weak self] in
			await current.end(
				ActivityContent(state: state, staleDate: deadline),
				dismissalPolicy: .after(deadline)
			)

			guard let self else { return }
			#if DEBUG
			Self.pushLog.notice("card: result handed over — the card is the system's now and goes at its deadline")
			#endif
			if self.lingering?.id == current.id { self.lingering = nil }
			self.pendingEnd = nil
			self.releaseFinale()
		}
	}

	/// Drop a card that is showing a result, right now.
	private func retireLingering() {
		pendingEnd?.cancel()
		pendingEnd = nil
		if let lingering {
			end(lingering, immediately: true)
			self.lingering = nil
		}
		releaseFinale()
	}

	/// Nothing is running any more. A result card, if one is up, still gets its
	/// hold — cancelling a queue is not a finished job.
	func end(appID: String? = nil) {
		guard let current = activity ?? _adoptJobCard(for: appID) else { return }
		// A caller that watched one app must not take down the card of another.
		if let appID, !appID.isEmpty, !isSameJob(appID, as: current) { return }
		takeDown(current)
	}

	/// The card the system is showing, when this object no longer holds it.
	///
	/// The one card a job may have can outlive the reference to it: iOS marks it
	/// stale after a silent stretch, a drain drops it as dead, or the process is
	/// restarted while it is on screen. Left unfound it becomes the card that
	/// never moves — frozen on its last words through signing, through the
	/// install, and after the app is already on the Home Screen — while the next
	/// phase builds a second card beside it. The system's own list is the truth
	/// about what is up, so the job takes its card back from there instead of
	/// stacking another one.
	private func _adoptJobCard(for appID: String?) -> Activity<DownloadActivityAttributes>? {
		guard isAuthorised else { return nil }

		let adopted = Activity<DownloadActivityAttributes>.activities.first { candidate in
			// A result being held for its moment on screen is not a job's card.
			if candidate.id == lingering?.id { return false }
			// A card the user swiped away is gone, even though ActivityKit still
			// lists it. Taking it back made it this job's card forever after:
			// every update found it, refused it, and dropped it again, the
			// revive path stayed unreachable because `activity` was non-nil, and
			// the job had no working card for the rest of its life. Only a card
			// that is genuinely up is one worth reclaiming.
			guard candidate.activityState == .active || candidate.activityState == .stale else { return false }
			guard let appID, !appID.isEmpty else { return true }
			return isSameJob(appID, as: candidate)
		}

		guard let adopted else { return nil }
		activity = adopted
		if jobStartedAt == nil { jobStartedAt = Date() }
		startBeat()
		Self.pushLog.notice("card: took back the card that was already up (\(adopted.id, privacy: .public))")
		return adopted
	}

	/// Forget the card and end it. The pending state and the generation both go,
	/// so a drain still in flight cannot push into a card that is gone.
	private func takeDown(_ current: Activity<DownloadActivityAttributes>) {
		#if DEBUG
		Self.pushLog.notice("card: taken down \(current.id, privacy: .public) and ended immediately")
		#endif
		activity = nil
		lastState = nil
		pending = nil
		pendingIsUrgent = false
		lastPushedAt = nil
		lastPushedPhase = nil
		jobStartedAt = nil
		lastMeasuredAt = nil
		aliases = []
		jobIsActive = false
		reviveAttemptedPhase = nil
		generation += 1
		stopBeat()
		end(current, immediately: true)
	}

	// MARK: - A run of apps

	/// A multi-sign run has started: these are the names its apps are addressed
	/// by, and they are all one thing to the island for as long as it runs.
	///
	/// Called once, when the run is created. A later run replaces the set
	/// outright — two runs are two cards, and the second one is the one on
	/// screen now.
	func declareRun(names: [String]) {
		let fresh = Set(names.filter { !$0.isEmpty })
		guard !fresh.isEmpty else { return }
		runNames = fresh
		runCurrent = nil
	}

	/// The run has moved on to this app: the card stays up and its subject
	/// changes. The name is recorded as one of the run's even if the run did not
	/// know it up front, because a source app is addressed by its transfer first
	/// and by its bundle id once the package has landed — the run learns the
	/// second name from the pipeline, exactly as the card's own aliases do.
	func noteRunCurrent(_ name: String) {
		guard !name.isEmpty, !runNames.isEmpty else { return }
		runNames.insert(name)
		runCurrent = name
	}

	/// The run is over. Its apps are separate jobs again, so a card left over
	/// from the run cannot be claimed by one of them later.
	func releaseRun() {
		runNames = []
		runCurrent = nil
	}

	/// Teaches the card that is up one more of its own names.
	///
	/// The pipeline learns the bundle id in the middle of the job — from the
	/// package it just extracted — and every phase after that addresses the app
	/// that way. Registering it here is what lets the install half keep driving
	/// the same card the download started.
	func addAlias(_ alias: String, for appID: String? = nil) {
		guard !alias.isEmpty else { return }

		// The name belongs to the card for this job, and that card may not be in
		// hand: the reference goes when a drain drops a card the system still
		// shows, and it is gone entirely after a restart that leaves the card up.
		// Registering only against a reference we hold meant the second name was
		// silently dropped in exactly those cases — and every phase after this
		// point addresses the app by that name, so each one was refused as
		// another job's and the card froze on the phase it was showing when the
		// name changed. That is the island that stops at the download and never
		// says Signing.
		//
		// So the card is taken back from the system first, the same way a push
		// does, and the name is registered against the card that is actually up.
		var current = activity
		if current == nil, jobIsActive { current = _adoptJobCard(for: appID) }
		guard let current else { return }
		if let appID, !appID.isEmpty, !isSameJob(appID, as: current) { return }
		aliases.insert(alias)
	}

	/// Whether a caller's identifier names the card that is up.
	///
	/// Exact equality is the common case. The fallback is the pipeline's own
	/// composite id: `com.example.app` and `com.example.app.https://…` are one
	/// job, and a dotted prefix is the only relationship between them — no two
	/// different bundle ids can be a prefix of one another.
	private func isSameJob(_ appID: String, as current: Activity<DownloadActivityAttributes>) -> Bool {
		if aliases.contains(appID) { return true }

		// One run, one card: the caller is the app the run is on now, and the
		// card is one the same run put up. The card's own name is what is
		// compared, not `runCurrent`, because the card is not renamed as the run
		// moves — that is the whole point of not starting a new one.
		if let runCurrent, runCurrent == appID, runNames.contains(current.attributes.appID) {
			return true
		}
		let mine = current.attributes.appID
		if appID == mine { return true }
		if mine.hasPrefix(appID + ".") || appID.hasPrefix(mine + ".") { return true }
		return false
	}

	/// Called at launch and on every return to the foreground: a card left behind
	/// by a crashed, killed or suspended run is not a live transfer, and must not
	/// sit in the island pretending to be one.
	///
	/// A card that belongs to the job running *right now* is left alone — the
	/// pipeline is between phases, not gone — and so is a result still inside its
	/// hold, which is being taken down by its own task. Anything else goes.
	func endOrphans() {
		guard isAuthorised else { return }

		let strays = Activity<DownloadActivityAttributes>.activities
		guard !strays.isEmpty else { return }

		var keep: Set<String> = []
		if let current = activity { keep.insert(current.id) }
		if let lingering { keep.insert(lingering.id) }

		let orphans = strays.filter { stray in
			if keep.contains(stray.id) { return false }
			// A card for a job we are still holding must not be swept up just
			// because the activity list lost track of which one is ours.
			if let current = activity, isSameJob(current.attributes.appID, as: stray) { return false }
			return true
		}

		guard !orphans.isEmpty else { return }

		Task {
			for stray in orphans {
				await stray.end(nil, dismissalPolicy: .immediate)
			}
		}
	}

	// MARK: - The wave

	/// Where the wave is now, 0…1 round the card.
	///
	/// Off the clock rather than off a counter, so two waves pushed a second
	/// apart are a second apart in phase no matter how many pushes were
	/// coalesced in between — and *capped*, because the clock alone is wrong the
	/// moment a phase goes quiet: a push arriving after twenty-five silent
	/// seconds would move the light four and a half times round the card, and the
	/// view, told to glide there, would fly rather than drift. A quarter turn is
	/// the most any single step may carry, which is exactly what the beat's own
	/// step wants and less than a second's worth of a transfer's.
	private func wavePhase(at date: Date = Date()) -> Double {
		let base: Double

		if let previous = lastState?.wave, previous.isFinite {
			let elapsed = lastWaveAt.map { date.timeIntervalSince($0) } ?? 0
			base = previous + min(0.25, max(0, elapsed) / wavePeriod)
		} else {
			// A card that has just appeared puts its light wherever the clock is,
			// so two jobs in a row do not both begin with the wave in the same
			// place.
			base = date.timeIntervalSinceReferenceDate / wavePeriod
		}

		lastWaveAt = date
		return base - floor(base)
	}

	/// Keep a working card fresh while there is something to keep fresh.
	///
	/// The pipeline's own ticks cannot do it: progress is bursty and the long
	/// phases are silent — signing reports nothing for minutes — so a card whose
	/// freshness came only from those ticks would read as stale exactly when the
	/// user is staring at the island wondering whether anything is still
	/// happening. One push every twenty-five seconds keeps the sixty-second
	/// window open, and it is the same push that carries the light a quarter of
	/// the way round the card, so a silent phase is not a frozen one.
	///
	/// The beat used to push a *changed* state every 0.7 seconds to carry the
	/// wave round the rim. That is what made the island blink: every Live
	/// Activity update is re-rendered and cross-faded by the system, so a card
	/// updated three times a second pulses — and on the compact island, where the
	/// rim is 22 pt across, the pulse is the only thing the eye can see. Three
	/// pushes a minute, each one taking twenty seconds to complete its travel, is
	/// the opposite of that: continuous drift, and a cross-fade the eye has no
	/// reason to notice.
	///
	/// It stops with the job. Once there is no card and no result, there is
	/// nothing to keep up, and the beat cancels itself on the next step.
	private func startBeat() {
		guard beat == nil else { return }
		beat = Task { [weak self] in
			while true {
				guard let self else { return }
				try? await Task.sleep(nanoseconds: UInt64(self.keepFresh * 1_000_000_000))
				if Task.isCancelled { return }
				self.step()
			}
		}
	}

	private func stopBeat() {
		beat?.cancel()
		beat = nil
	}

/// One step of the beat: the same work, a little further round.
	private func step() {
		guard isAuthorised else { return }

		if var state = lastState, state.phase.isActive {
			// The one thing that changes is the light. The job is the same job it
			// was twenty-five seconds ago — that is what makes this a keep-alive
			// rather than news — and the wave is what carries it: a quarter turn
			// per step, which the card's own glide spreads over the twenty
			// seconds that follow, so a signing phase breathes instead of sitting
			// frozen at a hue it has been holding since it began.
			//
			// The *figure* is not re-asserted. A keep-alive that carries the last
			// fraction forward is a keep-alive that keeps a stopped number alive:
			// it re-stamps the state as fresh every twenty-five seconds, so the
			// card never even reaches the stale age the widget uses to drop a
			// number — the island is handed a live-looking "60%" for as long as
			// the process runs, long after the transfer stopped measuring one.
			// That is the whole of "it parks on a number": measured on a stalled
			// transfer, the beat pushed 60% nineteen seconds after the app went
			// to the background and would have gone on doing it indefinitely.
			//
			// So the beat drops the figure once the app has had nothing real to
			// say for longer than any healthy phase would go quiet. The phase and
			// the light still go up — the job is still this job — and the number
			// returns the moment a real reading arrives, because that is a push
			// of its own.
			if let measured = lastMeasuredAt,
			   Date().timeIntervalSince(measured) > Self.figureLifetime {
				state.progressKnown = false
				// And the line under the bar, for the same reason and by the same
				// clock. It carries the byte count and the rate of the last real
				// reading — "9.9 MB of 16.4 MB · 1.1 MB/s" — and a rate is the
				// most perishable figure on the card: left in place it reads as a
				// transfer still moving at full speed, which is the same lie as
				// the parked percentage. Nothing honest can be said about where
				// the job has got to without a fresh measurement, so the card
				// says exactly that.
				//
				// Only the transfer, though. Signing and installing are silent by
				// nature — minutes of work with no fraction to report — and their
				// lines are not measurements that went stale: "Signing...",
				// "Installing..." are the honest present tense of a phase that is
				// genuinely still running. Only a phase whose words *were* a
				// reading loses them.
				if state.phase == .downloading {
					state.detail = "Reconnecting…"
				}
			}
			state.wave = wavePhase()
			lastState = state
			enqueue(state)
			return
		}

		// Terminal, or the card was swiped away. The result takes care of
		// itself, so with nothing lingering the beat has no reason to exist.
		if lingering == nil { stopBeat() }
	}

	// MARK: - The pump

	private func enqueue(_ state: DownloadActivityAttributes.ContentState, urgent: Bool = false) {
		pending = state
		// Latched rather than replaced: if anything in the batch that is waiting
		// asked to go out now, the state that finally goes out is still that
		// batch's answer, and it inherits the hurry.
		pendingIsUrgent = pendingIsUrgent || urgent
		// Nothing has gone out on this card yet, so this state is its birth and
		// the one after it is its first reading. Set here rather than at the call
		// sites because "this card has never pushed" is exactly what the birth
		// push looks like from the pump, whichever of the four ways a card is
		// born — requested, adopted, revived, or picked up after a restart.
		if lastPushedAt == nil { firstContentIsFree = true }
		guard !isPushing else { return }
		isPushing = true
		let token = generation
		Task { await drain(token) }
	}

	/// Push the newest state, then keep going while newer ones keep arriving.
	///
	/// One push in flight at a time and only ever the latest state, so the island
	/// converges on the truth as fast as ActivityKit allows rather than replaying
	/// a backlog of percentages that are already history.
	private func drain(_ token: Int) async {
		while token == generation {
			// Stale is not dead. The card is on screen and this push — with a
			// fresh date — is what revives it; treating it as gone here is what
			// left the island frozen on its last words with nobody able to reach
			// it. Only a card that is really over is dropped.
			guard let current = activity,
			      current.activityState == .active || current.activityState == .stale
			else {
				activity = nil
				lastState = nil
				jobStartedAt = nil
				break
			}
			guard let state = pending else { break }

			// A phase change or a result ignores the gap; so does a caller that
			// asked for its state to go out now. A progress tick waits it out and
			// then re-reads `pending`, so a newer state that arrived during the
			// wait is the one that goes out and nothing is ever lost.
			//
			// The birth push is exempt by arithmetic rather than by name — nothing
			// has been pushed, so there is no gap to measure from. The reading
			// right after it is exempt on purpose; see `firstContentIsFree`.
			let isBirth = lastPushedAt == nil
			let urgent = pendingIsUrgent
				|| (firstContentIsFree && !isBirth)
				|| state.phase != lastPushedPhase
				|| !state.phase.isActive
			if !urgent, let at = lastPushedAt {
				let wait = currentGap() - Date().timeIntervalSince(at)
				if wait > 0 {
					// The gap is a cadence limit, not a phase filter: a state that
					// arrives inside it waits its turn. But the wait must not
					// outlive the state. A phase change or a result arriving mid-gap
					// flips the urgent latch, and a single long sleep cannot see
					// that flip. One long sleep was also what let a finish that
					// landed during the wait bump the generation and take the
					// pending phase down with it: the island jumped from the last
					// download reading straight to the result, and Preparing /
					// Signing / Installing never appeared. Sliced, the sleep
					// re-reads both every tenth of a second, so the newest phase
					// goes out within a beat of arriving — and a card that died
					// under it is noticed the same way.
					var remaining = wait
					while remaining > 0, token == generation, !pendingIsUrgent {
						let slice = min(remaining, 0.1)
						try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
						remaining -= slice
					}
					continue
				}
			}

			pending = nil
			pendingIsUrgent = false
			if !isBirth { firstContentIsFree = false }
			lastPushedAt = Date()
			lastPushedPhase = state.phase
			#if DEBUG
			// Every push, on the console, so the cadence one actually costs can be
			// read rather than believed. A card updated several times a second is a
			// card that blinks, and that is not something a picture of the island
			// on a simulator can show.
			// `.notice` rather than `.debug`, because a debug-level line is not
			// collected by `log show` without turning debug logging on for the
			// process — and a measurement that has to be enabled is a measurement
			// nobody takes. Debug builds only.
			Self.pushLog.notice(
				"card: push \(state.phase.rawValue, privacy: .public) \(Int((state.progress * 100).rounded()), privacy: .public)% known=\(state.progressKnown ?? true, privacy: .public) wave=\(String(format: "%.3f", state.wave ?? 0), privacy: .public) — \(state.detail, privacy: .public)"
			)
			#endif
			await current.update(content(state))
		}
		isPushing = false
	}

	/// Every live state carries the moment it stops being true, so an app that
	/// dies mid-transfer leaves a card the system knows is stale rather than one
	/// that looks like it is still working for ever.
	private func content(_ state: DownloadActivityAttributes.ContentState) -> ActivityContent<DownloadActivityAttributes.ContentState> {
		let isTerminal = state.phase == .finished || state.phase == .failed
		return ActivityContent(
			state: state,
			staleDate: isTerminal ? nil : Date().addingTimeInterval(freshness)
		)
	}

	// MARK: - Holding the app up for the result

	/// Keep the process scheduled for the length of a result's hold.
	///
	/// The hold is a task, and a task cannot run in a suspended process. The
	/// install usually lands while the user is on the Home Screen — that is the
	/// whole point of the hand-off — so without this the "Installed" card would
	/// be pushed and then never taken away, which is exactly the stuck island
	/// this file exists to prevent. Held separately from the pipeline's own
	/// holds, so releasing one cannot drop the other.
	private func holdFinale() {
		guard !isHoldingFinale else { return }
		isHoldingFinale = true
		BSJobKeepAlive.shared.begin(BSJobKeepAlive.Reason.finale)
	}

	private func releaseFinale() {
		guard isHoldingFinale else { return }
		isHoldingFinale = false
		BSJobKeepAlive.shared.end(BSJobKeepAlive.Reason.finale)
	}

	private func end(_ activity: Activity<DownloadActivityAttributes>, immediately: Bool) {
		Task {
			await activity.end(nil, dismissalPolicy: immediately ? .immediate : .default)
		}
	}
}

// MARK: - Call sites

/// A tiny façade so the rest of the app never has to think about availability,
/// and so there is exactly one place to look when the island does not appear.
enum LiveStatus {
	/// The system's own card for the job — the one iOS draws while a
	/// continued-processing grant is held — is told the same thing as the island,
	/// from the same call sites. One source, so the two surfaces cannot disagree:
	/// the same name, the same phase, the same fraction, at the same moment.
	private static func _mirror(phase: String, title: String, progress: Double? = nil) {
		Task { @MainActor in
			BSContinuedProcessing.shared.publish(phase: phase, title: title, progress: progress)
		}
	}

	static func begin(
		appID: String,
		appName: String,
		detail: String = "",
		queued: Int = 0,
		bundleID: String? = nil,
		mode: String? = nil
	) {
		_mirror(phase: detail.isEmpty ? "Starting" : detail, title: appName)
		guard #available(iOS 16.2, *) else { return }
		Task { @MainActor in
			LiveActivityController.shared.begin(
				appID: appID,
				appName: appName,
				detail: detail,
				queued: queued,
				bundleID: bundleID,
				mode: mode
			)
		}
	}

	static func ensure(
		appID: String,
		appName: String,
		phase: DownloadActivityAttributes.ContentState.Phase,
		detail: String = "",
		mode: String? = nil,
		queued: Int? = nil
	) {
		guard #available(iOS 16.2, *) else { return }
		Task { @MainActor in
			LiveActivityController.shared.ensure(
				appID: appID,
				appName: appName,
				phase: phase,
				detail: detail,
				mode: mode,
				queued: queued
			)
		}
	}

	static func update(
		phase: DownloadActivityAttributes.ContentState.Phase,
		appName: String,
		progress: Double,
		detail: String = "",
		queued: Int = 0,
		progressKnown: Bool? = nil,
		force: Bool = false,
		appID: String? = nil,
		mode: String? = nil
	) {
		// The transfer's real fraction while there is one, and nothing at all for
		// the phases that have no fraction of their own — the same rule the island
		// follows, for the same reason: a number that is not a number is a lie the
		// user can see.
		_mirror(
			phase: detail.isEmpty ? phase.title : detail,
			title: appName,
			progress: progressKnown == false ? nil : progress
		)
		guard #available(iOS 16.2, *) else { return }
		Task { @MainActor in
			LiveActivityController.shared.update(
				phase: phase,
				appName: appName,
				progress: progress,
				detail: detail,
				queued: queued,
				progressKnown: progressKnown,
				force: force,
				appID: appID,
				mode: mode
			)
		}
	}

	static func finish(success: Bool, appName: String, detail: String, appID: String? = nil) {
		_mirror(phase: detail.isEmpty ? (success ? "Installed" : "Failed") : detail, title: appName)
		guard #available(iOS 16.2, *) else { return }
		Task { @MainActor in
			LiveActivityController.shared.finish(
				success: success,
				appName: appName,
				detail: detail,
				appID: appID
			)
		}
	}

	static func end(appID: String? = nil) {
		guard #available(iOS 16.2, *) else { return }
		Task { @MainActor in
			LiveActivityController.shared.end(appID: appID)
		}
	}

	/// One more name for the card that is up, when the job learns its own
	/// bundle id part-way through.
	static func addAlias(_ alias: String, for appID: String? = nil) {
		guard #available(iOS 16.2, *) else { return }
		Task { @MainActor in
			LiveActivityController.shared.addAlias(alias, for: appID)
		}
	}

	/// A multi-sign run has started. Its apps share the one card the island
	/// draws for the run, instead of ending and starting a card each.
	static func declareRun(names: [String]) {
		guard #available(iOS 16.2, *) else { return }
		Task { @MainActor in
			LiveActivityController.shared.declareRun(names: names)
		}
	}

	/// The run has moved on to this app — the card stays, its subject changes.
	static func noteRunCurrent(_ name: String) {
		guard #available(iOS 16.2, *) else { return }
		Task { @MainActor in
			LiveActivityController.shared.noteRunCurrent(name)
		}
	}

	/// The run is over: its apps are separate jobs again.
	static func releaseRun() {
		guard #available(iOS 16.2, *) else { return }
		Task { @MainActor in
			LiveActivityController.shared.releaseRun()
		}
	}

	static func endOrphans() {
		guard #available(iOS 16.2, *) else { return }
		Task { @MainActor in
			LiveActivityController.shared.endOrphans()
		}
	}

	#if DEBUG
	/// What the system itself says is on screen.
	///
	/// A screenshot of the island and the card's own life are two different
	/// questions, and on a simulator they disagree: the island is drawn by
	/// SpringBoard in its own window, and whether a given capture composites it
	/// is not something this app controls. This answers the other half — whether
	/// the card exists, and whether the system still calls it live — so a blank
	/// frame can be told from a card that has really gone.
	@MainActor
	static func describeCards() -> String {
		guard #available(iOS 16.2, *) else { return "no activitykit" }
		let cards = Activity<DownloadActivityAttributes>.activities
		guard !cards.isEmpty else { return "no cards" }
		return cards
			.map { "\($0.id)=\($0.activityState)" }
			.joined(separator: ", ")
	}
	#endif
}
