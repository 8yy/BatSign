//
//  BSInstallWatcher.swift
//  Feather
//
//  Follows an install hand-off to its end, so the live card can go away the
//  moment the app is really on the device.
//
//  Our own knowledge stops when the install link opens. From there iOS fetches
//  the package from the local server and puts the app on the Home Screen at its
//  own pace, possibly with the user already looking at something else. The only
//  honest signal that the job is over is the device's own answer.
//
//  That answer is not one question. "Is this bundle installed?" is true before,
//  during and after a reinstall — which is how the card used to sit at
//  "Installing" for minutes after an app that was already there had been
//  replaced. So the watcher asks five things and believes the first that says
//  yes:
//
//    1. the bundle was not installed and now is;
//    2. the build on the device is the version this job signed, having not been
//       that version before — a statement about our own build, and the one that
//       does not depend on the system reporting anything at all;
//    3. the bundle on disk was rewritten — a different write at that path;
//    4. an install for this bundle was watched running and has since stopped;
//    5. the system's own install fraction reached the end.
//
//  and it is bounded. When a hand-off plainly goes nowhere the card is ended
//  quietly rather than claiming a result, because a card that outlives its job
//  is worse than no card at all.
//
//  Each of those has to be evidence about *an install this app caused*, which is
//  the hard part: the same device answers questions about a bundle that is simply
//  sitting on the Home Screen. Three answers were being misread that way — the
//  path probe, which returns nothing when the device will not hand over the path
//  (so "no fingerprint" was read as "no app", and a reinstall of an app that was
//  already installed was announced as finished ten milliseconds after the
//  hand-off), an install fraction that was already complete the first time it was
//  seen, and the version, which says nothing at all about the install when it was
//  already that version before the hand-off. None of them is evidence on its own
//  any more.
//
//  Two moments can end it and both are checked: the poll, and the user coming
//  back to the app. A suspended poll cannot strand the card, because returning
//  to the foreground asks the same question again.
//

import Foundation
import UIKit
import os

// MARK: - What the device can be asked

/// The numbers that name a build: the version and the build number its Info.plist
/// carries.
///
/// Both are kept, and compared field by field, because the device does not always
/// report both. Measured on the runtime this app is built against, the system's own
/// registry answers `bundleVersion` — `CFBundleVersion` — and implements no
/// `shortVersionString` at all, so a rule that waited on short versions alone
/// could never once have fired.
struct BuildIdentity: Equatable, Sendable, Codable {
	var version: String?
	var build: String?

	var isEmpty: Bool { version == nil && build == nil }

	/// Whether two identities name the same build.
	///
	/// A field agrees only with itself: a build number is never read as a version,
	/// because two numbers that happen to look alike are not evidence that two
	/// different things are the same. Unknown agrees with nothing, so an answer the
	/// device did not give can never be mistaken for a change.
	func agrees(with other: BuildIdentity) -> Bool {
		if let version, let otherVersion = other.version, version == otherVersion { return true }
		if let build, let otherBuild = other.build, build == otherBuild { return true }
		return false
	}

	var described: String {
		switch (version, build) {
		case let (version?, build?): "\(version) (\(build))"
		case let (version?, nil): version
		case let (nil, build?): build
		case (nil, nil): "unknown"
		}
	}
}

enum BSInstallProbe {
	/// What the device knows about one bundle, read off the main thread because
	/// every one of these calls is synchronous cross-process work.
	struct Reading: Sendable {
		var isInstalled: Bool
		/// The system's install fraction, nil when it is not installing this
		/// bundle at all — which is itself information.
		var fraction: Double?
		/// A fingerprint of the bundle on disk, nil when there is none.
		var stamp: String?
		/// What the device says the build is called — `CFBundleShortVersionString`,
		/// from the system's own registry of what it has installed.
		///
		/// The strongest answer the device can give, because it is about a *build*
		/// and not about a path. A path answers the same for whatever version
		/// happens to be sitting there, and that is why a reinstall could not be
		/// told from a finished install; a version names the build, so "the version
		/// on the device is the one this job signed" is a statement about an install
		/// this app caused and about no other.
		var version: String?
		var build: String?
		/// What the device calls the app, so a job picked up by a later process
		/// can name it in the popup it owes the user.
		var name: String?

		/// The two together, which is what a comparison against another build
		/// actually is.
		var identity: BuildIdentity { BuildIdentity(version: version, build: build) }

		/// Whether the device has a file for this bundle at all.
		var hasBundle: Bool { stamp != nil }

		/// The same reading, in the shape the decision works on.
		var deviceReading: BSAppReading {
			BSAppReading(
				isInRegistry: isInstalled,
				identity: identity,
				path: nil,
				name: name,
				installFraction: fraction,
				registryAnswered: true,
				canTellAbsence: true,
				takenAt: Date()
			)
		}
	}

	static func read(_ identifier: String) -> Reading {
		// One scan, one answer per bundle: the registry, the install object and
		// the write time of the build on disk, all read the same way here as
		// everywhere else in the app. The watcher used to assemble its own
		// reading out of three private calls, which meant the pipeline and the
		// library could describe the same app differently — and a process that
		// had just started could describe it not at all.
		let reading = BSDeviceApps.read(identifier)

		return Reading(
			isInstalled: reading.isInRegistry,
			fraction: reading.installFraction,
			stamp: reading.stamp,
			version: reading.identity.version,
			build: reading.identity.build,
			name: reading.name
		)
	}

	/// The two numbers a build is identified by, read out of the Info.plist inside
	/// a bundle on disk.
	///
	/// Used for both halves of the comparison — what the device has, and what this
	/// job built — so the two answers come from the same place and are read the
	/// same way. A directory that is not a bundle at all answers nothing rather
	/// than guessing, which keeps "unknown" from being read as "different".
	static func identity(of path: String) -> BuildIdentity? {
		guard let bundle = Bundle(path: path) else { return nil }
		return BuildIdentity(
			version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
			build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
		)
	}

	/// What a bundle on disk is called, for the caller that knows where its own
	/// build is sitting. Empty fields are dropped rather than kept as empty
	/// strings, so that a missing version can never be compared as a value.
	static func buildIdentity(at path: String) -> BuildIdentity? {
		guard let identity = identity(of: path) else { return nil }
		let cleaned = BuildIdentity(
			version: identity.version?.isEmpty == false ? identity.version : nil,
			build: identity.build?.isEmpty == false ? identity.build : nil
		)
		return cleaned.isEmpty ? nil : cleaned
	}

	/// A fingerprint that changes when the app on disk is replaced.
	///
	/// One implementation, and it lives with the device reading: the watcher's
	/// baseline, a resumed job's baseline and the scan all compare the same
	/// string, so a rule that fires on one of them fires on all of them.
	enum BundleStamp {
		static func of(_ path: String) -> String { BSDeviceApps.BundleStamp.of(path) }
	}
}

