//
//  AutoUpdateManager.swift
//  Feather
//
//  App Store-style automatic updates: periodically compares installed
//  apps against their repositories, silently downloads, signs and
//  (where the installation method allows) installs updates.
//

import Foundation
import CoreData
import Network
import UIKit
import UserNotifications
import BackgroundTasks
import OSLog
import AltSourceKit

enum BatSignAuto {
	/// Prefix marking downloads that were started by the automatic updater.
	static let downloadPrefix = "BatSignAutoDownload"

	/// Prefix marking an update the user asked for by hand — from the Updates
	/// tab or from a Library row.
	///
	/// One prefix for both, because the two entry points used to invent their
	/// own (`BatSignManualUpdate_` and `FeatherManualDownload_`) and nothing
	/// that keys off an id recognised both. The importer classifies a transfer
	/// by prefix, and a manual update that reads as a first-time import is an
	/// update the card stops calling an update halfway through.
	static let manualUpdatePrefix = "BatSignManualUpdate"
}

@MainActor
final class AutoUpdateManager: ObservableObject {
	static let shared = AutoUpdateManager()

	static let autoDownloadPrefix = BatSignAuto.downloadPrefix

	private enum Keys {
		static let autoUpdateEnabled = "BatSign.autoUpdateEnabled"
		static let autoRenewEnabled = "BatSign.autoRenewEnabled"
		static let notificationsEnabled = "BatSign.notificationsEnabled"
		static let perAppAutoUpdate = "BatSign.perAppAutoUpdate"
		static let lastCheck = "BatSign.lastUpdateCheck"
		static let intervalHours = "BatSign.autoUpdateInterval"
		static let renewThresholdDays = "BatSign.renewThresholdDays"
		static let renewedUUIDs = "BatSign.renewedUUIDs"
	}

	@Published private(set) var isAutoChecking = false

	private var _timer: Timer?
	private let _pathMonitor = NWPathMonitor()
	private var _networkPath: NWPath?

	// MARK: - Settings (UserDefaults backed so views can bind with @AppStorage)

	var isWifiOnly: Bool {
		get { UserDefaults.standard.object(forKey: "BatSign.autoUpdateWifiOnly") as? Bool ?? false }
		set { UserDefaults.standard.set(newValue, forKey: "BatSign.autoUpdateWifiOnly") }
	}

