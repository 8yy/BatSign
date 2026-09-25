//
//  AutoSignManager.swift
//  Feather
//
//  Serial background signing queue. Imported/updated/renewal apps are
//  signed with the correct certificate without any user interaction,
//  old versions are cleaned up, and installation is attempted
//  immediately when the active installation method supports it.
//

import Foundation
import CoreData
import UIKit
import OSLog
import IDeviceSwift

@MainActor
final class AutoSignManager: ObservableObject {
	static let shared = AutoSignManager()

	/// The install hand-off, in the console.
	///
	/// Worth saying out loud because everything about it is invisible from inside
	/// the app: whether a dialog the system was asked for appeared is not
	/// reported back, so "why did nothing happen" is otherwise unanswerable on a
	/// device.
	private static let handOffLog = Logger(subsystem: "app.batsign.ios", category: "install")

	enum Reason: String {
		case autoSign
		case autoUpdate
		case renewal
	}

	struct Job: Identifiable {
		let id = UUID().uuidString
		let appUUID: String
		let reason: Reason
		let appIdentifier: String?
		let appName: String?
		var certificate: CertificatePair? = nil
		var options: Options? = nil
		var retryCount: Int = 0
		/// The multi-sign run this job is one of, when it is one.
		///
		/// Carried on the job rather than looked up by app, because the same app
		/// can be signed twice in one session — once on its own and once as part
		/// of a run — and the card has to say which of the two this is.
		var batch: Batch? = nil
	}

	@Published private(set) var queue: [Job] = []
	@Published private(set) var currentJob: Job?
	@Published private(set) var completedCount = 0
	@Published private(set) var lastErrorMessage: String?

	/// How an install ended, for the popup inside the app.
	///
	/// The island says what is happening while it happens and the notification
	/// says it outside the app; this is the same news for someone who is looking
	/// at BatSign, and for anyone who never granted notifications at all. It is
	/// armed whether or not the app is on screen, so a job that finishes while
	/// the user is elsewhere leaves the popup waiting and it is presented the
	/// moment they are back — and never dropped in between.
	struct InstallOutcome: Identifiable, Equatable {
		let id = UUID()
		let title: String
		let message: String
		let isFailure: Bool
	}

	/// The outcomes still owed a popup, oldest first.
	///
	/// A queue, not one optional: two jobs can end while the user is away from
	/// the app, and the second would overwrite the first before it was ever
	/// shown. Each gets its own turn.
	@Published private(set) var pendingOutcomes: [InstallOutcome] = []

	/// The one currently waiting, for the views and for the presenter.
	var installOutcome: InstallOutcome? { pendingOutcomes.first }

	/// Whether an alert can actually be put on a screen right now.
	///
	/// `.active` alone. `.inactive` is a frontmost app with something over it —
	/// the app switcher, a system alert, the install confirmation — and
	/// `present` needs a window that is taking part in that moment to land on.
	/// `.inactive` and `.background` are therefore the same from the alert's
	/// point of view: the notification is the channel that reaches the user
	/// while the app is not presenting, and the alert is armed for the moment it
	/// can.
	private var canPresentAlert: Bool {
		UIApplication.shared.applicationState == .active
	}

	/// The job ended. Say so, in the app, once.
	func reportInstallOutcome(title: String, message: String, isFailure: Bool = false) {
		pendingOutcomes.append(InstallOutcome(title: title, message: message, isFailure: isFailure))
		let how = isFailure ? "failed" : "succeeded"
		Self.handOffLog.notice(
			"install: outcome reported in app — \(title, privacy: .public) (\(how, privacy: .public))"
		)
		presentPendingInstallOutcomeIfPossible()
	}

	/// Tell the user, in the one place they are looking.
	///
	/// The two channels are alternatives, not a pair. The alert is for whoever
	/// has BatSign on screen and presenting; the notification is for whoever
	/// does not, which includes an inactive app whose window is covered by the
	/// install confirmation it just handed iOS. Posting both is what "the
	/// install popup comes more than one" was: a foreground app receives its own
	/// notification as a banner — `AppDelegate.willPresent` asks for one — so a
	/// job that landed while the user was watching BatSign raised the alert
	/// *and* a banner carrying the same sentence, at the same moment, over the
	/// same screen.
	///
	/// The alert stays armed whatever the app's state: an outcome that arrives
	/// while the app cannot present waits in `pendingOutcomes` and is presented
	/// the moment it can, so the news is never dropped by this choice.
	private func announce(title: String, body: String, identifier: String, isFailure: Bool = false) {
		if !canPresentAlert {
			AutoUpdateManager.shared.notify(title: title, body: body, identifier: identifier)
		}
		reportInstallOutcome(title: title, message: body, isFailure: isFailure)
	}

	/// The popup has been read. Nothing is waiting any more.
	func dismissInstallOutcome() {
		guard let shown = _shownOutcomes.first else { return }
		_shownOutcomes.removeFirst()
		// The outcome has to leave both lists, or the presenter — asked a line
		// below — finds it still pending and shows it again immediately.
		pendingOutcomes.removeAll { $0.id == shown.id }
		presentPendingInstallOutcomeIfPossible()
	}

	// MARK: - The two ways a job ends

	/// The app is on the Home Screen. This is the last popup of the job, and it
	/// goes to the one place the user is: a notification for whoever is in another
	/// app, the same sentence in the app for whoever is looking at BatSign — who
	/// never sees the system's own confirmation, because SpringBoard presents that
	/// over whatever is on screen and usually not this.
	///
	/// One function, so the three places that can conclude an install — the
	/// tunnel's synchronous return, the watcher noticing the app land, and the
	/// command-line hook this is tested through — cannot drift apart in what they
	/// say.
	func announceInstallLanded(name: String, identifier: String) {
		announce(
			title: "Installed \(name)",
			body: "The app is ready on your home screen.",
			identifier: "signos.installed.\(identifier)"
		)
	}

	/// The install failed. The same one place, and the message is the reason.
	func announceInstallFailed(name: String, identifier: String, message: String) {
		lastErrorMessage = message
		ActivityLog.shared.log(.failed, app: name, detail: message)
		announce(
			title: "Couldn't Install \(name)",
			body: message,
			identifier: "signos.failed.\(identifier)",
			isFailure: true
		)
		// The job the system granted background time for has ended in failure,
		// and that is what its card should say when it goes away.
		BSJobKeepAlive.shared.failed()
	}

	/// A transfer that did not deliver. The same one place as an install
	/// failure, because it is the same disappointment — and because the shell
	/// the user is watching gives them nothing else. The island card that was
	/// narrating the download is gone within seconds, the row goes back to
	/// "Get", and without this there is no record anywhere that the transfer
	/// ever happened. "I tapped install, it downloaded and then nothing
	/// happened" is that silence.
	func announceDownloadFailed(name: String, identifier: String, message: String) {
		lastErrorMessage = message
		ActivityLog.shared.log(.failed, app: name, detail: message)
		announce(
			title: "Couldn't Download \(name)",
			body: message,
			identifier: "signos.downloadfailed.\(identifier)",
			isFailure: true
		)
	}

	/// The bytes arrived. The Library entry is the receipt the user sees; this
	/// is the line in the timeline that says when the package got here, and it
	/// is what makes a transfer that later failed to sign distinguishable from
	/// one that never downloaded at all.
	func announceDownloadFinished(name: String) {
		ActivityLog.shared.log(.downloaded, app: name)
	}

	/// The package arrived and the signing queue would not take it.
	///
	/// This is its own news and not a download failure: the transfer did its
	/// job and the app *is* in the Library, only unsigned. Saying nothing was
	/// worse than either — the card had already been set to "Signing", a card
	/// only a queued job retires, and a refused queue left it there for as long
	/// as the app ran. That silence is what "it downloaded and then nothing
	/// happened" was.
	func announceDownloadRefused(name: String, identifier: String, message: String) {
		ActivityLog.shared.log(.downloaded, app: name, detail: message)
		announce(
			title: "\(name) Is Ready to Sign",
			body: message,
			identifier: "signos.sign.refused.\(identifier)",
			isFailure: false
		)
	}

