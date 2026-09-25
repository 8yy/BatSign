//
//  BSDeviceApps.swift
//  Feather
//
//  One question about the phone, answered from the phone: is the app this job
//  is about installing, installed, or not there?
//
//  Everything the signer concludes about an install has to come from the device,
//  and until now each caller asked its own way: the watcher asked about one
//  bundle, the store asked about another, and a process that had just been
//  started had no way to ask at all. Three askers, three partial answers, and no
//  way to tell "the device does not have it" from "the device would not say".
//
//  So there is one reading, taken once, and it is a *scan*: `snapshot()` reads
//  the system's whole registry in a single cross-process pass, and a reading for
//  any bundle comes out of it. Installd's own install object is consulted beside
//  it, because that is the only thing on the device that distinguishes a bundle
//  being *installed right now* from one that is merely sitting on the Home
//  Screen — a distinction the registry cannot make, and the one thing an install
//  card has to know.
//
//  The two facts are deliberately kept apart. "The registry names this app" and
//  "the system is installing this app" are independent: during a reinstall both
//  are true, and a reading that folded them into one boolean could not tell a
//  replacement under way from one that is already done — which is exactly the
//  case a card gets stuck on.
//
//  And the third answer is not silence. A device that will not hand over its
//  registry is not a device with no apps, so "absent" is only ever said when the
//  device really said so.
//

import Foundation
import UIKit
import os

/// The device's own four answers, as one value.
enum BSAppStatus: Equatable {
	/// The registry names it, so a build of it is on the device.
	case installed
	/// The system has an install object for this bundle: it is installing this
	/// app now.
	case installing
	/// The registry answered, and does not have it.
	case absent
	/// The workspace would not answer: nothing follows from this.
	case unknown
}

/// Everything the device will say about one app at one moment.
struct BSAppReading: Sendable, Equatable {
	/// The device has a build of this app — the registry names it. True before,
	/// during and after a reinstall, which is why it is never evidence on its
	/// own that an install has happened.
	var isInRegistry: Bool
	/// What that build is called, when the device says.
	var identity: BuildIdentity
	/// Where that build lives, when the system hands the path over.
	var path: String?
	/// What the app is called, when the device says.
	var name: String?
	/// The system's install fraction. Non-nil means an install object exists —
	/// which the system reports only for a bundle it is installing, never for one
	/// that is merely installed.
	var installFraction: Double?
	/// The registry was read. False makes every absence unknown.
	var registryAnswered: Bool
	/// `applicationIsInstalled:` is implemented, so absence can be stated.
	var canTellAbsence: Bool
	/// When this was read.
	var takenAt: Date

	static let unknown = BSAppReading(
		isInRegistry: false,
		identity: BuildIdentity(version: nil, build: nil),
		path: nil,
		name: nil,
		installFraction: nil,
		registryAnswered: false,
		canTellAbsence: false,
		takenAt: .distantPast
	)

	var status: BSAppStatus {
		if installFraction != nil { return .installing }
		if isInRegistry { return .installed }
		guard registryAnswered || canTellAbsence else { return .unknown }
		return .absent
	}

	/// The system is working on this bundle right now.
	var isInstalling: Bool { installFraction != nil }

	var stamp: String? { path.map(BSDeviceApps.BundleStamp.of) }

	var described: String {
		switch status {
		case .installed: "installed \(identity.described)"
		case .installing: "installing \(installFraction.map { String(format: "%.2f", $0) } ?? "?")"
		case .absent: "not installed"
		case .unknown: "unknown"
		}
	}
}

enum BSDeviceApps {
	private static let log = Logger(subsystem: "app.batsign.ios", category: "device")

	/// One app, as the device describes it.
	struct Entry: Sendable {
		let identifier: String
		let name: String?
		let version: String?
		let build: String?
		let path: String?

		var identity: BuildIdentity { BuildIdentity(version: version, build: build) }
	}

	/// The whole phone, read once.
	///
	/// `entries` is keyed by bundle id so a lookup costs nothing; `didAnswer` says
	/// whether the registry was read at all. A snapshot is a value and is meant to
	/// be taken off the main thread — it is a cross-process read — and then handed
	/// to whichever part of a job needs a decision.
	struct Snapshot: Sendable {
		let entries: [String: Entry]
		/// The registry answered. False means every lookup answers `.unknown`
		/// rather than `.absent`, because absence has to be a fact about the
		/// phone and not about this process's reach.
		let didAnswer: Bool
		/// `applicationIsInstalled:` is implemented, so absence can be stated.
		let canTellAbsence: Bool
		/// When this was read, so a caller can say how old its answer is.
		let takenAt: Date

		static let unreadable = Snapshot(
			entries: [:],
			didAnswer: false,
			canTellAbsence: false,
			takenAt: .distantPast
		)
	}

