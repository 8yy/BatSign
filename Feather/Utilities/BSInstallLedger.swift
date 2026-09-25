//
//  BSInstallLedger.swift
//  Feather
//
//  A hand-off written down, so the job it belongs to outlives the process that
//  started it.
//
//  Our own knowledge of an install begins when the link opens and ends wherever
//  the process ends. iOS fetches the package from the local server and installs
//  it at its own pace — and the user is very often somewhere else by then, with
//  the screen locked or BatSign killed in the background. Everything the watcher
//  held about that install lived in one object in one process, so a process that
//  died took the whole job with it: the card stayed on the Lock Screen saying
//  "Installing" because nobody was left who knew what it was waiting for, and
//  the next launch swept it away without a word, never saying whether the app
//  had landed.
//
//  So the hand-off is written down: what was asked for, what the device had
//  before, what this job built, whether the system ever took it, and when. It is
//  a handful of fields and it is written at the two moments that matter — when
//  the install is prepared, and when the system is asked to take it — and
//  cleared the moment the question is answered. A fresh process reads it, asks
//  the device (`BSDeviceApps`) what it now has, and either reports the landing
//  the user was owed or ends the card without claiming one.
//
//  It is deliberately not a queue and not a history. ActivityLog is the history;
//  this is the state of one question that has not been answered yet, and an
//  entry that is answered or abandoned is gone.
//

import Foundation
import os

enum BSInstallLedger {
	private static let log = Logger(subsystem: "app.batsign.ios", category: "install")

	/// Where the answer to a hand-off has got to.
	enum Stage: String, Codable {
		/// The device has been read and the job is about to build its package.
		/// Nothing has been handed to the system yet.
		case armed
		/// The install link has been opened. From here the system may be
		/// installing this app, and this record is the only thing that says so.
		case handedOff
		/// The card is down and nothing is following any more, but the question is
		/// still open. Either the wait for the hand-off ran out or the system went
		/// quiet — and an install that began slowly can still land minutes later,
		/// while BatSign is suspended or gone.
		///
		/// A stage rather than a deletion, because the two are not the same thing:
		/// the card going down is a decision about what to *show*, and this record
		/// is what is still *known*. Keeping it is how a later process can still
		/// say "it landed" instead of never having heard of the job at all.
		case awaiting
	}

	/// One hand-off, as it stood when it was last written.
	struct Record: Codable {
		/// The bundle id the install is about — the one name every part of the
		/// device agrees on.
		var identifier: String
		/// What the app is called, for the popup the landing owes the user.
		var name: String
		/// The build this job signed, as read off the bundle it handed over.
		var expected: BuildIdentity
		/// What the device had before the hand-off, so "the app is there" can be
		/// told from "this build is there, and it was not".
		var baseline: BuildIdentity
		var baselineStamp: String?
		var wasInstalled: Bool

		var stage: Stage
		/// When the hand-off was asked for — the start of the clock the watcher
		/// runs on, and the reason a record can be given up on.
		var askedAt: Date
		/// The last moment this record was touched by anything with news.
		var updatedAt: Date

		/// The system reported an install object for this bundle: the package was
		/// accepted and the confirmation was shown. It is what keeps a relaunched
		/// process from offering the same install a second time.
		var sawProgress: Bool
		/// That install was seen under way, below completion.
		var sawInFlight: Bool
		/// An install object was seen for this bundle at or above completion — the
		/// case a package that never publishes a moving fraction lands in.
		var sawInstallAtEnd: Bool
		/// When the device was last seen working on this bundle, so a resumed
		/// watch can tell a slow install from one that never started.
		var lastProgressAt: Date?

		var expectedIsEmpty: Bool { expected.isEmpty }
	}

	/// How long a hand-off may stay on the books.
	///
	/// The watcher's own deadline, because they are the same clock: the record is
	/// the watcher's state after the process is gone, and it must not outlive the
	/// span the installer retention in `AutoSignManager` already allows. A record
	/// older than this describes an install nobody is serving any more.
	static let lifetime: TimeInterval = 660