	/// The outcomes currently on a screen, in the order they were presented, so
	/// an outcome that arrives while one is up is shown after it rather than
	/// instead of it.
	private var _shownOutcomes: [InstallOutcome] = []

	/// Present the outcome, if there is anyone to present it to.
	///
	/// The alert goes on whatever is on top — a sheet, the signing screen, the
	/// library — because it describes a job that may well have finished while
	/// any of those were open, and an alert attached to the root view is exactly
	/// the one a sheet would hide. When the app is not presenting there is
	/// nothing to present to, so the outcome is left waiting and this is asked
	/// again on the way back to the foreground: the popup the job owes the user
	/// arrives when they are there to read it, and the notification covers the
	/// time in between.
	func presentPendingInstallOutcomeIfPossible() {
		// One alert at a time: stacking them is a lottery about which the OK
		// button dismisses.
		guard _shownOutcomes.isEmpty else { return }
		guard let outcome = pendingOutcomes.first else { return }
		guard canPresentAlert else { return }
		// The top of whatever is presented, and only if it is actually on a
		// screen — `present` on a controller whose view is not in a window is
		// how an alert goes missing without a trace.
		guard let presenter = UIApplication.topViewController(),
			  presenter.view.window != nil else { return }

		_shownOutcomes.append(outcome)

		let alert = UIAlertController(title: outcome.title, message: outcome.message, preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
			Task { @MainActor in
				guard let self else { return }
				// Only if it is still the same news: a later outcome may have
				// been queued while this one was being read.
				if let index = self._shownOutcomes.firstIndex(where: { $0.id == outcome.id }) {
					self._shownOutcomes.remove(at: index)
				}
				if let pendingIndex = self.pendingOutcomes.firstIndex(where: { $0.id == outcome.id }) {
					self.pendingOutcomes.remove(at: pendingIndex)
				}
				self.presentPendingInstallOutcomeIfPossible()
			}
		})