// MARK: - What counts as an install that has happened

/// Everything a landing decision is made from.
///
/// The live watch and a process that has just picked the job up out of the
/// ledger are asking the same question of the same device, so they answer it
/// with the same function. They used to be two code paths with two rule sets,
/// which is how one of them could end a card the other would have called a
/// landing.
struct InstallEvidence: Sendable {
	/// Whether the app was on the device before the hand-off. False makes any
	/// install of it a landing, because there was nothing to replace.
	var wasInstalled: Bool
	/// What the bundle on disk looked like before the hand-off, nil when the
	/// device would not hand over the path. Nil means *unknown*, not *absent*.
	var baselineStamp: String?
	/// The build the device had before the hand-off, empty when it had none.
	var baselineIdentity: BuildIdentity
	/// The build this job signed, read off the bundle it handed over.
	var expected: BuildIdentity
	/// What the device says now.
	var reading: BSAppReading
	/// The system reported an install object for this bundle — which it only
	/// does for a bundle it is installing, never for one that is merely
	/// installed. Means the package was accepted and the dialog was shown.
	var sawProgress: Bool
	/// That install was seen *under way*: a fraction below completion.
	var sawInFlight: Bool
	/// It was also seen at or above completion, which is where a package that
	/// never publishes a moving fraction lands.
	var sawInstallAtEnd: Bool
}

/// How a hand-off stands.
enum InstallVerdict: Equatable {
	/// The app this job signed is on the device, and this is the observation
	/// that says so.
	case landed(String)
	/// The system is installing it. The fraction is its own number.
	case installing(fraction: Double?)
	/// Nothing to conclude yet.
	case waiting

	var landingReason: String? {
		if case let .landed(reason) = self { return reason }
		return nil
	}
}

enum BSInstallVerdict {
	/// Whether the app this job is about is on the device now, having not been
	/// there — or not been *that build* — when the job began.
	///
	/// The rules are the watcher's, unchanged, and they are asked in this order:
	///
	///  1. the bundle was not installed and now is;
	///  2. the build on the device is the version this job signed, having not been
	///     that build before;
	///  3. the bundle on disk was rewritten — a different write at that path;
	///  4. an install for this bundle was watched running and has since stopped;
	///  5. the system's own install fraction, seen under way, is gone.
	///
	/// Each of them has to be evidence about *an install this app caused*, which
	/// is the hard part: the same device answers questions about a bundle that is
	/// simply sitting on the Home Screen. So a build that was already the build
	/// before the hand-off says nothing, an unknown baseline is never read as a
	/// changed one, and the install object is only evidence when it was seen.
	static func decide(_ evidence: InstallEvidence) -> InstallVerdict {
		let reading = evidence.reading

		// Still installing, and that is the more specific truth: during a
		// reinstall the registry still names the build being replaced, so a
		// caller told "installed" would describe a replacement as already done.
		if reading.isInstalling, !reading.isInRegistry {
			return .installing(fraction: reading.installFraction)
		}

		guard reading.isInRegistry else {
			// The device does not have it — which settles nothing, because the
			// install may simply not have reached the registry yet. What it does
			// settle is that no landing can be claimed.
			if reading.isInstalling { return .installing(fraction: reading.installFraction) }
			return .waiting
		}

		if !evidence.wasInstalled {
			// Nothing of this app was on the device, and now it is.
			return .landed("it was not installed and now it is")
		}

		if !evidence.expected.isEmpty,
		   evidence.expected.agrees(with: reading.identity),
		   !evidence.baselineIdentity.agrees(with: reading.identity) {
			// The build on the device is the one this job signed, and it is not
			// the build that was there before. Nothing about this answer depends
			// on the system reporting progress, which is why it is the one that
			// closes a Turbo install: that package lands without ever publishing a
			// fraction, and every progress-shaped test misses it while this one
			// reads the result off the app itself.
			//
			// The baseline has to be *known and different*. A build that matches
			// because it was already that build before the hand-off says nothing
			// at all — that is a reinstall of an app the device already had, and it
			// is left to the fingerprint and the system's own install object below.
			return .landed(
				"the build on the device is the one this job signed "
					+ "(\(evidence.baselineIdentity.described) → \(evidence.expected.described))"
			)
		}

		if let stamp = reading.stamp, let before = evidence.baselineStamp, stamp != before {
			// It was there before, and what is on disk is not what was there.
			//
			// Both halves are required. A stamp the device would not hand over is
			// unknown, and unknown was once read as "no app" — which announced a
			// reinstall of an app already on the device as finished ten
			// milliseconds after the hand-off.
			return .landed("the bundle on disk was rewritten")
		}

		if evidence.sawInFlight, reading.installFraction == nil {
			// An install for this bundle was watched running and has stopped: the
			// system's own answer that the install it was given is over.
			return .landed("the system's install ran and stopped")
		}

		if evidence.sawInstallAtEnd, reading.installFraction == nil {
			// The same answer for the package that never moved a bar: the install
			// object existed, at completion, and is gone.
			return .landed("the system's install object reached the end and went")
		}

		// Still genuinely installing, or still nothing to say.
		if reading.isInstalling { return .installing(fraction: reading.installFraction) }
		return .waiting
	}
}

// MARK: - The watcher

@MainActor
final class BSInstallWatcher {
	static let shared = BSInstallWatcher()

	private static let log = Logger(subsystem: "app.batsign.ios", category: "install")

	private struct Watch {
		let identifier: String
		var name: String
		/// Whether the app was on the device before the hand-off.
		///
		/// False makes any install of it a landing, because there was nothing to
		/// replace. True makes the install a replacement, which needs evidence
		/// that says more than "the app is there" — because it was there all
		/// along, and it still is while the new build is being written.
		let wasInstalled: Bool
		/// What the bundle on disk looked like before the hand-off, nil when the
		/// device would not hand over the path.
		///
		/// Nil means *unknown*, not *absent*. Reading those the same way is how
		/// a reinstall of an app already on the device was announced as finished
		/// ten milliseconds after the hand-off.
		let baseline: String?
		/// The build this job signed, read off the bundle it is about to hand over.
		///
		/// The one answer that survives everything the install does on its way to
		/// the Home Screen. An install that never reports a fraction — a Turbo
		/// package, which spends its time being compressed and then lands in one
		/// quick step — is invisible to every progress-shaped test; the build on the
		/// device afterwards is not, because it now names this one.
		var expected: BuildIdentity
		/// The build the device had before the hand-off, empty when it had none.
		var baselineIdentity: BuildIdentity
		/// The system reported an install object for this bundle, which it only
		/// does for a bundle it is installing — never for one that is merely
		/// installed. Means the package was accepted and the dialog was shown.
		var sawProgress: Bool
		/// That install was seen *under way* — a fraction below completion, not
		/// the complete number a finished app reports.
		var sawInFlight: Bool
		/// An install object was seen for this bundle at or above completion: the
		/// package that never publishes a moving fraction lands here.
		var sawInstallAtEnd: Bool