	var isSelfHealEnabled: Bool {
		get { UserDefaults.standard.object(forKey: "BatSign.selfHealRevoked") as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: "BatSign.selfHealRevoked") }
	}

	var isNightWindowOnly: Bool {
		get { UserDefaults.standard.object(forKey: "BatSign.autoUpdateNightOnly") as? Bool ?? false }
		set { UserDefaults.standard.set(newValue, forKey: "BatSign.autoUpdateNightOnly") }
	}

	/// Every automation toggle writes to UserDefaults and then asks the run
	/// loop to re-publish. These are plain stored properties as far as the
	/// observer is concerned: a `@Published` computed property cannot exist, so
	/// the bump is what makes a `Toggle` somewhere else agree with what just
	/// happened here.
	var isAutoUpdateEnabled: Bool {
		get { UserDefaults.standard.object(forKey: Keys.autoUpdateEnabled) as? Bool ?? true }
		set {
			UserDefaults.standard.set(newValue, forKey: Keys.autoUpdateEnabled)
			objectWillChange.send()
			if newValue { tick() }
		}
	}

	var isAutoRenewEnabled: Bool {
		get { UserDefaults.standard.object(forKey: Keys.autoRenewEnabled) as? Bool ?? true }
		set {
			UserDefaults.standard.set(newValue, forKey: Keys.autoRenewEnabled)
			objectWillChange.send()
		}
	}

	var notificationsEnabled: Bool {
		get { UserDefaults.standard.object(forKey: Keys.notificationsEnabled) as? Bool ?? true }
		set {
			UserDefaults.standard.set(newValue, forKey: Keys.notificationsEnabled)
			objectWillChange.send()
			if newValue { requestNotificationAuthorization() }
		}
	}

	var intervalHours: Double {
		get { UserDefaults.standard.object(forKey: Keys.intervalHours) as? Double ?? 6.0 }
		set { UserDefaults.standard.set(newValue, forKey: Keys.intervalHours) }
	}

	var renewThresholdDays: Int {
		get { UserDefaults.standard.object(forKey: Keys.renewThresholdDays) as? Int ?? 3 }
		set { UserDefaults.standard.set(newValue, forKey: Keys.renewThresholdDays) }
	}

	var lastCheckDate: Date? {
		get { UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date }
		set { UserDefaults.standard.set(newValue, forKey: Keys.lastCheck) }
	}

	// MARK: - Init

	private init() {}

	/// Boots the periodic checker. Called once on app launch.
	func start() {
		_pathMonitor.pathUpdateHandler = { [weak self] path in
			Task { @MainActor [weak self] in
				self?._networkPath = path
			}
		}
		_pathMonitor.start(queue: DispatchQueue.global(qos: .utility))

		_timer?.invalidate()
		_timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.tick()
			}
		}
		tick()
	}

	/// Runs a check if the configured interval has elapsed and the
	/// network/time constraints allow it.
	func tick() {
		if let last = lastCheckDate, !_intervalHasElapsed(since: last) {
			checkRenewals()
			return
		}

		guard _networkAllowed(), _withinWindow() else {
			checkRenewals()
			return
		}

		Task { await checkNow(notifyWhenClean: false) }
	}

	/// Whether enough time has passed since the last real check.
	///
	/// A negative interval — a `lastCheckDate` that is *after* now, which is
	/// what a clock set back produces, whether by hand or by a network time
	/// correction — used to satisfy the "not yet" comparison for ever, and a
	/// device that had done that stopped checking for updates permanently. A
	/// future stamp is treated as elapsed: it carries no information about when
	/// the last check really happened, so the check runs and the stamp is put
	/// somewhere sensible.
	private func _intervalHasElapsed(since last: Date) -> Bool {
		let elapsed = Date().timeIntervalSince(last)
		return elapsed <= 0 || elapsed >= intervalHours * 3600
	}

	private func _networkAllowed() -> Bool {
		guard isWifiOnly else { return true }
		guard let path = _networkPath, path.status == .satisfied else { return true }
		return !path.isExpensive
	}

	private func _withinWindow() -> Bool {
		guard isNightWindowOnly else { return true }
		let hour = Calendar.current.component(.hour, from: Date())
		return hour >= 22 || hour < 6
	}

	// MARK: - Checking

	@discardableResult
	func checkNow(notifyWhenClean: Bool = true, silent: Bool = false) async -> Int {
		guard !isAutoChecking else { return UpdateManager.shared.updates.count }
		isAutoChecking = true
		defer {
			isAutoChecking = false
			lastCheckDate = Date()
		}

		await UpdateManager.shared.checkForUpdates(
			sources: _fetchSources(),
			localApps: _fetchSignedApps().map { $0 as AppInfoPresentable }
				+ _fetchImportedApps().map { $0 as AppInfoPresentable }
		)

		checkRenewals()

		let updates = UpdateManager.shared.updates.values
			.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }

		ActivityLog.shared.log(.checked, app: "BatSign", detail: updates.isEmpty ? "all apps up to date" : "\(updates.count) found")

		if updates.isEmpty {
			_updateBadge(0)
			if notifyWhenClean && !silent {
				notify(
					title: "All Apps Up to Date",
					body: "Every app matches the latest version in its repository.",
					identifier: "signos.updates.clean"
				)
			}
			return 0
		}

		_updateBadge(updates.count)

		if !isAutoUpdateEnabled {
			if silent { return updates.count }
			let body: String
			if
				updates.count == 1,
				let whatsNew = updates[0].whatsNew,
				!whatsNew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			{
				let trimmed = whatsNew.count > 120 ? String(whatsNew.prefix(120)) + "…" : whatsNew
				body = "\(updates[0].appName) \(updates[0].remoteVersion): \(trimmed)"
			} else if updates.count == 1 {
				body = "\(updates[0].appName) has a new version available."
			} else {
				body = "\(updates.count) apps have new versions available."
			}
			notify(title: "Updates Available", body: body, identifier: "signos.updates.available")
			return updates.count
		}

		let disabledSourceURLs = _disabledSourceURLs()

		var started = 0
		for update in updates {
			guard isAutoUpdateEnabled(for: update.bundleIdentifier) else { continue }
			guard !_matchesDisabledSource(update.sourceURL, disabled: disabledSourceURLs) else { continue }
			let jobId = "\(Self.autoDownloadPrefix)_\(update.localUUID)"
			guard DownloadManager.shared.getDownload(by: jobId) == nil else { continue }

			// The app's own name and bundle id travel with the transfer. The card
			// is keyed by the bundle id, so the signing and install halves that
			// follow this download land on the same card — and the name on it is
			// the app the user knows rather than the file name in the URL.
			//
			// The transfer is not written into the timeline here. It is written
			// by the delivery itself, in the one place that knows the bytes
			// arrived — which is later than this line, and which also covers a
			// package that arrives while the app is somewhere else. Recording it
			// in both places put two "Downloaded" rows in the timeline for one
			// download.
			_ = DownloadManager.shared.startDownload(
				from: update.downloadURL,
				id: jobId,
				bundleID: update.bundleIdentifier,
				displayName: update.appName,
				sourceProvenance: update.sourceProvenance
			)
			started += 1
		}

		if started > 0 {
			notify(
				title: "Updating Apps",
				body: started == 1
					? "Downloading \(updates.count == 1 ? updates[0].appName : "1 app") in the background."
					: "Downloading \(started) app updates in the background.",
				identifier: "signos.updates.downloading"
			)
		}

		return updates.count
	}

	private func _updateBadge(_ count: Int) {
		let enabled = UserDefaults.standard.object(forKey: "BatSign.badgeUpdates") as? Bool ?? false
		UIApplication.shared.applicationIconBadgeNumber = enabled ? min(max(count, 0), 99) : 0
	}

	/// Recomputes the app-icon badge from current pending updates.
	func updateBadgeFromState() {
		_updateBadge(UpdateManager.shared.updates.count)
	}

	// MARK: - Per-source rules

	func isSourceAutoUpdateEnabled(_ source: AltSource) -> Bool {
		let overrides = UserDefaults.standard.dictionary(forKey: "BatSign.sourceAutoUpdate") as? [String: Bool] ?? [:]
		return overrides[source.identifier ?? ""] ?? true
	}

	func setSourceAutoUpdate(_ enabled: Bool, for source: AltSource) {
		var overrides = UserDefaults.standard.dictionary(forKey: "BatSign.sourceAutoUpdate") as? [String: Bool] ?? [:]
		overrides[source.identifier ?? ""] = enabled
		UserDefaults.standard.set(overrides, forKey: "BatSign.sourceAutoUpdate")
	}

	private func _disabledSourceURLs() -> Set<String> {
		let overrides = UserDefaults.standard.dictionary(forKey: "BatSign.sourceAutoUpdate") as? [String: Bool] ?? [:]
		return Set(
			_fetchSources()
				.filter { overrides[$0.identifier ?? ""] == false }
				.compactMap { $0.sourceURL?.absoluteString }
		)
	}

	private func _matchesDisabledSource(_ url: URL, disabled: Set<String>) -> Bool {
		var string = url.absoluteString
		if string.hasSuffix("/") {
			string = String(string.dropLast())
		}
		return disabled.contains(string)
	}

	// MARK: - Shortcuts

	/// Downloads every pending update through the automatic pipeline.
	///
	/// This is the "Install Pending Updates" Shortcut — an explicit, user-
	/// invoked command, the Shortcut twin of the in-app "Update All" button.
	/// Both ignore the per-app and per-source switches on purpose: those
	/// switches govern what the app does *by itself in the background*, and a
	/// bulk action the user started by hand is the user overriding that. The
	/// automatic path keeps its guards; this one is not automatic.
	func downloadAllPendingUpdates() async -> Int {
		// Silent: the Shortcut's dialog is the news, and a banner saying
		// "updates available" over the same moment it downloads them is the
		// duplicate-popup this app learned not to post.
		await checkNow(notifyWhenClean: false, silent: true)

		var started = 0
		for update in UpdateManager.shared.updates.values {
			let jobId = "\(Self.autoDownloadPrefix)_\(update.localUUID)"
			if DownloadManager.shared.getDownload(by: jobId) != nil {
				// Already in flight — the automatic path took it during the
				// check above. Count it, so the dialog does not claim "No
				// updates to install" while they are installing.
				started += 1
				continue
			}

			_ = DownloadManager.shared.startDownload(
				from: update.downloadURL,
				id: jobId,
				bundleID: update.bundleIdentifier,
				displayName: update.appName,
				sourceProvenance: update.sourceProvenance
			)
			started += 1
		}
		return started
	}

	/// Re-derives the update list from current sources and library with none of
	/// the side effects of a full check — no notifications, no automatic
	/// downloads, no interval stamp.
	///
	/// The skip/hold rules changed: the optimistic restore can only re-add what
	/// the last check found, and an app the user has since updated by hand must
	/// not come back as an update. Only a fetch knows, so the tap re-checks and
	/// the list is replaced with the truth.
	func refreshUpdatesSilently() async {
		guard !isAutoChecking else { return }
		await UpdateManager.shared.checkForUpdates(
			sources: _fetchSources(),
			localApps: _fetchSignedApps().map { $0 as AppInfoPresentable }
				+ _fetchImportedApps().map { $0 as AppInfoPresentable },
			preserveOnFailure: true
		)
		updateBadgeFromState()
	}

	// MARK: - Per-app auto-update

	func isAutoUpdateEnabled(for identifier: String) -> Bool {
		guard isAutoUpdateEnabled else { return false }
		let overrides = UserDefaults.standard.dictionary(forKey: Keys.perAppAutoUpdate) as? [String: Bool]
		return overrides?[identifier] ?? true
	}

	func setAutoUpdate(_ enabled: Bool, for identifier: String) {
		var overrides = UserDefaults.standard.dictionary(forKey: Keys.perAppAutoUpdate) as? [String: Bool] ?? [:]
		overrides[identifier] = enabled
		UserDefaults.standard.set(overrides, forKey: Keys.perAppAutoUpdate)
	}

	// MARK: - Certificate renewal

	/// Re-signs apps whose certificate is about to expire (or was revoked)
	/// using the healthiest available certificate, so installs survive
	/// past the 7/365-day signing windows.
	func checkRenewals() {
		guard isAutoRenewEnabled else { return }

		// Self-Heal: re-verify revocation status against Apple's own
		// checks (throttled to once per 6h per certificate). Revoked
		// certificates immediately qualify for re-sign below.
		if isSelfHealEnabled {
			let now = Date()
			for cert in Storage.shared.getAllCertificates() where !cert.revoked {
				guard let uuid = cert.uuid else { continue }
				let key = "BatSign.lastRevocationCheck.\(uuid)"
				let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
				if now.timeIntervalSince(last) < 6 * 3600 { continue }
				UserDefaults.standard.set(now, forKey: key)
				Storage.shared.revokagedCertificate(for: cert)
			}
		}

		let threshold = Double(renewThresholdDays) * 86400
		var renewed = Set(UserDefaults.standard.stringArray(forKey: Keys.renewedUUIDs) ?? [])

		for app in _fetchSignedApps() {
			guard let uuid = app.uuid, !renewed.contains(uuid) else { continue }

			let needsRenewal: Bool
			if let cert = app.certificate {
				if cert.revoked {
					needsRenewal = isSelfHealEnabled
				} else if let expiration = cert.expiration {
					needsRenewal = expiration.timeIntervalSinceNow <= threshold
				} else {
					needsRenewal = false
				}
			} else {
				needsRenewal = false
			}

			guard needsRenewal else { continue }

			// Only renew when a healthy replacement certificate exists.
			guard let replacement = _healthiestCertificate(excluding: app.certificate) else { continue }

			// The mark is the *result* of asking, not the asking itself. It used
			// to be written before the enqueue, and an enqueue that refused —
			// automatic signing turned off, or a job the queue would not take —
			// left the uuid recorded as renewed while nothing was ever resigned.
			// The certificate then expired anyway, and nothing retried it,
			// because the record said it was already done.
			guard AutoSignManager.shared.enqueue(app: app, reason: .renewal, certificate: replacement) else {
				continue
			}

			renewed.insert(uuid)
			UserDefaults.standard.set(Array(renewed), forKey: Keys.renewedUUIDs)
		}
	}

	private func _healthiestCertificate(excluding: CertificatePair?) -> CertificatePair? {
		let certs = Storage.shared.getAllCertificates().filter { cert in
			guard !cert.revoked, cert != excluding else { return false }
			if let expiration = cert.expiration {
				return expiration.timeIntervalSinceNow > 86400
			}
			return true
		}
		return certs.first { $0.isDefault } ?? certs.first
	}

	// MARK: - Notifications

	func requestNotificationAuthorization() {
		let install = UNNotificationAction(identifier: "SIGNOS_INSTALL_ACTION", title: "Install", options: [.foreground])
		let later = UNNotificationAction(identifier: "SIGNOS_LATER_ACTION", title: "Later", options: [])
		UNUserNotificationCenter.current().setNotificationCategories([
			UNNotificationCategory(identifier: "SIGNOS_INSTALL", actions: [install, later], intentIdentifiers: [])
		])

		// The prompt is presented by the app and blocks the whole screen. On a
		// simulator there is no one to tap it — automation cannot reach the
		// alert — so the ask is skipped there and the grant comes from the TCC
		// database instead. Devices still ask, once, in the user's hands.
		#if !targetEnvironment(simulator)
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
			// The grant is the whole point of the ask and it used to be thrown
			// away, which left the one failure that matters — every install
			// popup from then on dropped by the system without a word —
			// invisible from inside the app.
			if let error {
				Logger.notify.error("notify: authorization failed — \(error.localizedDescription, privacy: .public)")
			} else {
				Logger.notify.notice("notify: authorization granted: \(granted, privacy: .public)")
			}
		}
		#else
		Logger.notify.notice("notify: authorization is not requested on the simulator")
		#endif
	}

	/// Post a notification, and make sure one can arrive at all.
	///
	/// Two gates stand in front of every card and both used to be silent: the
	/// user's own switch, and the permission the app may never have been
	/// granted. A notification that is not authorized is dropped by the system
	/// without an error, so an install that finished while the user was in
	/// another app ended in nothing at all — the popup that was supposed to
	/// arrive outside simply never existed. The status is read here, the ask is
	/// made when it has never been made, and the outcome is logged either way,
	/// so "no popup appeared" is answerable afterwards.
	func notify(title: String, body: String, identifier: String = UUID().uuidString, category: String? = nil) {
		guard notificationsEnabled else {
			Logger.notify.notice("notify: suppressed by the user's setting — \(title, privacy: .public)")
			return
		}

		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		if let category {
			content.categoryIdentifier = category
		}

		let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
		let center = UNUserNotificationCenter.current()

		center.getNotificationSettings { settings in
			switch settings.authorizationStatus {
			case .authorized, .provisional, .ephemeral:
				center.add(request) { error in
					if let error {
						Logger.notify.error("notify: refused — \(error.localizedDescription, privacy: .public)")
					} else {
						Logger.notify.notice("notify: posted — \(title, privacy: .public)")
					}
				}
			case .notDetermined:
				// The ask belongs to the first card that has to arrive rather
				// than to launch: a prompt nobody asked for is a prompt nobody
				// grants, and the launch-time ask may have been skipped.
				//
				// Not on a simulator, for the same reason the launch-time ask is
				// skipped there: nothing can answer the prompt, and it arrives as
				// a full-screen system alert over whatever the user is looking at
				// — including BatSign itself, mid-install, which is the one
				// moment this pipeline must not interrupt. Undetermined is the
				// honest state to leave it in there, and the card is dropped with
				// a line saying so rather than silently.
				#if targetEnvironment(simulator)
				Logger.notify.notice("notify: not asked on the simulator, card dropped — \(title, privacy: .public)")
				#else
				center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
					guard granted else {
						Logger.notify.notice("notify: not granted, card dropped — \(title, privacy: .public)")
						return
					}
					center.add(request) { error in
						if let error {
							Logger.notify.error("notify: refused — \(error.localizedDescription, privacy: .public)")
						}
					}
				}
				#endif
			case .denied:
				Logger.notify.notice("notify: notifications are denied, card dropped — \(title, privacy: .public)")
			@unknown default:
				center.add(request)
			}
		}
	}

	/// Withdraw the cards that describe a *pending* install of one app.
	///
	/// The "tap to finish" fallback and the "waiting for power" hold are both
	/// posted under the signed app's uuid. Once the install has landed — or the
	/// job has failed outright — those cards describe an install that no longer
	/// exists, and tapping one starts a second install for an app that is
	/// already on the Home Screen. They go, by the same identifiers they were
	/// posted under.
	func removeInstallNotifications(for bundleIdentifier: String?) {
		guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }

		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.predicate = NSPredicate(format: "identifier == %@", bundleIdentifier)
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		request.fetchLimit = 1
		guard let uuid = (try? Storage.shared.context.fetch(request))?.first?.uuid else { return }

		let identifiers = ["signos.install.\(uuid)", "signos.charging.\(uuid)"]
		let center = UNUserNotificationCenter.current()
		center.removeDeliveredNotifications(withIdentifiers: identifiers)
		center.removePendingNotificationRequests(withIdentifiers: identifiers)
	}

	// MARK: - Background refresh

	#if !targetEnvironment(macCatalyst)
	func scheduleBackgroundRefresh() {
		let request = BGAppRefreshTaskRequest(identifier: "\(Bundle.main.bundleIdentifier!).refresh")
		request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
		try? BGTaskScheduler.shared.submit(request)
	}

	static func registerBackgroundRefresh() {
		BGTaskScheduler.shared.register(
			forTaskWithIdentifier: "\(Bundle.main.bundleIdentifier!).refresh",
			using: nil
		) { task in
			Task { @MainActor in
				await AutoUpdateManager.shared.checkNow(notifyWhenClean: false, silent: true)
				AutoUpdateManager.shared.scheduleBackgroundRefresh()
				task.setTaskCompleted(success: true)
			}
		}
	}
	#endif

	// MARK: - Fetch helpers

	private func _fetchSources() -> [AltSource] {
		let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
		return (try? Storage.shared.context.fetch(request)) ?? []
	}

	private func _fetchSignedApps() -> [Signed] {
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		return (try? Storage.shared.context.fetch(request)) ?? []
	}

	private func _fetchImportedApps() -> [Imported] {
		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Imported.date, ascending: false)]
		return (try? Storage.shared.context.fetch(request)) ?? []
	}
}