	/// How long an answered-by-silence record may still claim a landing.
	///
	/// Past the deadline the wait is over, but the *answer* can still arrive: an
	/// app that turned up twenty minutes after the card went down is still an
	/// install this app made, and the user is still owed the news. Six hours is
	/// long enough for a lock screen, a tunnel that stalled and a phone that was
	/// put down, and short enough that a build from yesterday is not announced
	/// into today.
	static let reportWindow: TimeInterval = 6 * 3600

	/// How long a record may stay on the books with nothing on the device to
	/// show for it.
	///
	/// A resumed process has no server and no staged package, so an install it
	/// took over is only still possible if the system is already fetching. If the
	/// system is not installing this bundle and the device does not have the
	/// build, there is nothing to wait for — and a card that says "Installing"
	/// through a wait that cannot end is the thing this whole file exists to
	/// prevent. Long enough for a manifest fetch that has only just begun, short
	/// enough that the card goes while the user is still looking at it.
	static let silence: TimeInterval = 45

	private static let key = "BatSign.installLedger"
	/// Records are dropped at load, not kept as history: the oldest possible
	/// useful record is one whose deadline has not passed, and anything beyond a
	/// day is a leftover from a build that no longer exists.
	private static let maxAge: TimeInterval = 86_400

	// MARK: - Reading and writing

	/// Every record on the books, expired ones removed.
	///
	/// Expiry is applied on read rather than on a timer, because a timer cannot
	/// run in a process that is not running — which is the only situation this
	/// store exists for.
	static var records: [Record] {
		let now = Date()
		let all = _load().filter { now.timeIntervalSince($0.askedAt) < maxAge }
		return all
	}

	static func record(for identifier: String) -> Record? {
		guard !identifier.isEmpty else { return nil }
		return records.first { $0.identifier == identifier }
	}

	/// Whether this hand-off has run out of time.
	static func isExpired(_ record: Record, at now: Date = Date()) -> Bool {
		now.timeIntervalSince(record.askedAt) > lifetime
	}

	/// Write a record over any previous one for the same bundle.
	static func put(_ record: Record) {
		guard !record.identifier.isEmpty else { return }
		var all = _load()
		all.removeAll { $0.identifier == record.identifier }
		all.append(record)
		_save(all)
	}

	/// Note what the system is doing with a hand-off, as it is seen.
	///
	/// The watcher observes several things about one install over its life — the
	/// system took it, it is under way, it reached the end — and each one is
	/// written as it happens, so that a process which dies a second later leaves
	/// the most it knew behind. Those three observations are the difference
	/// between a fresh process that can tell an install the system is running
	/// from one that never began, and one that can only guess.
	///
	/// Written rarely on purpose: a fraction is reported every second, and a
	/// write per second to a store that exists for the crash case is not worth
	/// the disk. A boolean that has just turned true, or a progress stamp more
	/// than `progressInterval` old, is all this keeps.
	static func noteProgress(
		_ identifier: String,
		fraction: Double,
		isNew: Bool,
		at date: Date = Date()
	) {
		guard var record = record(for: identifier) else { return }

		let isStaleStamp = record.lastProgressAt.map { date.timeIntervalSince($0) > progressInterval } ?? true
		guard isNew || isStaleStamp else { return }

		record.sawProgress = true
		if fraction < 0.99 {
			record.sawInFlight = true
		} else {
			record.sawInstallAtEnd = true
		}
		record.lastProgressAt = date
		record.updatedAt = date
		put(record)
	}

	/// How old the recorded progress stamp has to be before it is refreshed.
	private static let progressInterval: TimeInterval = 5

	/// The card has gone and nothing is following; the question stays open.
	///
	/// Called where a job would previously have been forgotten. The difference
	/// between "we have stopped watching" and "we no longer know" is the whole
	/// point: an install that began slowly can still land after the card has gone,
	/// and a later process can still settle it — but only if it was written down.
	static func hold(_ identifier: String, at date: Date = Date()) {
		guard var record = record(for: identifier), record.stage != .awaiting else { return }
		record.stage = .awaiting
		record.updatedAt = date
		put(record)
	}

	// MARK: - News that has already been told