		/// The same watch, as the thing that is written down.
		///
		/// The watcher's state and the ledger's record are one thing in two
		/// places: this is what a fresh process picks up, so the fields that
		/// decide a landing have to survive the trip.
		var record: BSInstallLedger.Record {
			BSInstallLedger.Record(
				identifier: identifier,
				name: name,
				expected: expected,
				baseline: baselineIdentity,
				baselineStamp: baseline,
				wasInstalled: wasInstalled,
				stage: stage,
				askedAt: askedAt,
				updatedAt: Date(),
				sawProgress: sawProgress,
				sawInFlight: sawInFlight,
				sawInstallAtEnd: sawInstallAtEnd,
				lastProgressAt: nil
			)
		}

		/// A watch picked back up out of the ledger.
		///
		/// The clock is not restarted: a record carries the moment the hand-off
		/// was asked for, and the deadline that follows from it is what stops a
		/// card outliving the job it describes.
		static func resumed(_ record: BSInstallLedger.Record) -> Watch {
			Watch(
				identifier: record.identifier,
				name: record.name,
				wasInstalled: record.wasInstalled,
				baseline: record.baselineStamp,
				expected: record.expected,
				baselineIdentity: record.baseline,
				sawProgress: record.sawProgress,
				sawInFlight: record.sawInFlight,
				sawInstallAtEnd: record.sawInstallAtEnd,
				stage: record.stage,
				askedAt: record.askedAt,
				isResumed: true
			)
		}

		/// How far the hand-off has got: prepared, or actually given to the
		/// system. Only the second can be the cause of an install.
		var stage: BSInstallLedger.Stage = .armed
		/// When the hand-off was asked for. Survives a restart; for a watch taken
		/// in this process it is the moment it was armed.
		var askedAt: Date = Date()
		/// Picked up from the ledger by a process that did not start it.
		var isResumed = false
	}

	private var current: Watch?
	private var task: Task<Void, Never>?
	/// The 2.5-second settle after an install's own progress object reaches its
	/// end. Lives beside the poll loop because it ends the same watch the loop
	/// would — just sooner, once there is nothing left to follow.
	private var settleTask: Task<Void, Never>?
	/// A reconcile is already reading the device and settling the books. See
	/// `resume`, which is where two passes at once are refused.
	private var isReconciling = false

	/// How long a single job may be followed.
	///
	/// A hand-off's clock is not the app's. The user may be mid-sentence in
	/// another app when the dialog appears, and installd may then fetch a large
	/// package over a slow link. Ten minutes is the span the installer retention
	/// in `AutoSignManager` already allows, and the watcher runs slightly past
	/// it so the card outlives the server rather than the reverse.
	private let deadline: TimeInterval = 660

	/// How often the device is asked.
	///
	/// One cross-process read a second. Faster polling bought the card a
	/// quicker exit after a landing and nothing else, at the cost of four reads
	/// a second for ten minutes; a landing is noticed within a second either
	/// way, which is well under the threshold an eye can detect.
	private let interval: UInt64 = 1_000_000_000

	/// How often the device is asked while the system is visibly installing.
	///
	/// Twice a second, and only for as long as `sawInFlight` holds — the state
	/// the polls themselves establish, meaning the system was seen copying this
	/// bundle into place. That window is the one where a second of lag is
	/// visible to the user: the icon is already appearing on the Home Screen and
	/// the card is still saying "Installing…", which is the whole of the
	/// complaint. It is bounded by the install itself — seconds, not minutes —
	/// so the cost the note above is about is not paid for the idle ten.
	private let installingInterval: UInt64 = 500_000_000

	/// The gap before the next read: half a second while an install is in
	/// flight, one second otherwise.
	private var pollGap: UInt64 {
		current?.sawInFlight == true ? installingInterval : interval
	}

	/// When the hand-off is offered again, in polls — one a second.
	///
	/// Used only while nothing at all has come back from the system: no install
	/// object, no progress, nothing. That is what a hand-off the system would
	/// not take looks like, and asking again is the only lever there is — the
	/// moment the system does accept it, the dialog appears on top of whatever
	/// the user is looking at.
	///
	/// The offers back off over *minutes*, because a person who has just seen a
	/// dialog arrive over another app does not act within seconds: they finish
	/// the sentence they were reading, then they tap. The old schedule gave up
	/// entirely after twenty-four seconds — which is to say, while the user was
	/// still reading the dialog — and every give-up was followed by the process
	/// being suspended on the next app switch, the card going stale, and the
	/// system labelling the install Interrupted while it waited for a tap that
	/// was still welcome.
	private let offerAtPolls = [15, 45, 90, 150, 240]

	/// The poll at which the offers are declared unanswered.
	///
	/// Six minutes. Late enough that a dialog someone saw on the way to
	/// something else has had a fair chance to be tapped; early enough that the
	/// "tap to finish" notification arrives while the waiting user still wants
	/// it. Nothing is thrown away at this point — the package, the server and
	/// the installer all stand, and the holds stay up until the watcher's own
	/// deadline — so the tap that finishes it still lands immediately.
	private let stallAtPoll = 360

	private init() {}

	/// Whether a hand-off is still being followed. False means it landed, or it
	/// ran out of time, or it was cancelled — in all three cases the job it
	/// describes is over.
	var isFollowing: Bool { current != nil }

	/// Whether the system has said anything at all about this install.
	///
	/// The difference between "the confirmation was shown and the install is
	/// under way" and "the confirmation was never shown" — and it is the only
	/// way to tell, because an app is not told whether its request to open an
	/// install link was accepted. False means offering it again is worth doing;
	/// true means a second offer would be a second prompt for an app that is
	/// already arriving.
	var hasSeenSystemProgress: Bool { current?.sawProgress ?? false }

	// MARK: - Arm and follow

	/// Remember what the device has *before* the hand-off.
	///
	/// Called at the top of the install, because by the time the system reports
	/// anything the old app may already be gone and there is nothing left to
	/// compare against.
	///
	/// `expecting` is what this job built, and it is kept beside the baseline: the
	/// two together are what turn "the build on the device" into a statement about
	/// *this* install, which is the only reading of it worth having.
	///
	/// The watch is written down here as well as held, and the moment it is taken
	/// is the moment the clock starts. If the process does not live to see the
	/// end of this install, the record is what a later one reads — so it is
	/// written before the hand-off rather than after it, because the hand-off is
	/// exactly the part that can be cut short.
	func arm(_ identifier: String, expecting: BuildIdentity? = nil, name: String = "") {
		guard !identifier.isEmpty else { return }
		let before = baseline(identifier)
		let watch = Watch(
			identifier: identifier,
			name: name,
			wasInstalled: before.wasInstalled,
			baseline: before.stamp,
			expected: expecting ?? .init(version: nil, build: nil),
			baselineIdentity: before.identity,
			sawProgress: false,
			sawInFlight: false,
			sawInstallAtEnd: false
		)
		current = watch
		// A new hand-off for this app is a new question, and its landing is news
		// again: the previous install's announcement must not silence this one.
		BSInstallLedger.forgetReported(identifier)
		BSInstallLedger.put(watch.record)
	}