	/// Read the device: one pass over the registry.
	///
	/// The pass is the scan. Everything a caller needs about a bundle afterwards
	/// is answered from it, and the only calls made after it are the ones the
	/// registry cannot answer — the install object, and the registry's own
	/// yes/no for a bundle the list does not carry.
	static func snapshot() -> Snapshot {
		let canTellAbsence = UIApplication.canReportInstallation()

		guard let installed = UIApplication.installedApplications() else {
			return Snapshot(
				entries: [:],
				didAnswer: false,
				canTellAbsence: canTellAbsence,
				takenAt: Date()
			)
		}

		var entries: [String: Entry] = [:]
		entries.reserveCapacity(installed.count)
		for app in installed {
			entries[app.identifier] = Entry(
				identifier: app.identifier,
				name: app.name,
				version: app.version,
				build: app.build,
				path: app.path
			)
		}

		return Snapshot(
			entries: entries,
			didAnswer: true,
			canTellAbsence: canTellAbsence,
			takenAt: Date()
		)
	}

	/// What the device says about one app, given a snapshot already in hand.
	static func read(_ identifier: String, using snapshot: Snapshot) -> BSAppReading {
		guard !identifier.isEmpty else { return .unknown }

		guard let entry = snapshot.entries[identifier] else {
			// Not in the list. The list is the whole registry, so for a device
			// that answered this is already a "no" — but `applicationIsInstalled:`
			// is asked as well, because the two disagree on a bundle the device
			// installs without listing it, and the answer that matters is the one
			// that says it *is* there.
			let isThere = UIApplication.isInstalled(identifier)
			let record = isThere ? UIApplication.installedApplication(identifier) : nil

			return BSAppReading(
				isInRegistry: isThere,
				identity: BuildIdentity(version: record?.version, build: record?.build),
				path: record?.path,
				name: record?.name,
				installFraction: UIApplication.installProgress(for: identifier),
				registryAnswered: snapshot.didAnswer,
				canTellAbsence: snapshot.canTellAbsence,
				takenAt: snapshot.takenAt
			)
		}

		return BSAppReading(
			isInRegistry: true,
			identity: entry.identity,
			path: entry.path,
			name: entry.name,
			installFraction: UIApplication.installProgress(for: identifier),
			registryAnswered: snapshot.didAnswer,
			canTellAbsence: snapshot.canTellAbsence,
			takenAt: snapshot.takenAt
		)
	}

	/// What the device says about one app, read now.
	static func read(_ identifier: String) -> BSAppReading {
		read(identifier, using: snapshot())
	}

	/// The status of one app, as the four-answer summary.
	static func status(of identifier: String, using snapshot: Snapshot) -> BSAppStatus {
		read(identifier, using: snapshot).status
	}

	/// The four answers, as one line, for the log and for a support report.
	static func describe(_ identifier: String, using snapshot: Snapshot) -> String {
		let reading = read(identifier, using: snapshot)
		let name = reading.name ?? "—"
		return "\(identifier) [\(name)]: \(reading.described)"
	}

	/// The whole scan, as lines: every app the device names, with its build.
	///
	/// This is what "scan the app status on the phone" means in practice — one
	/// reading of the registry, the count, and whatever the system is installing
	/// right now — so a scan that returned nothing can be told from a device that
	/// has nothing.
	static func report(_ snapshot: Snapshot, limit: Int = 10) -> String {
		guard snapshot.didAnswer else {
			return "scan: the registry would not answer \(snapshot.entries.count) apps; absence available: \(snapshot.canTellAbsence)"
		}

		let sorted = snapshot.entries.values.sorted { $0.identifier < $1.identifier }
		let head = sorted.prefix(limit).map { "\($0.identifier)@\($0.identity.described)" }
		let installs = sorted
			.filter { UIApplication.installProgress(for: $0.identifier) != nil }
			.map(\.identifier)

		var lines = ["scan: \(sorted.count) apps on the device"]
		lines.append("scan: \(head.joined(separator: ", "))\(sorted.count > limit ? ", …" : "")")
		lines.append(installs.isEmpty
			? "scan: nothing is being installed"
			: "scan: installing now — \(installs.joined(separator: ", "))")
		return lines.joined(separator: "\n")
	}

	/// A fingerprint that changes when the app on disk is replaced: where it
	/// lives, and when that path was last written.
	///
	/// Lives here rather than in the watcher because it is a fact about the
	/// device, and every reader of a status has to read it the same way.
	enum BundleStamp {
		static func of(_ path: String) -> String {
			let attributes = try? FileManager.default.attributesOfItem(atPath: path)
			let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
			return "\(path)#\(Int(modified))"
		}
	}
}