		presenter.present(alert, animated: true) { [weak self] in
			// Refused — something else was mid-presentation. Nothing is lost:
			// the outcome stays pending and the next activation tries again.
			if presenter.presentedViewController !== alert {
				if let index = self?._shownOutcomes.firstIndex(where: { $0.id == outcome.id }) {
					self?._shownOutcomes.remove(at: index)
				}
				return
			}
			// On screen, at last. The line that says the popup arrived, rather
			// than merely that the job ended: an outcome reported while the app
			// is elsewhere waits, and this is the moment it stops waiting.
			Self.handOffLog.notice("install: popup shown in the app — \(outcome.title, privacy: .public)")
		}
	}

	private var _isRunning = false

	/// How the job that has just been processed ended, for the run that queued
	/// it. Read by `_run`, written by `_process`, and false unless the job
	/// reached the install hand-off — a run reports an app as signed, and an app
	/// that stopped before its install was handed over did not land.
	private var _lastJobOutcome = false

	/// Keeps local install servers alive until the system fetches the payload.
	private static var _liveInstallers: [ServerInstaller] = []

	/// The archive working copies that go with the retained servers.
	///
	/// The server streams the package from its handler's work directory, so the
	/// directory must outlive the request; it is thrown away when the server is
	/// released — at the hand-off's end or the expiry — rather than left in tmp
	/// for the next launch's sweep.
	private static var _liveArchiveHandlers: [ObjectIdentifier: ArchiveHandler] = [:]

	private init() {
		UIDevice.current.isBatteryMonitoringEnabled = true
		NotificationCenter.default.addObserver(
			forName: Notification.Name("BatSign.autoInstallRequested"),
			object: nil,
			queue: .main
		) { [weak self] note in
			guard let uuid = note.userInfo?["uuid"] as? String else { return }
			Task { @MainActor in
				await self?._handleInstallRequest(uuid: uuid)
			}
		}

		NotificationCenter.default.addObserver(
			forName: Notification.Name("BatSign.installHandOffEnded"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in self?._endInstallHandOff() }
		}

		// The install confirmation is the system's to present, and it will not
		// present one on behalf of an app it considers inactive — which a job
		// that finished signing while the user was in another app may well look
		// like. The watcher asks for another offer on a timer while the install
		// has produced no answer at all, and this is where it lands.
		NotificationCenter.default.addObserver(
			forName: Notification.Name("BatSign.retryInstallHandOff"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in await self?._offerHandOffAgain() }
		}

		// The offers above have run out. Nothing has come back from the system for
		// an install that is sitting ready, and asking a seventh time would only be
		// noise — so the one thing left is to say so, once.
		NotificationCenter.default.addObserver(
			forName: Notification.Name("BatSign.installHandOffStalled"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in self?._offerHandOffFellBack() }
		}
	}

	// MARK: - Settings

	var isAutoSignEnabled: Bool {
		get { UserDefaults.standard.object(forKey: "BatSign.autoSignEnabled") as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: "BatSign.autoSignEnabled") }
	}

	// MARK: - Per-app certificate pins

	static func pinnedCertificateUUID(for identifier: String) -> String? {
		let pins = UserDefaults.standard.dictionary(forKey: "BatSign.appCertificatePins") as? [String: String] ?? [:]
		return pins[identifier]
	}

	static func setPinnedCertificate(_ uuid: String?, for identifier: String) {
		var pins = UserDefaults.standard.dictionary(forKey: "BatSign.appCertificatePins") as? [String: String] ?? [:]
		if let uuid {
			pins[identifier] = uuid
		} else {
			pins.removeValue(forKey: identifier)
		}
		UserDefaults.standard.set(pins, forKey: "BatSign.appCertificatePins")
	}

	private var _autoDeleteOldVersions: Bool {
		UserDefaults.standard.object(forKey: "BatSign.autoDeleteOldVersions") as? Bool ?? true
	}

	// MARK: - Enqueueing

	/// Queues an app for background signing.
	/// Returns whether the job was taken. The two refusals here — signing
	/// turned off, or an app with no uuid — used to be silent `return`s, and a
	/// caller that had already recorded the work as done (a renewal marking
	/// itself complete at the moment it asked) would never try again.
	@discardableResult
	func enqueue(
		app: AppInfoPresentable,
		reason: Reason = .autoSign,
		certificate: CertificatePair? = nil,
		options: Options? = nil,
		force: Bool = false,
		batch: Batch? = nil
	) -> Bool {
		guard force || isAutoSignEnabled else { return false }
		guard let uuid = app.uuid else { return false }

		let job = Job(
			appUUID: uuid,
			reason: reason,
			appIdentifier: app.identifier,
			appName: app.name,
			certificate: certificate,
			options: options,
			batch: batch
		)
		enqueue(job: job)
		return true
	}

	/// Clones an app: same app, new identity, parallel install.
	///
	/// The new identity is only legal with a wildcard certificate. A
	/// PPQ-protected profile pins its application identifier, and signing a
	/// modified bundle id against it embeds entitlements for the *old*
	/// identifier: the clone builds and looks signed, and installd rejects it
	/// for the mismatch. Those clones are signed under the app's own
	/// identifier instead — same name change, install that actually lands.
	func cloneApp(app: AppInfoPresentable) {
		var options = OptionsManager.shared.options
		let certificate = Storage.shared.getCertificate(from: app)
			?? _certificate(for: app, options: options)

		if certificate?.ppQCheck != true {
			let base = app.identifier ?? UUID().uuidString
			options.appIdentifier = "\(base).clone\(Int.random(in: 100...999))"
		}
		options.appName = "\(app.name ?? "App") \(Int.random(in: 2...9))"
		options.signingOption = .default

		enqueue(app: app, reason: .autoSign, certificate: certificate, options: options, force: true)
	}

	/// Resolves an imported app by uuid and queues it. Safe to call for
	/// every import: duplicates and already signed apps are filtered.
	///
	/// The reason is the caller's to name. An import that arrived as an
	/// automatic update download is the second half of that update, and calling
	/// it a plain import would relabel the card the download began — it would
	/// read "Updating" through the transfer and then say "Signing…" over the
	/// same work.
	///
	/// Returns whether the job was taken. Every `false` used to be a silent
	/// `return`, and a card that had already been set to "Signing" was left on
	/// that phase for as long as the app ran — the app was in the Library and
	/// the island was still promising to sign it. Callers now answer for the
	/// refusal themselves.
	@discardableResult
	func enqueueImported(
		uuid: String,
		reason: Reason = .autoSign,
		batch: Batch? = nil,
		force: Bool = false
	) -> Bool {
		// A package that landed as part of a multi-sign run is signed whatever the
		// automatic-signing toggle says: the user picked these apps by name and
		// pressed the button for them, and a preference about automatic work has
		// no say in work somebody asked for. Same rule as a clone.
		guard force || isAutoSignEnabled else { return false }

		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		guard let app = (try? Storage.shared.context.fetch(request))?.first else { return false }

		return enqueue(app: app, reason: reason, force: force, batch: batch)
	}

	/// Pick up a signing job that a killed process left behind.
	///
	/// The journal names the app, not a package: what was interrupted is the
	/// signing of a Library record, and the record is still there. Deliberately
	/// forced — the job was already running when the process was taken away, and
	/// re-signing it is finishing the user's work, not starting new work.
	func recoverSigning(uuid: String, name: String?) {
		if let app = _resolveApp(uuid: uuid) {
			enqueue(app: app, reason: .autoSign, force: true)
			Self.handOffLog.notice(
				"recovery: signing picked up for \(name ?? uuid, privacy: .public)"
			)
			return
		}

		// Nothing to sign any more — the record went with the process, or the app
		// was deleted while it was being signed. Nothing to pick up.
		BSJobJournal.shared.clear(reason: "signing job has no app")
	}

	private func enqueue(job: Job) {
		// A retry is the one same-app enqueue that is legal while its own
		// processing is still on the stack: the failing job IS `currentJob` when
		// it asks for its second attempt. Every other same-app enqueue while the
		// app is being processed is a duplicate and is refused.
		guard currentJob?.appUUID != job.appUUID || job.retryCount > 0 else { return }
		guard !queue.contains(where: { $0.appUUID == job.appUUID }) else { return }

		// The hold is taken *here*, not inside `_run`.
		//
		// There is a window between the two, and it is the width of a task
		// hand-off: the transfer that produced this job releases its own hold the
		// instant the package has been handed over, and a run loop that has not
		// started yet holds nothing. Suspended in that window — which is what
		// switching apps at the wrong moment does — the process stops with a
		// package on disk and a signature half-applied, and the user's install
		// never arrives. Taken here, the hold is continuous from "there is work"
		// to "the work is done".
		BSJobKeepAlive.shared.begin(BSJobKeepAlive.Reason.job)

		queue.append(job)

		// The check and the set must be one act on this actor. Setting the flag
		// inside the spawned task left a gap the width of a task hand-off, and
		// every enqueue that ran in that gap believed it was the first: N jobs
		// enqueued in one turn spawned N run loops over one queue, each
		// overwriting `currentJob` while the others were mid-sign, each tearing
		// down the keepalive hold the moment its own loop drained, and the
		// island swapped cards between jobs that were all still running.
		if !_isRunning {
			_isRunning = true
			Task(priority: .userInitiated) { await _run() }
		}
	}

	// MARK: - A run of apps

	/// Whether this app is on the queue already, or being signed right now.
	///
	/// A multi-sign run asks before it enqueues: the queue refuses a second job
	/// for an app it is already working on — which is the right answer for it and
	/// the wrong one for a run, because a run would show that app as one of its
	/// own and wait for a completion that belongs to somebody else's job.
	func isBusy(_ uuid: String) -> Bool {
		currentJob?.appUUID == uuid || queue.contains { $0.appUUID == uuid }
	}

	/// Drops every job of a run that has not started yet, and says how many.
	///
	/// The job being signed right now is kept on purpose. Signing cannot be stopped
	/// halfway — a half-written bundle in `Signed/` is worse than a finished one —
	/// and it is the app the next completion will report to the run.
	@discardableResult
	func cancelQueued(batchID: String) -> Int {
		let before = queue.count
		queue.removeAll { $0.batch?.id == batchID }
		let dropped = before - queue.count
		if dropped > 0 {
			Self.handOffLog.notice(
				"queue: \(dropped, privacy: .public) job(s) dropped from a cancelled run"
			)
		}
		return dropped
	}

	// MARK: - Queue processing

	private func _run() async {
		defer { _isRunning = false }

		// Hold the app up for the whole queue, not per job. Signing is minutes
		// of in-process CPU work and the hand-off after it is a local server;
		// without this, leaving the app mid-sign suspended the process and the
		// job died silently.
		BSJobKeepAlive.shared.begin(BSJobKeepAlive.Reason.job)
		defer { BSJobKeepAlive.shared.end(BSJobKeepAlive.Reason.job) }

		while let job = queue.first {
			queue.removeFirst()
			currentJob = job
			await _process(job)
			let outcome = _lastJobOutcome
			currentJob = nil
			completedCount += 1

			// The run this job was part of is told, so its own progress is the
			// queue's own result rather than a second opinion about it.
			if let batch = job.batch {
				BSBulkSign.shared.noteFinished(batch: batch, succeeded: outcome)
			}

			// A job that re-enqueued itself for its one retry is not over. The
			// retry intends to keep the card it already has — it said "Trying
			// once more" — and retiring here ends that card before the retried
			// job's `ensure` can build the replacement. The two race, and the
			// user reads it as the island blinking off and on over the same job.
			if queue.contains(where: { $0.appUUID == job.appUUID && $0.retryCount > job.retryCount }) {
				continue
			}
			_retireCard(for: job)
		}
	}

	/// The job is over. The card must be too.
	///
	/// This is the guarantee, and it is deliberately not left to the paths
	/// inside `_process` to remember. The failures that strand an island are the
	/// quiet ones, and there are several: signing refused for want of a
	/// certificate, an install held back until a charger is connected, an install
	/// method that does not install at all. Every one of those returns without an
	/// outcome, and every one of them used to leave the card sitting on
	/// "Signing" — after the screen had said the job was doing something, and for
	/// as long as the app kept running. A stale card is not dismissed by iOS; it
	/// is just stale, and it stays.
	///
	/// A hand-off still being followed is the one exception, and it is not an
	/// outcome either: the watcher owns the card from the moment the package is
	/// handed over, and it is the thing that knows when the app lands.
	private func _retireCard(for job: Job) {
		// The hand-off is the last moment the journal's record for this job is
		// worth anything. Its one purpose is resuming interrupted work, and
		// after the package is with iOS there is nothing to resume — resuming
		// it would re-sign an app that is on its way to the Home Screen or
		// already on it: the second install prompt, the second card, and the
		// "Failed" report after a success that the user described. The
		// watcher's ledger owns the follow from here, so the record goes now,
		// keyed to this job so a transfer that is still running is untouched.
		BSJobJournal.shared.clearIf(jobUUID: job.appUUID, bundleID: job.appIdentifier)

		// The job is over, so anything the journal was holding for it is over
		// too — but only when no other transfer is in flight, because a second
		// download may have started while this one was finishing.
		if DownloadManager.shared.downloads.isEmpty {
			BSJobJournal.shared.clear(reason: "job finished")
		}

		guard !BSInstallWatcher.shared.isFollowing else { return }
		// Keyed by the app when it is known, so a transfer that started while
		// this job was finishing is not swept up with it.
		if let identifier = job.appIdentifier, !identifier.isEmpty {
			LiveStatus.end(appID: identifier)
		} else {
			LiveStatus.end()
		}
	}

	private func _process(_ job: Job) async {
		// Cleared here, so every early return below is already the honest answer
		// and only the path that really finishes the job has to say otherwise.
		_lastJobOutcome = false

		guard let app = _resolveApp(uuid: job.appUUID) else {
			// The record this job was queued for is gone — deleted from the
			// Library, or replaced by a newer import while the job waited. The
			// work will not happen, and the card that announced it must not be
			// left standing on it.
			LiveStatus.finish(
				success: false,
				appName: job.appName ?? "App",
				detail: "The app to sign is no longer in the Library",
				appID: job.appIdentifier ?? ""
			)
			return
		}

		let options = job.options ?? OptionsManager.shared.options
		let certificate = job.certificate ?? _certificate(for: app, options: options)

		if certificate == nil && options.signingOption == .default {
			let reason = "No valid certificate available for automatic signing."
			lastErrorMessage = reason
			// The failure is written down as well as announced. Every other way a job
			// can end leaves a line in the timeline; this one left nothing, so an
			// import that could not be signed was indistinguishable from one that was
			// never imported at all.
			ActivityLog.shared.log(.failed, app: job.appName ?? app.name ?? "App", detail: reason)
			// The half that reaches a user who is somewhere else, and the half
			// that reaches a user looking at BatSign — which is a popup and not a
			// banner, because this one is news and not an alarm. On its own the
			// notification left the second half with nothing: not a popup, not a
			// line anywhere, and no signed app either. A signing job that cannot
			// sign is the job the user most needs told about, and "it downloaded
			// and then nothing happened" is what its silence is called.
			announce(
				title: "Couldn't Sign \(job.appName ?? app.name ?? "App")",
				body: "No certificate is available for automatic signing. Import a certificate in Settings, then sign it again.",
				identifier: "signos.sign.failed.\(job.appUUID)",
				isFailure: true
			)
			// The card said what the job was doing and the job has stopped, so the
			// card has to say that too. Left alone it stays on "Signing" for as
			// long as the app runs — a still card on a dead job, which is the one
			// thing this feature must never produce.
			LiveStatus.finish(
				success: false,
				appName: job.appName ?? app.name ?? "App",
				detail: "No certificate available",
				appID: job.appIdentifier ?? app.identifier
			)
			return
		}

		// The card describes this half of the job as well as the download half.
		//
		// Signing is minutes of work with nothing to report, and without this the
		// card is left saying whatever the download last said — which is how an
		// island reads "Preparing" through an entire re-sign, or "Installing" for
		// an app that is still being signed.
		//
		// An update and a renewal are the same work as a first signing, and they
		// are named as the phase that exists for them. Both re-sign an app that is
		// already in the Library, at the user's own request — and a card that says
		// "Signing" for them is describing a first install of an app the user
		// already has, in the one place that is supposed to say which job is
		// running.
		let phase: DownloadActivityAttributes.ContentState.Phase
		let phaseDetail: String
		switch job.reason {
		case .renewal:
			phase = .updating
			phaseDetail = "Renewing the signature"
		case .autoUpdate:
			phase = .updating
			phaseDetail = "Signing the update"
		case .autoSign:
			phase = .signing
			phaseDetail = "Signing…"
		}			// A job that is one app of a run tells the card so before it addresses
			// it. The run's apps are one thing on the island — one card, retargeted
			// as each app starts, which is the difference between a card that walks
			// through a run and a card that blinks off and on again for every app
			// in it. A source app's name is registered here too, because the
			// identifier it signs under is not the transfer id the run declared.
			if job.batch != nil {
				LiveStatus.noteRunCurrent(job.appIdentifier ?? app.identifier ?? "")
			}
			LiveStatus.ensure(
				appID: job.appIdentifier ?? app.identifier ?? "",
				appName: job.appName ?? app.name ?? "App",
				phase: phase,
				detail: _cardDetail(phaseDetail, job.batch),
				mode: Self.installMode,
			// The run's own count, which is what the island shows as "+5 more":
			// one app of eight is a queue, and the card is the only place the
			// whole of it is visible while it runs.
			queued: job.batch?.remaining
		)

		// Written down before the work starts. A signing job that is not a
		// transfer leaves nothing on disk behind it, so a kill during these
		// minutes — memory pressure, the user swiping the app away — has nothing
		// to be discovered from. This is the record that says which app was being
		// signed, and it is what the next launch signs.
		if BSJobJournal.shared.record(signing: job.appUUID, name: job.appName ?? app.name) {
			BSBackgroundTasks.shared.scheduleJobContinuation()
		}

		// The pipeline's own stages, on the card, as they begin.
		//
		// Signing is the one stretch of this job that reports nothing of its own —
		// no bytes, no fraction — and it is the longest. A card holding one word
		// for the whole of it is indistinguishable from a card that has stopped,
		// which is what "it parks on Signing" is: the island says "Signing", four
		// minutes pass, and nothing on it moves. Each stage below is a step the
		// pipeline really takes, named the moment it starts, and the words live on
		// `SigningHandler.Stage` so the card and the work cannot drift apart.
		//
		// Deliberately *not* forced. A stage change is a detail change inside one
		// phase, and a burst of pushes that bypass the rate limit is what exhausts
		// ActivityKit's update budget — after which the system drops every later
		// update and the card really does freeze. The gap is two seconds while
		// these run, so a stage still lands the moment it is worth reading.
		let cardAppName = job.appName ?? app.name ?? "App"
		let cardAppID = job.appIdentifier ?? app.identifier ?? ""
		// Read here, on the main actor, because the stage closure runs wherever
		// the signing pipeline is — which is not here.
		let cardMode = Self.installMode

		var signingError: Error?
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			FR.signPackageFile(
				app,
				using: options,
				icon: nil,
				certificate: certificate,
				onStage: { stage in
					LiveStatus.update(
						phase: phase,
						appName: cardAppName,
						progress: 0,
						detail: stage.detail,
						progressKnown: false,
						appID: cardAppID,
						mode: cardMode
					)
				}
			) { error in
				signingError = error
				continuation.resume()
			}
		}
		if let signingError {
			lastErrorMessage = signingError.localizedDescription
			ActivityLog.shared.log(.failed, app: job.appName ?? "App", detail: signingError.localizedDescription)

			// one automatic retry — transient failures (locks, disk spikes) recover
			if job.retryCount < 1 {
				var retry = Job(
					appUUID: job.appUUID,
					reason: job.reason,
					appIdentifier: job.appIdentifier,
					appName: job.appName,
					certificate: job.certificate,
					options: job.options
				)
				retry.retryCount = job.retryCount + 1
				// The card stays up for the second attempt, and it says so rather
				// than repeating "Signing…" as if nothing had happened.
				LiveStatus.update(
					phase: phase,
					appName: job.appName ?? app.name ?? "App",
					progress: 0,
					detail: "Trying once more",
					progressKnown: false,
					force: true,
					appID: job.appIdentifier ?? app.identifier
				)
				enqueue(job: retry)
				return
			}

			AutoUpdateManager.shared.notify(
				title: "Couldn't Install \(job.appName ?? "App")",
				body: "Open BatSign and try again.",
				identifier: "signos.failed.\(job.appUUID)"
			)
			// The job is over and it did not do what the card said it was doing.
			// Every terminal path owes the card an ending: a job that stops
			// without one leaves the island announcing work that is not running.
			LiveStatus.finish(
				success: false,
				appName: job.appName ?? app.name ?? "App",
				detail: signingError.localizedDescription,
				appID: job.appIdentifier ?? app.identifier
			)
			AutoUpdateManager.shared.updateBadgeFromState()
			return
		}

		guard let identifier = job.appIdentifier ?? app.identifier else {
			LiveStatus.finish(
				success: false,
				appName: job.appName ?? app.name ?? "App",
				detail: "The signed app has no identity to install",
				appID: ""
			)
			return
		}

		// The Library row SigningHandler writes carries the identifier the app
		// was actually signed with, and signing can change it — a clone signs
		// under `options.appIdentifier`, which is not the identifier the job was
		// enqueued under. Looking the result up by the original identifier is
		// how a clone used to resolve to nothing at all (imported: "Signing did
		// not produce an app to install") or to the pre-existing original row
		// (already signed: the original got installed again and the clone row
		// sat in the Library, orphaned, forever).
		let signedIdentifier = options.appIdentifier ?? identifier
		var signedApps = _signedApps().filter { $0.identifier == signedIdentifier }
		if let newestEntry = signedApps.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
			// PPQ-protected apps change identifiers on every sign; catch
			// those old versions by display name so they never pile up.
			let sameName = _signedApps().filter {
				$0.uuid != newestEntry.uuid && $0.name != nil && $0.name == newestEntry.name
			}
			for extra in sameName where !signedApps.contains(where: { $0.uuid == extra.uuid }) {
				signedApps.append(extra)
			}
		}
		guard let newest = signedApps.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) else {
			lastErrorMessage = "Signing did not produce a new app entry."
			LiveStatus.finish(
				success: false,
				appName: job.appName ?? app.name ?? "App",
				detail: "Signing did not produce an app to install",
				appID: identifier
			)
			return
		}

		// The install half addresses the app by the identity it was signed with,
		// and signing can change it — a PPQ-protected package, a clone, an
		// identity from the options. Teaching the card that name now is what lets
		// the install progress and the landing keep driving the card the download
		// began, instead of pushing into a name the card has never heard of and
		// leaving it frozen on the signing phase for ever.
		if let signedIdentifier = newest.identifier, !signedIdentifier.isEmpty {
			LiveStatus.addAlias(signedIdentifier, for: identifier)
		}

		switch job.reason {
		case .renewal:
			ActivityLog.shared.log(.renewed, app: newest.name ?? identifier)
		default:
			ActivityLog.shared.log(.updated, app: newest.name ?? identifier, detail: newest.version)
		}

		let handedOff = await _attemptSilentInstall(newest, batch: job.batch)

		// The build this one replaces is retired *after* the hand-off, and off the
		// main thread.
		//
		// It used to run between the signature and the install, on the main actor,
		// and removing a large bundle is thousands of file system calls: the card
		// sat on "Signing" for the whole of it — after the app was demonstrably
		// signed — while the interface stopped answering taps. Nothing about the
		// hand-off needs the old copy gone first, because the watcher's baseline is
		// what the *device* has, not what the Library holds.
		if _autoDeleteOldVersions {
			await _retireBuilds(signedApps, keeping: newest, source: app)
		}

		// The one path that finished the job: the signed app was handed to the
		// installer, which is what "signed" means to the run that asked for it.
		_lastJobOutcome = handedOff
		AutoUpdateManager.shared.updateBadgeFromState()
	}

	/// What a card says for a job, with the job's place in a multi-sign run.
	///
	/// "Signing · 2 of 5". The run is what the user asked for — one button, five
	/// apps — and while it is happening the card is the only place the whole of it
	/// exists: the app they are watching is one of five, and a card that says only
	/// "Signing" makes the other four invisible.
	private func _cardDetail(_ base: String, _ batch: Batch?) -> String {
		guard let batch else { return base }
		return "\(base) · \(batch.position)"
	}

	/// Retires the builds a job replaced: the files off the main thread, the
	/// records on it.
	///
	/// `deleteApp` is both halves at once and they belong to different threads —
	/// the file system half is the expensive one and has no business on the main
	/// actor, and the Core Data half has no business anywhere else. Splitting them
	/// is what keeps a re-sign from blocking the app for the length of a disk
	/// operation.
	private func _retireBuilds(
		_ apps: [Signed],
		keeping newest: Signed,
		source: any AppInfoPresentable
	) async {
		for old in apps where old.uuid != newest.uuid {
			await _discardFiles(of: old)
			Storage.shared.deleteApp(for: old)
		}

		// The package that was signed, when it was an ordinary import rather than a
		// re-sign of something already in the Library: the signed copy is the one
		// to keep.
		if !source.isSigned {
			await _discardFiles(of: source)
			Storage.shared.deleteApp(for: source)
		}
	}

	/// The on-disk half of a retirement, away from the main actor.
	private func _discardFiles(of app: any AppInfoPresentable) async {
		guard let directory = Storage.shared.getUuidDirectory(for: app) else { return }
		await Task.detached(priority: .utility) {
			try? FileManager.default.removeItem(at: directory)
		}.value
	}

	// MARK: - Install

	/// App Store-style finishing move: after signing, the install happens
	/// with the least friction the active method allows. Paired-device
	/// installs are fully silent; local-server installs either fire the
	/// system prompt immediately (app in foreground) or present a
	/// "tap to install" notification that completes on open.
	/// Whether the install was handed over without an error.
	///
	/// Returned rather than assumed, because a run of apps counts an app as signed
	/// only when the signed bundle really reached the installer: "Signing" with
	/// nothing to install is the failure a person most wants told apart from a
	/// landing.
	@discardableResult
	private func _attemptSilentInstall(_ app: Signed, batch: Batch? = nil) async -> Bool {
		let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
		guard method == 0 || method == 1 else { return false }

		// charging-only preference: hold the install until power is connected
		if UserDefaults.standard.object(forKey: "BatSign.installChargingOnly") as? Bool ?? false {
			let state = UIDevice.current.batteryState
			guard state == .charging || state == .full else {					AutoUpdateManager.shared.notify(
						title: "\(app.name ?? "App") is waiting for power",
						body: "Connect your device to a charger to finish installing.",
						identifier: "signos.charging.\(app.uuid ?? UUID().uuidString)"
					)
					return false
				}
		}

		ArchiveHandler.fastestCompressionOverride = true
		defer { ArchiveHandler.fastestCompressionOverride = false }

		// What the device had before the hand-off, taken now: by the time the
		// system reports anything, the build being replaced may already be gone
		// and there would be nothing left to compare against.
		if let identifier = app.identifier {
			BSInstallWatcher.shared.arm(identifier, expecting: _builtIdentity(of: app))
		}

		// From here the work moves out of the download and into signing and
		// installing, and the live card follows it instead of disappearing. The
		// hand-off has no fraction yet, so it is announced as a phase and the
		// real install percentage replaces it as soon as the system reports one.
		//
		// `ensure` and not `update`: this can be the first thing that runs — an
		// install started from a notification has no download card behind it —
		// and a job with no card is a job the user cannot see.
		LiveStatus.ensure(
			appID: app.identifier ?? "",
			appName: app.name ?? "App",
			phase: .installing,
			detail: _cardDetail(
				method == 1 ? "Installing over the tunnel" : "Handing the package to iOS",
				batch
			),
			mode: Self.installMode,
			queued: batch?.remaining
		)

		do {
			if method == 1 {
				let viewModel = InstallerStatusViewModel(isIdevice: true)
				let handler = ArchiveHandler(app: app, viewModel: viewModel)
				// The tunnel's install is synchronous: when it returns — or when
				// it throws — nothing is streaming from the working copy any more,
				// and the full app copy it holds can go now rather than on the next
				// launch's sweep.
				defer { handler.clean() }
				try await handler.move()
				let packageUrl = try await handler.archive()

				let proxy = InstallationProxy(viewModel: viewModel)
				try await proxy.install(at: packageUrl, suspend: false)

				ActivityLog.shared.log(.installed, app: app.name ?? "App")

				// The watcher armed above is the other way this same landing can
				// be told: a return to the foreground while `install` was running
				// reconciles the ledger and reports it. Announcing from here too,
				// unconditionally, is how one tunnel install produced two
				// identical "Installed" popups — the dedupe lives in the ledger
				// both paths are supposed to honour, and this path now does.
				let landingIdentifier = app.identifier ?? app.uuid ?? UUID().uuidString
				let landingBuild = _builtIdentity(of: app)?.described
				if !BSInstallLedger.hasBeenReported(landingIdentifier, build: landingBuild) {
					BSInstallLedger.noteReported(landingIdentifier, build: landingBuild)
					announceInstallLanded(
						name: app.name ?? "App",
						identifier: landingIdentifier
					)
				}

				// The tunnel's install is synchronous — the call above returned only
				// once installd said it was done — so there is nothing to follow and
				// the armed baseline is not needed.
				BSInstallWatcher.shared.cancel(app.identifier)
				LiveStatus.finish(
					success: true,
					appName: app.name ?? "App",
					detail: "Installed on this iPhone",
					appID: app.identifier
				)
			} else {
				try await _serverInstall(app)
				// iOS takes over from here: it fetches the package from our own
				// server and installs it, at its own pace, possibly with the user
				// already on the Home Screen. The watcher follows that to its end
				// instead of leaving a card at "Installing" until iOS times it out.
					if let identifier = app.identifier {
						BSInstallWatcher.shared.follow(
							identifier,
							name: app.name ?? "App",
							expecting: _builtIdentity(of: app)
						)
					}
				}
				return true
			} catch {
			announceInstallFailed(
				name: app.name ?? "App",
				identifier: app.uuid ?? UUID().uuidString,
				message: error.localizedDescription
			)
				BSInstallWatcher.shared.cancel(app.identifier)
				LiveStatus.finish(
					success: false,
					appName: app.name ?? "App",
					detail: error.localizedDescription,
					appID: app.identifier
				)
				return false
			}
		}

	/// How this job is being packaged, in the words the setting uses.
	///
	/// The island shows it, because the modes are not equally quick and the wait
	/// is not equally explainable: Turbo spends its time compressing and then
	/// installs fast, Speed is the other way round, and "Preparing" with no mode
	/// next to it is what makes a correct wait look like a stall.
	static var installMode: String {
		CompressionMode.stored.label
	}

	/// What the build this job made is called.
	///
	/// Read off the signed bundle on disk — the bytes that are about to be handed
	/// to installd — rather than out of the record, because the record is written
	/// before the final Info.plist is: a job signed with a version override keeps
	/// whatever the importer happened to see. The record is the fallback for a
	/// bundle that cannot be read at all, so the answer is never worse than it was
	/// before this existed.
	///
	/// Both numbers are carried, because the device does not always report both:
	/// measured on the runtime this app is built against, the system's registry
	/// answers the build number and has no short version at all. It is used for one
	/// thing, and it is the thing that ends an install honestly — the watcher
	/// compares it against the build on the device, and a match that was not there
	/// before the hand-off is the install being over.
	private func _builtIdentity(of app: Signed) -> BuildIdentity? {
		if let directory = Storage.shared.getAppDirectory(for: app),
		   let identity = BSInstallProbe.buildIdentity(at: directory.path) {
			return identity
		}

		guard let version = app.version, !version.isEmpty else { return nil }
		return BuildIdentity(version: version, build: nil)
	}



	private func _serverInstall(_ app: Signed) async throws {
		let viewModel = InstallerStatusViewModel(isIdevice: false)
		let handler = ArchiveHandler(app: app, viewModel: viewModel)
		try await handler.move()
		let packageUrl = try await handler.archive()

			let installer = try ServerInstaller(app: app, viewModel: viewModel)
			installer.packageUrl = packageUrl
			Self._retainInstaller(installer)
			Self._liveArchiveHandlers[ObjectIdentifier(installer)] = handler

		guard let url = URL(string: installer.iTunesLink) else { return }

		// The hand-off is asked for from wherever the app happens to be, and it is
		// asked for again until the system answers.
		//
		// The confirmation the user sees does not belong to this app — installd
		// and SpringBoard present it, and installd is what fetches the package
		// from the server above — so nothing about it needs BatSign on screen. The
		// request is not gated on being in the foreground any more, and that gating
		// was the bug: every install that finished signing while the user was in
		// another app — which is every install worth having — was treated as
		// impossible, and arrived as a notification telling them to come back and
		// tap instead of as a dialog over whatever they were looking at.
		//
		// A dialog asked for from the background can be declined — the system
		// simply will not open the link — and the app is never told whether a
		// dialog was shown. What it *is* told is whether the request was taken,
		// and that is what the retry is keyed on: the watcher asks again while
		// nothing at all has come back from the system, and every ask records its
		// own result, so a request the system accepted is never repeated. Asking a
		// second time about a request that was already taken is a second
		// confirmation for the user and a duplicate request for installd, which is
		// the error that arrived after the popup arrived twice.
		let isForeground = UIApplication.shared.applicationState == .active

		// Whether the system *took* the request is recorded, and it is worth
		// recording: it is the only thing that separates "the dialog is on its
		// way" from "nothing out there will ever open this link" — the app is
		// not told whether a dialog appeared, but it is told this. When a device
		// test shows no popup, this line says which of the two it was.
		let accepted = await UIApplication.shared.open(url)

		_pendingHandOff = PendingHandOff(url: url, app: app, accepted: accepted)

		Self.handOffLog.notice(
			"install: hand-off asked for \(app.name ?? "App", privacy: .public) (\(isForeground ? "foreground" : "background", privacy: .public)), taken by the system: \(accepted, privacy: .public)"
		)

		ActivityLog.shared.log(
			.installed,
			app: app.name ?? "App",
			detail: isForeground ? "install prompt asked for" : "install prompt asked for in the background"
		)

		// Nothing is posted from here. The notification is the last resort, and the
		// watcher is the only thing that can tell when the last resort has been
		// reached: it is what watches for the system's answer, and it is what asks
		// for another offer while there is no answer to watch.
		//
		// The result of the open is deliberately not trusted either way — it
		// reports whether the request was taken, not whether a dialog was shown.

		// The card stays up rather than being retired here. The job is not over —
		// it is being offered to installd — and a card that ends while the install
		// it describes has not happened is the same lie as one parked at 100%.
		LiveStatus.ensure(
			appID: app.identifier ?? "",
			appName: app.name ?? "App",
			phase: .installing,
			detail: "Installing…",
			mode: Self.installMode
		)
	}

	/// A hand-off offered to the system: the link to open, the app it belongs to,
	/// and what the system did with the last ask.
	///
	/// `accepted` is the only thing the app is ever told, and it is what decides
	/// whether another offer is worth making. An ask the system took is a request
	/// installd and SpringBoard are already handling and a dialog already on its
	/// way to the user; asking again does not produce that dialog a second time —
	/// it presents a *second* one, and a second install request for a bundle
	/// already being installed is what iOS answers with an error. An ask the
	/// system refused is the case the retry schedule was built for: nothing out
	/// there will open the link until it is asked again.
	private struct PendingHandOff {
		let url: URL
		let app: Signed
		var accepted: Bool
	}

	private var _pendingHandOff: PendingHandOff?

	/// The user is back in the app.
	///
	/// Three things can be true at once and all three are checked: an install may
	/// have finished while we were suspended, a hand-off may be waiting on
	/// exactly this moment, and the island may be holding a card that belongs to
	/// neither.
	/// The app was suspended while a transfer ran; the card on the island is
	/// showing whatever the last push said.
	///
	/// A live activity cannot update itself and a suspended app cannot push, so
	/// the bytes that arrived while the process was away are invisible to the
	/// card: it holds the fraction it had when the app went under — usually 0%,
	/// because that is where a transfer starts — and it goes on holding it
	/// through the whole of a download that has long since finished. Nothing on
	/// the island is wrong, exactly; it is simply old, and old is what "stuck"
	/// means.
	///
	/// A push is free the instant the app is up again, so the truth is re-sent
	/// here: the real fraction, the real byte count, the real rate, measured
	/// from what actually arrived.
	func refreshLiveCardForTransfers() {
		// Before the card is corrected, the one question a suspension makes
		// unanswerable is asked: did anything actually stop while the screen was
		// locked? The stall sweep is a runloop timer and a suspended app runs no
		// timers, so a socket that died during the lock was invisible until a
		// full sweep after the user was back — with the island parked on its
		// last number for all of it, which is the "it parks on a number again
		// when I come back" report. Asked here, the answer lands before the
		// card is re-sent, so what goes up is the truth either way: a moving
		// transfer's real fraction, or a stopped one's revival.
		DownloadManager.shared.recheckStalledTransfers()

		for download in DownloadManager.shared.downloads {
			// A transfer whose bytes have already arrived is still in the list —
			// it is dropped only when the import reports back — and it is no
			// longer a download. Re-sending a `.downloading` frame for it
			// overwrote the `.unpacking` card the delegate just published, and
			// the island went backwards: "Preparing the package" replaced by an
			// old fraction and a dead rate.
			if download.hasFinishedTransferring { continue }

			// Whether this transfer has moved a byte recently enough that its
			// fraction is still a reading rather than a memory.
			//
			// The card was re-sent here on every return with `force: true` and
			// the stored fraction, and a fresh freshness date went with it. So a
			// transfer that stopped while the screen was locked was painted back
			// onto the island at whatever number it reached, marked live —
			// undoing the one thing the stale handling exists to do, because the
			// card was no longer stale, it was freshly wrong. A number nobody
			// measured any more is not sent at all: the phase goes up with no
			// figure, which is exactly what the card does when it has nothing to
			// measure, and the revival that the recheck above started will
			// supply a real one.
			let moving = DownloadManager.shared.isTransferMoving(download)
			let total = download.expectedBytes

			LiveStatus.update(
				phase: .downloading,
				appName: download.cardName,
				progress: moving ? download.transferProgress : 0,
				detail: moving ? DownloadManager.transferDetail(download) : "Reconnecting…",
				queued: max(DownloadManager.shared.downloads.count - 1, 0),
				progressKnown: moving && total > 0,
				force: true,
				appID: download.liveID,
				mode: Self.installMode
			)
		}
	}

	func handleForeground() {
		BSInstallWatcher.shared.recheck()
		// And the record of any hand-off this process does not hold: an install
		// that landed while the app was suspended or dead is settled here, before
		// the sweep below takes its card away without a word.
		BSInstallWatcher.shared.reconcile()
		retireRedundantImports()
		// A job that ended while the user was elsewhere owes them its popup, and
		// this is the first moment there is anywhere to put it.
		presentPendingInstallOutcomeIfPossible()
		// A card that was frozen while the app was suspended is corrected here,
		// before the user has a chance to read it as stalled.
		refreshLiveCardForTransfers()
	}

	/// Remove imported records that a signed copy has made redundant.
	///
	/// A download that could not be signed — no valid certificate, or the app
	/// closed in the middle of the job — leaves its import behind, and every
	/// later download of the same app leaves another one. The Library keeps them
	/// all: the app appears once as itself and once per stale import, each with
	/// its own GET, which is what a library "full of duplicates" is, and every
	/// one of them is a row that offers to sign something already signed.
	///
	/// An import is redundant the moment a signed copy of the same app and
	/// version exists, because the signed copy is the one that installs. The
	/// check is deliberately narrow:
	///
	///  * only an *imported* record is ever removed — a signed one is a result
	///    the user made;
	///  * only when its app *and* its version are already signed, so a second
	///    build with a version of its own is kept;
	///  * never the only copy of an app, which is the record the Sign button
	///    works from when nothing has been signed yet.
	///
	/// Run at launch and on every return to the foreground, which is also what
	/// clears the ones an earlier build left behind.
	func retireRedundantImports() {
		let imported = (try? Storage.shared.context.fetch(Imported.fetchRequest())) ?? []
		guard !imported.isEmpty else { return }

		let signed = _signedApps()
		guard !signed.isEmpty else { return }

		var retired = 0
		for app in imported {
			guard let identifier = app.identifier, !identifier.isEmpty else { continue }
			let version = app.version ?? ""
			let superseded = signed.contains { signedApp in
				signedApp.identifier == identifier && (signedApp.version ?? "") == version
			}
			guard superseded else { continue }
			Storage.shared.deleteApp(for: app)
			retired += 1
		}

		guard retired > 0 else { return }
		Self.handOffLog.notice(
			"imports: retired \(retired, privacy: .public) stale imported record(s)"
		)
	}

	/// Keep holding up the process, whatever state it is in.
	///
	/// Called on the way out to the background. The holds that matter are
	/// ref-counted and already taken by whatever is running, but an audio session
	/// that was interrupted while the app was in the foreground — a call, another
	/// app taking the output — leaves a job that is about to be suspended with
	/// nothing keeping it up. Asking for the holds to be re-asserted costs
	/// nothing when they were never lost.
	func handleBackground() {
		BSJobKeepAlive.shared.reaffirm()
	}

	/// Offer a refused install hand-off again.
	///
	/// The confirmation belongs to installd and SpringBoard, not to this app: the
	/// app only asks. A backgrounded app's request can be quietly declined — the
	/// open comes back false and nothing is shown — and the app is never told
	/// whether a dialog appeared. So the watcher asks for another attempt on a
	/// timer, and this is where the timer lands.
	///
	/// What it must not do is ask again about a request the system already took.
	/// The distinction is not cosmetic: each accepted open is a fresh request, and
	/// a fresh request for an install already in hand is presented to the user as
	/// another confirmation — "the install popup comes more than one" — and
	/// answered by installd as a duplicate, with an error. That is what asking
	/// again on a timer while `hasSeenSystemProgress` was still false did: progress
	/// only becomes visible *after* the user confirms, so the offers kept firing
	/// through exactly the window in which the first confirmation was on screen
	/// and the system had already said yes.
	///
	/// The ask's own result is therefore kept, and it is the gate: a request the
	/// system refused is worth repeating, a request it accepted is not.
	private func _offerHandOffAgain() async {
		guard let pending = _pendingHandOff else { return }
		guard BSInstallWatcher.shared.isFollowing else {
			_pendingHandOff = nil
			return
		}
		// Already taken by the system — the dialog is with the user, and a second
		// ask would be a second prompt for an app that is on its way in.
		guard !pending.accepted else {
			Self.handOffLog.notice("install: offer skipped — the system took the first ask")
			return
		}
		// Already installing — a second offer would be a second prompt as well, and
		// this is the signal for it once the system has started reporting.
		guard !BSInstallWatcher.shared.hasSeenSystemProgress else {
			Self.handOffLog.notice("install: offer skipped — the system is already installing it")
			return
		}

		let accepted = await UIApplication.shared.open(pending.url)

		// The answer belongs to the hand-off that was asked about, and only if that
		// is still the one being held: the system can take a moment, and the job can
		// end — or a second one begin — while it does. Writing the flag to a copy of
		// a hand-off that is no longer the current one would mark the wrong job.
		if _pendingHandOff?.url == pending.url {
			_pendingHandOff?.accepted = accepted
		}

		guard accepted else {
			Self.handOffLog.notice(
				"install: hand-off offered again and the system would not take it (\(pending.app.name ?? "App", privacy: .public))"
			)
			return
		}
		Self.handOffLog.notice("install: hand-off asked again (\(pending.app.name ?? "App", privacy: .public))")
		ActivityLog.shared.log(.installed, app: pending.app.name ?? "App", detail: "install prompt offered again")
	}

	/// Every offer has been made and the system has still said nothing.
	///
	/// The dialog that was asked for while the user was elsewhere can be refused
	/// without a word, and there is no way to tell that apart from a dialog that
	/// appeared and was dismissed — so after several asks the honest thing is to
	/// stop asking and say where the install is. It is not rebuilt: the package,
	/// the server and the installer are all still standing, so the tap that
	/// finishes it happens immediately when it comes.
	private func _offerHandOffFellBack() {
		guard let pending = _pendingHandOff else { return }
		guard BSInstallWatcher.shared.isFollowing else {
			_pendingHandOff = nil
			return
		}
		// Already accepted once — a notification would be news of an install
		// that is already arriving.
		guard !BSInstallWatcher.shared.hasSeenSystemProgress else { return }

		// One channel, and the right sentence for it. Outside, the notification is
		// the only thing that can reach the user and it is what carries the action,
		// so it is posted and the in-app half says where to find it. Inside, the
		// notification is suppressed for the reason every other announcement
		// suppresses it — a banner over the app is the duplicate popup — and the
		// user is told what to do with the app already in front of them: the
		// package, the server and the installer are all still standing, and the
		// Library's Install button is the tap that finishes it.
		//
		// Both sentences are about what *BatSign* saw, not about what Apple did.
		// Whether a dialog appeared is the one thing this app is never told, and
		// an install that finished can look exactly like an install that never
		// started when neither the fraction nor the fingerprint came back — so the
		// user is pointed at the one action that is right either way, which is to
		// look at the Home Screen and, only if the app is not there, tap Install.
		let name = pending.app.name ?? "App"
		if canPresentAlert {
			reportInstallOutcome(
				title: "\(name) is ready",
				message: "BatSign never saw Apple's install prompt. Check your Home Screen — if \(name) is not there, open the Library and tap Install."
			)
		} else {
			AutoUpdateManager.shared.notify(
				title: "\(name) is ready",
				body: "Tap to finish installing it.",
				identifier: "signos.install.\(pending.app.uuid ?? UUID().uuidString)",
				category: "SIGNOS_INSTALL"
			)
			// The same words inside the app, waiting for whoever comes back: the
			// dialog this stands in for belongs to the system and it never
			// appeared, so someone looking at BatSign would otherwise see a card
			// saying "Tap the notification" beside no notification at all.
			reportInstallOutcome(
				title: "\(name) is ready",
				message: "Tap the notification to finish installing it, if it is not on your Home Screen already."
			)
		}

		LiveStatus.ensure(
			appID: pending.app.identifier ?? "",
			appName: name,
			phase: .installing,
			detail: canPresentAlert ? "Install it from the Library" : "Tap the notification to finish",
			mode: Self.installMode
		)

		Self.handOffLog.notice(
			"install: hand-off unanswered after every offer — telling the user (\(name, privacy: .public))"
		)
		ActivityLog.shared.log(.installed, app: name, detail: "install prompt never answered")
	}

	/// Let go of the install server and the hold that keeps it answering.
	///
	/// Called when the hand-off has reached its end — the app landed, or the
	/// watcher gave up — and not before. The servers are the only thing standing
	/// between installd and the package, and the silent audio session under them
	/// is the only thing standing between this process and suspension; releasing
	/// either early is what made an install stop the moment the user looked away.
	private func _endInstallHandOff() {
		Self._installerExpiry?.cancel()
		Self._installerExpiry = nil
		_pendingHandOff = nil
		Self._liveInstallers.removeAll()
		// The servers are down; the working copies they streamed from can go
		// with them.
		for handler in Self._liveArchiveHandlers.values { handler.clean() }
		Self._liveArchiveHandlers.removeAll()
		BSJobKeepAlive.shared.end(BSJobKeepAlive.Reason.installer)

		// The app landed, or the hand-off was given up on. Either way the job
		// this journal entry belongs to has reached its end, and leaving it
		// behind would have the next launch pick up work that is already done.
		if DownloadManager.shared.downloads.isEmpty {
			BSJobJournal.shared.clear(reason: "install hand-off ended")
		}
	}

	private static var _installerExpiry: Task<Void, Never>?

	private static func _retainInstaller(_ installer: ServerInstaller) {
		_liveInstallers.append(installer)

		// The hand-off is not over when this function returns: installd fetches
		// the manifest and then the package, possibly while the user is already
		// looking at the Home Screen or in another app entirely. The server has to
		// stay up — and so does the app — for as long as that can take.
		//
		// The hold is *not* released when the user comes back. It used to be, and
		// that was the bug: returning once dropped the only thing keeping the
		// process scheduled, so the next time the user left — which is exactly
		// what someone does while waiting for an install — the server died
		// mid-fetch and the install failed. It now runs until the landing watcher
		// confirms the app is on the device, and the expiry below is the backstop
		// for a hand-off that never gets an answer at all.
		BSJobKeepAlive.shared.begin(BSJobKeepAlive.Reason.installer)

		Self._installerExpiry?.cancel()
		Self._installerExpiry = Task { @MainActor in
			// Matches the watcher's follow deadline: the server stands until the
			// watcher has given up, and no longer. Retiring them together is what
			// keeps "the package is still reachable" and "the card is still up"
			// the same statement.
			try? await Task.sleep(nanoseconds: 660_000_000_000)
			guard !Task.isCancelled else { return }
			_liveInstallers.removeAll { $0 === installer }
			// Its stream is over too; the working copy it served goes with it.
			_liveArchiveHandlers.removeValue(forKey: ObjectIdentifier(installer))?.clean()
			BSJobKeepAlive.shared.end(BSJobKeepAlive.Reason.installer)
		}
	}

	/// Fires the pending install when the user opens BatSign from the
	/// "tap to install" notification.
	private func _handleInstallRequest(uuid: String) async {
		// Tapping the notification is the second half of a hand-off that was
		// already built and refused, not a new job. Everything for it is staged —
		// the package, the server, the retained installer — so opening the link
		// it is holding is the whole of the work. Rebuilding from scratch here
		// would re-archive a package that is already sitting on disk, and the user
		// would watch a spinner for a minute to reach a dialog that was ready
		// before they tapped.
		if let pending = _pendingHandOff {
			_pendingHandOff = nil
			guard await UIApplication.shared.open(pending.url) else { return }
			ActivityLog.shared.log(.installed, app: pending.app.name ?? "App", detail: "install prompt shown")
			if let identifier = pending.app.identifier {
				BSInstallWatcher.shared.follow(
					identifier,
					name: pending.app.name ?? "App",
					expecting: _builtIdentity(of: pending.app)
				)
			}
			return
		}

		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		guard let app = (try? Storage.shared.context.fetch(request))?.first else { return }

		do {
			try await _serverInstall(app)
			// The system is fetching the package now, with the user on the Home
			// Screen. Following it is what ends the live card when — and only
			// when — the app actually lands.
			if let identifier = app.identifier {
				BSInstallWatcher.shared.follow(
					identifier,
					name: app.name ?? "App",
					expecting: _builtIdentity(of: app)
				)
			}
		} catch {
			lastErrorMessage = error.localizedDescription
			BSInstallWatcher.shared.cancel(app.identifier)
			LiveStatus.finish(
				success: false,
				appName: app.name ?? "App",
				detail: error.localizedDescription,
				appID: app.identifier
			)
		}
	}

	// MARK: - Certificate selection

	private func _certificate(for app: AppInfoPresentable, options: Options) -> CertificatePair? {
		// Updates and renewals keep the app's existing certificate while
		// it is still valid, preserving the signing identity.
		if let existing = Storage.shared.getCertificate(from: app), !existing.revoked {
			if let expiration = existing.expiration {
				if expiration.timeIntervalSinceNow > 0 {
					return existing
				}
			} else {
				return existing
			}
		}

		let certs = Storage.shared.getAllCertificates().filter { cert in
			if cert.revoked { return false }
			if let expiration = cert.expiration {
				return expiration.timeIntervalSinceNow > 0
			}
			return true
		}

		if let defaultCert = certs.first(where: { $0.isDefault }) {
			return defaultCert
		}

		let selectedIndex = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		if
			selectedIndex >= 0,
			let selected = Storage.shared.getCertificate(for: selectedIndex),
			certs.contains(selected)
		{
			return selected
		}

		return certs.first
	}

	// MARK: - Fetch helpers

	private func _resolveApp(uuid: String) -> (any AppInfoPresentable)? {
		let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
		signedRequest.predicate = NSPredicate(format: "uuid == %@", uuid)
		if let signed = (try? Storage.shared.context.fetch(signedRequest))?.first {
			return signed
		}

		let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
		importedRequest.predicate = NSPredicate(format: "uuid == %@", uuid)
		if let imported = (try? Storage.shared.context.fetch(importedRequest))?.first {
			return imported
		}

		return nil
	}

	private func _signedApps() -> [Signed] {
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		return (try? Storage.shared.context.fetch(request)) ?? []
	}
}