	/// Start following the hand-off.
	func follow(_ identifier: String, name: String, expecting: BuildIdentity? = nil) {
		guard !identifier.isEmpty else { return }

		// A follow with no arm — the notification path, where the user's tap is
		// the first we hear of it — takes its baseline now. That is still
		// before the install, so it is still a baseline. Its build comes from
		// the same place, and for the same reason.
		if current?.identifier != identifier {
			// A hand-off that is starting now, whatever was said about an earlier
			// install of the same app.
			BSInstallLedger.forgetReported(identifier)
			let before = baseline(identifier)
			current = Watch(
				identifier: identifier,
				name: name,
				wasInstalled: before.wasInstalled,
				baseline: before.stamp,
				expected: expecting ?? .init(version: nil, build: nil),
				baselineIdentity: before.identity,
				sawProgress: false,
				sawInFlight: false,
				sawInstallAtEnd: false
			)
		} else {
			current?.name = name
			// The armed watch may have been taken before the package existed; the
			// caller here has just built it, and what it built is the better answer.
			if let expecting, !expecting.isEmpty { current?.expected = expecting }
		}

		// The install link has been opened: from here the system may be installing
		// this app, and this is the record that says a job is out there which
		// nobody's memory holds.
		current?.stage = .handedOff
		if let watch = current { BSInstallLedger.put(watch.record) }

		// Hold the process up for as long as the hand-off lasts.
			//
		// iOS fetches the manifest and then the package from the local server
		// after the user has confirmed, which is usually after they have left for
		// another app. Suspended in the middle of that fetch and the install
		// fails — the server stops answering, installd gives up, and the user
		// sees an app that never arrives. This hold is what keeps the server
		// answering on the Home Screen, and it is released when the app lands.
		BSJobKeepAlive.shared.begin(BSJobKeepAlive.Reason.landing)

		start()
	}


	/// The user is back in the app. The install may well have finished while the
	/// process was suspended and the poll never got to see it, so the same
	/// question is asked once more, on the spot — and the card is re-asserted
	/// only when the answer is silence.
	///
	/// The old order was the wrong one: a generic "Installing…" was pushed
	/// first, from memory, and the poll came after. Every return to the app
	/// therefore flashed "Installing…" once more — including for a job the
	/// phone had already finished, which is the notification the user reads
	/// again and again. The poll now speaks first: it lands the job, or paints
	/// the system's own fraction, and only when it has nothing to say is the
	/// card given back its words, so the island cannot claim more than this
	/// process knows.
	func recheck() {
		guard let watch = current else { return }
		Task { [weak self] in
			guard let self else { return }
			let answer = await self.assess(watch)
			if let reason = answer.landing {
				self.land(watch, reason: reason)
				return
			}
			guard self.current?.identifier == watch.identifier else { return }
			guard !answer.refreshed else { return }
			LiveStatus.ensure(
				appID: watch.identifier,
				appName: watch.name.isEmpty ? "App" : watch.name,
				phase: .installing,
				detail: "Installing…",
				mode: AutoSignManager.installMode
			)
		}
	}

	/// The job failed or was abandoned. Nothing to follow any more.
	func cancel(_ identifier: String? = nil) {
		if let identifier, current?.identifier != identifier { return }
		task?.cancel()
		task = nil
		settleTask?.cancel()
		settleTask = nil
		if let identifier {
			// The watch for this app is over without a landing. Its pending-
			// install cards are as stale as a landed one's — more so: the job
			// they offer to finish is gone.
			AutoUpdateManager.shared.removeInstallNotifications(for: identifier)
			// And so is the record: a job that was abandoned is not a question
			// anybody is still waiting on an answer to.
			BSInstallLedger.clear(identifier)
		} else if let watch = current {
			BSInstallLedger.clear(watch.identifier)
		}
		current = nil
		release()
	}

	/// The app was deleted from the Library. That is the end of its job, no
	/// matter what the pipeline is doing with it.
	///
	/// Deleting a Library row used to leave everything about that app armed:
	/// the ledger record survived, so the next launch revived a watch for a
	/// bundle the user had just told the app to forget, and the card went on
	/// saying "Installing…" for an install nobody wanted any more — the exact
	/// shape of "it says installing again even when I removed the app". Every
	/// channel that could speak for that bundle is silenced here, in one place,
	/// so the three deletion sites cannot drift apart in what they forget.
	func retireFromLibrary(_ identifier: String) {
		Self.log.notice("install: \(identifier, privacy: .public) was deleted from the Library — the job is over")
		if current?.identifier == identifier {
			task?.cancel()
			task = nil
			settleTask?.cancel()
			settleTask = nil
			current = nil
		}
		BSInstallLedger.clear(identifier)
		// The next install of this app is new news, even of the same build: the
		// user deleted it on purpose, and the popup they are owed next time is
		// not a repeat of anything they decided to end.
		BSInstallLedger.forgetReported(identifier)
		AutoUpdateManager.shared.removeInstallNotifications(for: identifier)
		LiveStatus.end(appID: identifier)
		release()
	}

	#if DEBUG
	/// A rehearsal of the settle: arm a watch by hand and start the 2.5-second
	/// exit, so the vanish the user asked for can be watched on a simulator —
	/// which has no install object to trigger the real path.
	func debugSettle(_ identifier: String, name: String = "SettleTest") {
		current = Watch(
			identifier: identifier,
			name: name,
			wasInstalled: false,
			baseline: nil,
			expected: .init(version: nil, build: nil),
			baselineIdentity: .init(version: nil, build: nil),
			sawProgress: true,
			sawInFlight: true,
			sawInstallAtEnd: false
		)
		BSInstallLedger.put(current!.record)
		BSJobKeepAlive.shared.begin(BSJobKeepAlive.Reason.landing)
		LiveStatus.ensure(
			appID: identifier,
			appName: name,
			phase: .installing,
			detail: "Finishing…",
			mode: AutoSignManager.installMode
		)
		_scheduleInstallEnd(identifier)
	}
	#endif

	// MARK: - Internals

