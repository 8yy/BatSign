//
//  BSHomeRegistry.swift
//  Feather
//
//  The phone's Home Screen, remembered — so an install that happened while
//  nobody was watching is still noticed afterwards.
//
//  Every other part of the installer works forwards: a job is followed from the
//  moment it is handed over until it lands, and a landing is reported by whoever
//  was following. That is the right way to report an install *while it is
//  happening*, and it is how the card, the progress and the popup all stay true.
//  It has one hole, and it is the hole the user sees. If the process that was
//  following is suspended, killed, or never got a record written — the app
//  arrives on the Home Screen and BatSign has nothing to say about it, because
//  nobody alive ever saw it happen.
//
//  So the device is also read *backwards*. The whole registry is remembered
//  after every look, and the next look is diffed against it: a bundle that was
//  not there, or whose build has changed, is an install that has happened since.
//  That is the same evidence the App Store works from — it is the system's own
//  answer about what is on the phone — and unlike a follow, it cannot be
//  interrupted: a phone that was locked, an app that was killed and a job whose
//  record was already dropped all leave the same trace, and the next scan finds
//  it.
//
//  What it will not do is claim other apps' installs. A bundle the user got from
//  somewhere else is as new to this scan as one of ours, so a landing is only
//  ever reported for an app this app itself signed. A first scan establishes the
//  memory and reports nothing: on the very first launch every app on the phone
//  is "new", and none of them is an install this app just made.
//

import Foundation
import os

enum BSHomeRegistry {
	private static let log = Logger(subsystem: "app.batsign.ios", category: "device")

	/// One app, as the phone had it at one moment.
	struct Entry: Codable, Equatable {
		var identifier: String
		var version: String?
		var build: String?
		var name: String?
	}

	/// An install that has happened since the phone was last looked at.
	struct Landing {
		var identifier: String
		var name: String?
		/// What the phone had before, when it had anything.
		var previous: Entry?
		var current: Entry

		/// The app appeared where it was not before. For an app that was never on
		/// the phone — the usual case for one installed from a source — this is
		/// the whole of the evidence, and it does not need anything else.
		var isNew: Bool { previous == nil }
		/// The app was already there and its build has changed: an install over
		/// the top of one that existed, which is a landing only when the build is
		/// the one this app signed.
		var changedBuild: Bool {
			guard let previous else { return false }
			return previous.build != current.build || previous.version != current.version
		}
	}

	private static let key = "BatSign.homeRegistry"

	/// What the phone had the last time anybody looked, by bundle id.
	///
	/// Read at load, so a memory left by a build that no longer exists — a
	/// renamed key, a corrupted value — is ignorable rather than fatal: an
	/// unreadable memory behaves exactly like a first scan, which reports nothing.
	static func remembered() -> [String: Entry] {
		guard let data = UserDefaults.standard.data(forKey: key),
		      let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
		else { return [:] }
		return entries
	}

	/// Whether there is a memory to diff against at all.
	///
	/// The distinction matters: no memory means every app on the phone would look
	/// new, so a scan that has never run must report nothing and establish the
	/// memory instead.
	static var hasBaseline: Bool { !remembered().isEmpty }

	/// Diff what the phone has now against what it had last time, and remember
	/// the new state.
	///
	/// The memory is advanced as part of the diff rather than by a second call,
	/// so a landing cannot be reported twice: the change that produced it is in
	/// the memory by the time this returns.
	static func landings(using snapshot: BSDeviceApps.Snapshot) -> [Landing] {
		let before = remembered()
		let isFirstScan = before.isEmpty

		var now: [String: Entry] = [:]
		now.reserveCapacity(snapshot.entries.count)
		for (identifier, entry) in snapshot.entries {
			now[identifier] = Entry(
				identifier: identifier,
				version: entry.version,
				build: entry.build,
				name: entry.name
			)
		}

		remember(now)

		// A device that would not answer is not a device with nothing on it, and
		// a scan that replaced a real memory with an empty one would report every
		// app as new the next time it did answer.
		guard snapshot.didAnswer else {
			remember(before)
			return []
		}

		guard !isFirstScan else { return [] }

		var landings: [Landing] = []
		for (identifier, entry) in now {
			guard let previous = before[identifier] else {
				landings.append(Landing(identifier: identifier, name: entry.name, previous: nil, current: entry))
				continue
			}
			guard previous != entry else { continue }
			landings.append(Landing(identifier: identifier, name: entry.name, previous: previous, current: entry))
		}

		return landings
	}

	/// Diff against a scan taken now.
	static func landings() -> [Landing] {
		landings(using: BSDeviceApps.snapshot())
	}

	/// Whether a landing is one of ours.
	///
	/// The one thing the diff cannot know, because "new on this phone" is true of
	/// every install the user made anywhere. An app this app signed is this app's
	/// install; anything else is left alone. A build that changed rather than
	/// appeared needs more: the version on the phone has to be the version this
	/// app signed, or the change is somebody else's update to an app that happens
	/// to share the bundle id.
	static func isOurs(_ landing: Landing, signed: [String: String]) -> Bool {
		guard let signedVersion = signed[landing.identifier] else { return false }
		guard landing.changedBuild else { return true }
		return signedVersion.isEmpty || signedVersion == landing.current.version
	}

	// MARK: - On disk

	/// Advance the memory for one app, the way the diff itself would.
	///
	/// A landing reported by a watcher never goes through the diff — the watch
	/// saw the app arrive and said so in the moment, while the registry's
	/// memory still says the app is not there. The next scan then finds the
	/// same arrival again and reports it a second time, once the report
	/// window has passed — the popup the user reads days later for an app
	/// installed long ago. This writes what the phone says the app is, right
	/// now, so the scan's memory and the watcher's news agree.
	static func noteLanding(identifier: String, name: String) {
		let reading = BSDeviceApps.read(identifier)
		// A reading that cannot see the app must not become the memory of it:
		// a nil identity written here would differ from the real one forever.
		guard reading.isInRegistry || reading.installFraction != nil else { return }

		var entries = remembered()
		entries[identifier] = Entry(
			identifier: identifier,
			version: reading.identity.version,
			build: reading.identity.build,
			name: reading.name ?? name
		)
		remember(entries)
	}

	private static func remember(_ entries: [String: Entry]) {
		guard let data = try? JSONEncoder().encode(entries) else {
			log.error("homescan: could not encode the registry — the next scan has nothing to compare against")
			return
		}
		UserDefaults.standard.set(data, forKey: key)
	}

	/// Forget the memory. The next scan establishes it again and reports nothing,
	/// which is what the debug hook that drives a scan from a known state needs.
	static func forget() {
		UserDefaults.standard.removeObject(forKey: key)
	}
}