	private static let reportedKey = "BatSign.installReported"

	/// News that went out, and which build of the app it was about.
	///
	/// The build is half the fact, not decoration. "We told the user this app
	/// landed" is only the same news while the app on the phone is the same app;
	/// the user who deletes it and installs it again is owed the news again, and a
	/// stamp keyed on the bundle id alone would sit there and refuse to speak.
	struct Reported: Codable {
		var at: Date
		var build: String?
	}

	/// Whether this install has already been announced.
	///
	/// A landing is news, and news delivered twice is worse than none: the user
	/// gets two popups, two timeline lines and two card finishes for one app, and
	/// stops believing any of them. Two things can produce the same landing —
	/// a launch and a return to the foregound both reconcile, and either can reach
	/// a record before the other has cleared it — so the fact that the news went
	/// out is written down beside the record rather than inferred from it.
	///
	/// Written on the way in to the announcement and durable, because the process
	/// that announced it can die a moment later: a report is not something a
	/// restart should repeat.
	///
	/// `build` is the build the device held when the news went out. When both the
	/// recorded and the current build are known and they differ, the app arrived
	/// again and this is not a repeat — the window is about how long a *telling*
	/// stays fresh, not about how long the app is on the phone.
	static func hasBeenReported(
		_ identifier: String,
		build: String? = nil,
		within window: TimeInterval = 900
	) -> Bool {
		guard !identifier.isEmpty else { return false }
		guard let said = _reported()[identifier] else { return false }
		guard Date().timeIntervalSince(said.at) < window else { return false }
		guard let build, let told = said.build, !build.isEmpty, !told.isEmpty else { return true }
		return told == build
	}

	static func noteReported(_ identifier: String, build: String? = nil, at date: Date = Date()) {
		guard !identifier.isEmpty else { return }
		var all = _reported()
		// Stamps older than the window are dropped here rather than on a timer:
		// nothing reads them again, and a store this small should not grow.
		all = all.filter { date.timeIntervalSince($0.value.at) < 900 }
		all[identifier] = Reported(at: date, build: build)
		_rememberReported(all)
	}

	/// A new hand-off for the same app is a new question, and its landing is news
	/// again. Without this a reinstall within the window would be announced to
	/// nobody — the app the user just installed and does not have.
	static func forgetReported(_ identifier: String) {
		guard !identifier.isEmpty else { return }
		var all = _reported()
		guard all.removeValue(forKey: identifier) != nil else { return }
		_rememberReported(all)
	}

	private static func _reported() -> [String: Reported] {
		guard let data = UserDefaults.standard.data(forKey: reportedKey) else { return [:] }
		if let stamps = try? JSONDecoder().decode([String: Reported].self, from: data) {
			return stamps
		}
		// A store written by the build that kept a bare date. Read rather than
		// discarded: an install announced before the update is still announced, and
		// treating it as fresh news is exactly the duplicate this store prevents.
		if let legacy = try? JSONDecoder().decode([String: Date].self, from: data) {
			return legacy.mapValues { Reported(at: $0, build: nil) }
		}
		return [:]
	}

	private static func _rememberReported(_ stamps: [String: Reported]) {
		guard let data = try? JSONEncoder().encode(stamps) else { return }
		UserDefaults.standard.set(data, forKey: reportedKey)
	}

	/// The question has been answered, or given up on. Either way it is not on
	/// the books any more.
	static func clear(_ identifier: String) {
		guard !identifier.isEmpty else { return }
		var all = _load()
		let before = all.count
		all.removeAll { $0.identifier == identifier }
		guard all.count != before else { return }
		_save(all)
	}

	/// Drop everything. Used by the debug hook that stages a record by hand, so a
	/// test starts from a known state rather than from the last run's leftovers.
	static func clearAll() {
		_save([])
	}

	// MARK: - On disk

	private static func _load() -> [Record] {
		guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
		return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
	}

	private static func _save(_ records: [Record]) {
		guard let data = try? JSONEncoder().encode(records) else {
			log.error("ledger: could not encode — the hand-off is not written down")
			return
		}
		UserDefaults.standard.set(data, forKey: key)
	}
}