	/// The end of an install, on the install's own word.
	///
	/// Armed the moment the system's progress object reports 100%. The registry
	/// gets 2.5 seconds — the same hold the finale uses — to name the app; a
	/// landing decided inside that window plays out normally, with its popup.
	/// When the window closes with no confirmation, the card has said all it
	/// can say truthfully and it goes: 100%, two and a half seconds, gone —
	/// which is the behaviour the user asked for, and the end of the long hold
	/// that let the system reap the background grant as a failure ("Task
	/// failed", on a surface this app cannot clear). The record stays on the
	/// books as an open question, so a landing the registry confirms later is
	/// still reported by the settle path rather than lost with the card.
	private func _scheduleInstallEnd(_ identifier: String) {
		settleTask?.cancel()
		settleTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 2_500_000_000)
			guard !Task.isCancelled, let self,
			      let watch = self.current, watch.identifier == identifier else { return }

			Self.log.notice(
				"install: \(identifier, privacy: .public) reached the end of its install — the card goes after its 2.5 seconds"
			)
			LiveStatus.end(appID: identifier)
			// The question stays open: a landing the registry names later is
			// still news, and the settle path is where it will be told.
			BSInstallLedger.hold(identifier)
			self.task?.cancel()
			self.task = nil
			self.settleTask = nil
			self.current = nil
			self.release()
		}
	}

	private func start() {
		task?.cancel()
		task = Task { [weak self] in
			guard let self else { return }
			// The clock starts when the hand-off was asked for, not when this
			// loop began. A watch picked up out of the ledger has been running
			// for as long as the record is old, and restarting its clock here
			// would let a card outlive the job it describes by a second full
			// deadline — the one thing this file exists to prevent.
			let askedAt = self.current?.askedAt ?? Date()
			let expiry = askedAt.addingTimeInterval(self.deadline)
			var polls = 0
			var offers = 0

			while !Task.isCancelled, Date() < expiry {
				guard let watch = self.current else { return }
				if let reason = await self.hasLanded(watch) {
					self.land(watch, reason: reason)
					return
				}

				polls += 1

				// Nothing has come back at all: the hand-off was never shown, so
				// the manager is asked to offer it again while this process is
				// still up — and, when the offers run out, told to stop and say
				// where the install is instead.
				//
				// Only for a watch this process actually asked for. A resumed
				// watch's hand-off was made by the process that is gone: there is
				// nothing here to offer again, and a second offer staged from a
				// fresh process would be a second confirmation for an install the
				// user has already seen once.
				if self.current?.sawProgress == false, self.current?.isResumed != true {
					if offers < self.offerAtPolls.count, polls >= self.offerAtPolls[offers] {
						offers += 1
						NotificationCenter.default.post(
							name: Notification.Name("BatSign.retryInstallHandOff"),
							object: nil
						)
					} else if offers == self.offerAtPolls.count, polls >= self.stallAtPoll {
						offers += 1
						NotificationCenter.default.post(
							name: Notification.Name("BatSign.installHandOffStalled"),
							object: nil
						)
					}
				}

				try? await Task.sleep(nanoseconds: self.pollGap)
			}

			// Ran out of patience. The job may still be going — a very slow
			// tunnel, a user who never tapped — but the card has stopped being
			// true, so it goes without claiming an outcome.
			guard !Task.isCancelled, let watch = self.current else { return }

			// One last look, taken on the way out. The loop above asked the same
			// question a second ago, and an install that landed inside that second
			// — which is exactly when a slow Turbo package finishes, right at the
			// end of a long wait — would otherwise end as no news at all: the card
			// would vanish instead of saying "Installed", and the popup that is the
			// whole point of the job would never arrive.
			if let reason = await self.hasLanded(watch) {
				self.land(watch, reason: "\(reason), at the end of the wait")
				return
			}

			LiveStatus.end(appID: watch.identifier)
			// The clock ran out and the question was never answered. The card goes,
			// but the record stays on the books as an open question: an install this
			// slow can still land after the last poll, and the difference between
			// "we stopped watching" and "we no longer know" is exactly what the
			// user is complaining about. A later launch answers it from the phone.
			BSInstallLedger.hold(watch.identifier)
			self.current = nil
			self.task = nil
			self.release()
		}
	}

	// MARK: - Picking a job back up

	/// Finish what the ledger describes, from whatever process is running.
	///
	/// Called at launch and on every return to the foreground, before anything is
	/// swept away. A hand-off whose process died leaves a record, a card on the
	/// Lock Screen saying "Installing", and nobody who knows what either was
	/// waiting for — and the sweep that used to run here took the card down
	/// without ever asking whether the app had arrived. It asks now.
	///
	/// `completion` runs after the device has been read and every record settled,
	/// which is what lets the caller sweep the cards that are left over *after*
	/// the ones that can still be explained have been.
	func resume(completion: ((Set<String>) -> Void)? = nil) {
		let now = Date()
		let held = current?.identifier
		// A watch alive in this process is strictly better informed than a
		// record: it has been polling, and it is the one that will land the job.
		let records = BSInstallLedger.records.filter { $0.identifier != held }

		// One pass at a time. Launch and a return to the foreground both reconcile,
		// and a second pass that reads the books while the first is still deciding
		// settles the same hand-offs — which is how one install produced two popups.
		guard !isReconciling else {
			completion?([])
			return
		}
		isReconciling = true

		// The device is read even when the books are empty. A hand-off is not the
		// only way an app arrives: the case this exists for is the one where nothing
		// was written down at all, and a pass that skipped the phone whenever there
		// were no records would never see it — which is the user's complaint, in one
		// line of control flow.
		Task { [weak self] in
			guard let self else { return }
			let snapshot = await Task.detached(priority: .utility) {
				BSDeviceApps.snapshot()
			}.value

			// Which landings the books have already answered. The scan that runs
			// next looks at the same phone and would find the same arrival, and the
			// user must not be told twice — one popup, one timeline line, one card.
			var reported: Set<String> = []
			for record in records {
				if let identifier = self.settle(record, using: snapshot, now: now) {
					reported.insert(identifier)
				}
			}
			self.isReconciling = false
			completion?(reported)
		}
	}

	/// Ask the device about every hand-off on the books, then sweep whatever is
	/// left over.
	///
	/// The order is the point. Every record the ledger can still explain is
	/// settled first — including the cards that are about to be finished *with a
	/// result*, which is the news a user who locked their screen mid-install
	/// never got — then the phone itself is scanned for installs nobody has a
	/// record of, and only then is anything taken down for being unexplainable.
	/// Sweeping first is what used to delete the evidence: a card left by a killed
	/// run was ended on launch without anyone asking whether the app had arrived,
	/// so an install that landed while BatSign was dead was never reported at all.
	func reconcile() {
		resume { [weak self] reported in
			guard let self else { return }
			Task { [weak self] in
				guard let self else { return }
				await self._reportLandingsNobodyFollowed(alreadyReported: reported)
				LiveStatus.endOrphans()
			}
		}
	}

	/// One record, against one reading of the device.
	///
	/// Three endings and each one is the device's own answer — the install
	/// landed, the system is installing it, or nothing is happening. The return
	/// value is the bundle whose landing was reported here, so the scan that runs
	/// after this cannot report the same arrival a second time.
	private func settle(
		_ record: BSInstallLedger.Record,
		using snapshot: BSDeviceApps.Snapshot,
		now: Date
	) -> String? {
		let reading = BSDeviceApps.read(record.identifier, using: snapshot)
		let name = record.name.isEmpty ? (reading.name ?? Self._nameFromIdentifier(record.identifier)) : record.name

		let verdict = BSInstallVerdict.decide(
			InstallEvidence(
				wasInstalled: record.wasInstalled,
				baselineStamp: record.baselineStamp,
				baselineIdentity: record.baseline,
				expected: record.expected,
				reading: reading,
				sawProgress: record.sawProgress,
				sawInFlight: record.sawInFlight,
				sawInstallAtEnd: record.sawInstallAtEnd
			)
		)

		// An open question rather than a watched one: the card is already down and
		// nothing here is holding a process up for this job. All that is left to do
		// is settle it — and only a landing is worth telling the user about.
		if record.stage == .awaiting {
			guard now.timeIntervalSince(record.askedAt) <= BSInstallLedger.reportWindow else {
				// Old enough that the news would be about yesterday. The record has
				// done its job by keeping the question open this long; it goes now
				// rather than being answered by a build that is no longer the point.
				BSInstallLedger.clear(record.identifier)
				return nil
			}

			switch verdict {
			case let .landed(reason):
				// The install the user was owed, reported long after the fact. The
				// process that would have said so at the time is gone; this is the
				// next one noticing it on the phone.
				Self.log.notice(
					"install: \(record.identifier, privacy: .public) landed after the card went — \(reason, privacy: .public)"
				)
			_reportLanding(
				identifier: record.identifier,
				name: name,
				reason: reason,
				announce: true,
				build: reading.identity.build
			)
			return record.identifier


			case let .installing(fraction):
				// The system is installing it right now, and this process is in the
				// foreground to see it: the card goes back up and the job is followed
				// to its end properly.
				//
				// Only while the same clock the live watcher obeys still allows it.
				// The card was taken down because the job outlasted its deadline or
				// the system went quiet — and a dead install object can keep
				// answering "installing" long after nothing is moving. Reviving the
				// card from it anyway is what painted "Installing…" again on every
				// launch: each revival ran a fresh watch, each watch refreshed the
				// progress stamp, and each stamp made the next revival look alive.
				// Past the deadline the honest answer is "we no longer know", not
				// "still installing"; a landing that really happens later is still
				// reported by the landed case above, on the phone's own word.
				guard !BSInstallLedger.isExpired(record, at: now) else {
					Self.log.notice(
						"install: \(record.identifier, privacy: .public) is past its deadline while the system still claims to be installing it — the claim is stale, the card stays down"
					)
					BSInstallLedger.clear(record.identifier)
					LiveStatus.end(appID: record.identifier)
					release()
					return nil
				}
				Self.log.notice(
					"install: picked \(record.identifier, privacy: .public) back up from the books — the system is installing it (\(String(format: "%.2f", fraction ?? 0), privacy: .public))"
				)
				var revived = record
				revived.stage = .handedOff
				BSInstallLedger.put(revived)
				current = Watch.resumed(revived)
				BSJobKeepAlive.shared.begin(BSJobKeepAlive.Reason.landing)
				LiveStatus.update(
					phase: .installing,
					appName: name,
					progress: fraction ?? 0,
					detail: fraction == nil ? "Finishing…" : "Installing…",
					appID: record.identifier,
					mode: AutoSignManager.installMode
				)
				start()
				if let fraction, fraction >= 0.99 { self._scheduleInstallEnd(record.identifier) }

			case .waiting:
				// Nothing on the device and nothing following: nothing to do and
				// nothing to show. The record stays until it is answered or ages out.
				break
			}
			return nil
		}

		switch verdict {
		case let .landed(reason):
			// It landed while nobody was watching. The news was owed when it
			// happened and the process that would have sent it is gone, so it
			// arrives now — the card, the timeline line and the popup together,
			// exactly as the watcher would have sent them.
			Self.log.notice(
				"install: landed while nobody was watching \(record.identifier, privacy: .public) — \(reason, privacy: .public)"
			)
			_reportLanding(
				identifier: record.identifier,
				name: name,
				reason: reason,
				announce: true,
				build: reading.identity.build
			)
			return record.identifier

		case let .installing(fraction):
			guard !BSInstallLedger.isExpired(record, at: now) else {
				// Past the deadline as well as installing. The clock wins: a card
				// that outlives the span the installer was retained for describes
				// work nobody is serving any more.
				Self.log.notice("install: \(record.identifier, privacy: .public) is past its deadline — the card goes")
				BSInstallLedger.clear(record.identifier)
				LiveStatus.end(appID: record.identifier)
				release()
				return nil
			}

			// The system is working on it right now, so this process takes the
			// job over and follows it to the end.
			Self.log.notice(
				"install: picked \(record.identifier, privacy: .public) back up — the system is installing it (\(String(format: "%.2f", fraction ?? 0), privacy: .public))"
			)
			current = Watch.resumed(record)
			BSJobKeepAlive.shared.begin(BSJobKeepAlive.Reason.landing)
			LiveStatus.update(
				phase: .installing,
				appName: name,
				progress: fraction ?? 0,
				detail: fraction == nil ? "Finishing…" : "Installing…",
				appID: record.identifier,
				mode: AutoSignManager.installMode
			)
			start()
				if let fraction, fraction >= 0.99 { self._scheduleInstallEnd(record.identifier) }

		case .waiting:
			// Nothing on the device: not installed, and no install object. Either
			// the fetch has not begun or it never will — and this process has no
			// server and no staged package, so it cannot begin one now. Time is
			// the only thing that can tell those apart.
			let silence = record.lastProgressAt ?? record.askedAt
			let quiet = now.timeIntervalSince(silence)

			guard record.stage == .handedOff,
			      quiet < BSInstallLedger.silence,
			      !BSInstallLedger.isExpired(record, at: now) else {
				// Nothing was handed over, or the window has closed. The card goes
				// without claiming an outcome, because there is no outcome to
				// claim: an install that never reached the device is not a landing
				// and it is not a failure the user was told about either.
				Self.log.notice(
					"install: gave up watching \(record.identifier, privacy: .public) — \(Int(quiet), privacy: .public)s since the hand-off, nothing on the device yet"
				)
				// The card goes and the question stays open. An install that has not
				// begun after this long may never begin, but "may" is not "did not":
				// the phone is asked again on the next launch, and it is the phone's
				// answer that decides, not this process's patience.
				BSInstallLedger.hold(record.identifier, at: now)
				LiveStatus.end(appID: record.identifier)
				release()
				return nil
			}

			// Still inside the fetch window. Keep following, so an install that
			// does begin is followed to its end by this process rather than
			// abandoned twice.
			Self.log.notice(
				"install: still waiting on \(record.identifier, privacy: .public) — \(Int(quiet), privacy: .public)s since the hand-off"
			)
			current = Watch.resumed(record)
			BSJobKeepAlive.shared.begin(BSJobKeepAlive.Reason.landing)
			LiveStatus.ensure(
				appID: record.identifier,
				appName: name,
				phase: .installing,
				detail: "Installing…",
				mode: AutoSignManager.installMode
			)
			start()
		}

		// Either the job is being followed now, or there was nothing to do: no
		// landing was reported here, so nothing is held back from the scan.
		return nil
	}

	/// The news a landing owes the user, delivered the one way it is ever
	/// delivered: the card finishes with a result, the timeline gets its line, and
	/// the popup goes out.
	///
	/// Extracted because three different processes can now conclude the same
	/// install — the live watch, a process that picked the job up out of the books,
	/// and the scan that notices an app arriving with nobody behind it at all. They
	/// must not drift apart in what they say, and a landing reported twice is as
	/// wrong as one never reported.
	private func _reportLanding(
		identifier: String,
		name: String,
		reason: String,
		announce: Bool,
		build: String? = nil
	) {
		// One install, one telling — whichever of the ways that can conclude it gets
		// there first. Without this, a launch and a return to the foreground that
		// both reconcile reach the same record, and the user gets the same popup,
		// timeline line and card finish twice.
		//
		// The build goes with it so this stays a guard against *repeats* and not
		// against the news: an app that arrives again as a different build is an
		// arrival the user has not been told about yet.
		guard !BSInstallLedger.hasBeenReported(identifier, build: build) else {
			BSInstallLedger.clear(identifier)
			Self.log.notice(
				"install: \(identifier, privacy: .public) was already reported — not saying it twice"
			)
			return
		}
		BSInstallLedger.noteReported(identifier, build: build)

		// The phone's own memory of the app advances too, so the scan that runs
		// on the next launch cannot find this same arrival and tell it again.
		BSHomeRegistry.noteLanding(identifier: identifier, name: name)

		Self.log.notice(
			"install: landing reported for \(identifier, privacy: .public) — \(reason, privacy: .public)"
		)
		BSInstallLedger.clear(identifier)
		// A landing ends every offer to finish this app's install: cards asking the
		// user to confirm an install that has already happened are worse than none.
		AutoUpdateManager.shared.removeInstallNotifications(for: identifier)
		ActivityLog.shared.log(.installed, app: name, detail: "Installed on this iPhone")
		// The card is finished by identifier, so a card that belongs to another job
		// — or to a later install of the same app — is left alone.
		LiveStatus.finish(
			success: true,
			appName: name,
			detail: "Installed on this iPhone",
			appID: identifier
		)
		// And whatever card the finale above could not reach — a card whose
		// identifier drifted, one left by a killed run that this landing is the
		// first word about — is swept now rather than at the next launch. The
		// user just watched the app appear on the Home Screen; the island must
		// empty in the same breath, not hold its last words until tomorrow's
		// foreground.
		LiveStatus.endOrphans()
		guard announce else { return }
		// The last step is the one that touches the screen: the in-app alert reads
		// the app's state and walks to its top view controller, and none of the
		// three ways an install can be concluded runs on the main thread. The news
		// is handed over rather than presented from wherever it was decided.
		Task { @MainActor in
			AutoSignManager.shared.announceInstallLanded(name: name, identifier: identifier)
		}
	}

	/// Installs that landed with nobody behind them, found by scanning the phone.
	///
	/// The last line of defence, and the one that answers the user's complaint
	/// literally: the app was downloaded and installed from the Home Screen and
	/// "the signer doesn't even know". Every other path here needs a process to
	/// have been alive and following; this one needs only that the phone was looked
	/// at, and it works from a phone that was locked, an app that was killed, and a
	/// job whose record was dropped before it began.
	private func _reportLandingsNobodyFollowed(alreadyReported: Set<String> = []) async {
		let snapshot = await Task.detached(priority: .utility) {
			BSDeviceApps.snapshot()
		}.value

		let landings = BSHomeRegistry.landings(using: snapshot)
		guard !landings.isEmpty else { return }

		// What this app has signed is what it may claim: an app from the App Store
		// is exactly as new to this scan as one installed from a source.
		let signed = await MainActor.run { Storage.shared.signedAppsByIdentifier() }
		let ours = landings.filter { BSHomeRegistry.isOurs($0, signed: signed) }
		guard !ours.isEmpty else { return }

		for landing in ours {
			// A landing the books have just answered is already reported: the same
			// arrival seen twice is two popups and two timeline lines for one
			// install.
			guard !alreadyReported.contains(landing.identifier) else { continue }

			// A hand-off still on the books is settled by the record, which knows
			// more than the scan does — the build it expected and what the device
			// had before. This is only for the installs nobody has a record of.
			guard BSInstallLedger.record(for: landing.identifier) == nil else { continue }

			let name = landing.name ?? Self._nameFromIdentifier(landing.identifier)
			let how = landing.isNew ? "was not on the phone" : "build changed on the phone"
			_reportLanding(
				identifier: landing.identifier,
				name: name,
				reason: "the scan of the phone says it \(how)",
				announce: true,
				build: landing.current.build
			)
		}
	}

	/// A name for an app nobody wrote down: its bundle id's last part, which is
	/// wrong for a company and better than "App" for a person.
	private static func _nameFromIdentifier(_ identifier: String) -> String {
		let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
		return last.isEmpty ? "App" : last
	}

	/// Whether the app this watch is about is on the device now, having not been
	/// there — or not been *that build* — when the watch began.
	///
	/// The answer comes back with its reason, so a landing can always be traced
	/// to the observation that produced it. The judgement itself is not made
	/// here: it is `BSInstallVerdict.decide`, which is the same function a
	/// process that picked this job up out of the ledger calls. Two rule sets for
	/// one question is how the live watch and the resumed one could disagree
	/// about whether an app had landed.
	private func hasLanded(_ watch: Watch) async -> String? {
		await assess(watch).landing
	}

	/// One poll of the device, with the answer in full.
	///
	/// `landing` is the reason the job is over; `refreshed` says whether this
	/// poll already spoke to the card — either the landing is handled by the
	/// caller, or the poll painted the system's own number. The caller that
	/// re-asserts the card after this must know the difference: pushing a
	/// generic "Installing…" over a fraction this very poll just measured is
	/// how the island showed the same stale sentence on every return to the
	/// app while the job was in fact moving.
	private func assess(_ watch: Watch) async -> (landing: String?, refreshed: Bool) {
		let identifier = watch.identifier
		// Read off the main thread: every one of these calls is synchronous
		// cross-process work.
		let reading = await Task.detached(priority: .utility) {
			BSDeviceApps.read(identifier)
		}.value

		// Written through `current`, not through a copy of it: a copy of an
		// optional struct is a value, and these flags are what the next poll and
		// the notification path read back. The same observations go to the ledger,
		// so a process that dies between two polls leaves the most it knew behind:
		// "the system took this install" is the one thing a later process cannot
		// work out for itself.
		let isCurrent = current?.identifier == identifier
		if isCurrent, let fraction = reading.installFraction {
			let isNew = !(current?.sawProgress ?? false)
				|| (fraction < 0.99 && !(current?.sawInFlight ?? false))
				|| (fraction >= 0.99 && !(current?.sawInstallAtEnd ?? false))
			current?.sawProgress = true
			if fraction < 0.99 {
				current?.sawInFlight = true
			} else {
				let firstEnd = !(current?.sawInstallAtEnd ?? false)
				current?.sawInstallAtEnd = true
				// The install's own progress object has reached its end. The card
				// gets 2.5 seconds — the finale's hold — for the registry to name
				// the app, and if it has not by then, the card goes anyway: this
				// is the "100%, two and a half seconds, gone" the user asked for,
				// and it is also what keeps the background grant from being held
				// for minutes on an install that will never confirm — the long
				// hold was the reaped grant, the one the system reports as
				// "Task failed" on a surface this app cannot clear.
				if firstEnd {
					_scheduleInstallEnd(identifier)
				}
			}
			BSInstallLedger.noteProgress(identifier, fraction: fraction, isNew: isNew)
		}

		// Decide whether the job is over BEFORE painting anything. The order
		// here is the difference between a card that ends itself and one that
		// hangs at 100% for ever: "landed" ends the card with a system-side
		// dismissal in the same breath, so the process can be suspended the
		// very next instant without stranding anything. Painting a cosmetic
		// "Finishing… 100%" first — as this used to do — left a card at 100%
		// whenever iOS suspended the process inside the one-second gap before
		// the landing was noticed, which is precisely when an install usually
		// completes: with the user somewhere else.
		let verdict = BSInstallVerdict.decide(
			InstallEvidence(
				wasInstalled: watch.wasInstalled,
				baselineStamp: watch.baseline,
				baselineIdentity: watch.baselineIdentity,
				expected: watch.expected,
				reading: reading,
				sawProgress: current?.sawProgress ?? watch.sawProgress,
				sawInFlight: current?.sawInFlight ?? watch.sawInFlight,
				sawInstallAtEnd: current?.sawInstallAtEnd ?? watch.sawInstallAtEnd
			)
		)

		if let reason = verdict.landingReason { return (reason, false) }

		guard isCurrent else { return (nil, false) }
		let name = watch.name.isEmpty ? "App" : watch.name

		if case let .installing(fraction) = verdict {
			// Still genuinely installing: paint the system's own number. This poll
			// is the one place the true fraction exists — without it the card kept
			// the 0% it started with for the whole install, and a user who switched
			// apps read a moving job as a stalled one.
			LiveStatus.update(
				phase: .installing,
				appName: name,
				progress: fraction ?? 1,
				detail: fraction == nil ? "Finishing…" : "Installing…",
				appID: identifier,
				mode: AutoSignManager.installMode
			)
			// A nil fraction painted as 1 is still the end of the install — the
			// settle must not depend on which shape the evidence took. Armed once
			// under the timer's own existence, so repeating polls cannot postpone
			// the exit.
			if (fraction ?? 1) >= 0.99, settleTask == nil {
				_scheduleInstallEnd(identifier)
			}
			return (nil, true)
		} else if current?.sawInFlight == true {
			// An install that was under way and is no longer reporting itself, for
			// a bundle the registry has not named yet. On the device this is how
			// an install *ends*: the system removes the progress object the
			// moment the work is done, and the registry — a private read — may
			// never confirm the app. The card cannot wait on that confirmation:
			// the 2.5-second settle starts here, exactly as it does when the
			// fraction itself reaches the end. Armed once — the timer's own
			// existence is the guard, so a poll that runs again cannot postpone
			// it forever.
			LiveStatus.update(
				phase: .installing,
				appName: name,
				progress: 1,
				detail: "Finishing…",
				appID: identifier,
				mode: AutoSignManager.installMode
			)
			if settleTask == nil { _scheduleInstallEnd(identifier) }
			return (nil, true)
		}

		return (nil, false)
	}

	/// The install arrived. Everything the job promised the user is delivered here
	/// and nowhere else, so that one call is the whole of "it is done": the card
	/// ends with a result, the timeline gets its line, and the popup — the thing
	/// the user actually waits for — is posted.
	///
	/// The record goes before any of it. If this process is suspended halfway
	/// through these calls, the next one must not read a finished install off the
	/// books and announce it a second time.
	private func land(_ watch: Watch, reason: String) {
		task?.cancel()
		task = nil
		// The landing won the race with the settle timer; the timer's work —
		// ending the card and holding the record — is exactly what a landing
		// must not run after.
		settleTask?.cancel()
		settleTask = nil
		Self.log.notice(
			"install: landed for \(watch.identifier, privacy: .public) — \(reason, privacy: .public)"
		)
		current = nil

		let name = watch.name.isEmpty ? "App" : watch.name

		// The same announcement every other way of concluding an install makes, from
		// the same place: the card, the timeline line, the cleared offers and the
		// popup, told once. The build this job signed is the build that landed, and
		// it is what makes the telling news rather than a repeat.
		_reportLanding(
			identifier: watch.identifier,
			name: name,
			reason: reason,
			announce: true,
			build: watch.expected.build
		)
		release()
	}

	/// The hold that kept the local server answering is over.
	///
	/// Both halves matter: the assertion stops iOS suspending this process while
	/// the system is still fetching the package, and the notification is what lets
	/// the manager stop staging a hand-off nobody is waiting for any more.
	private func release() {
		BSJobKeepAlive.shared.end(BSJobKeepAlive.Reason.landing)
		NotificationCenter.default.post(
			name: Notification.Name("BatSign.installHandOffEnded"),
			object: nil
		)
	}

	/// What the device said about the app *before* the hand-off.
	///
	/// The three parts are kept apart on purpose. "It was installed" and "this was
	/// the build" are different facts, and a reinstall needs the second: an app
	/// that is already there looks identical before and after the new build is
	/// written unless the build it was is known.
	private struct Baseline {
		let wasInstalled: Bool
		let stamp: String?
		let identity: BuildIdentity
	}

	private func baseline(_ identifier: String) -> Baseline {
		let reading = BSInstallProbe.read(identifier)
		return Baseline(
			wasInstalled: reading.isInstalled,
			stamp: reading.stamp,
			identity: reading.identity
		)
	}
}

