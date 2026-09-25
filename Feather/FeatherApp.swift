//
//  FeatherApp.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import Nuke
import IDeviceSwift
import OSLog
#if DEBUG
import ActivityKit
#endif

@main
struct FeatherApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@Environment(\.scenePhase) private var scenePhase

	let heartbeat = HeartbeatManager.shared

	@StateObject var downloadManager = DownloadManager.shared
	@StateObject private var autoUpdateManager = AutoUpdateManager.shared
	@AppStorage("BatSign.biometricLock") private var _biometricLock = false
	@State private var _isLocked = false
	let storage = Storage.shared

	/// The user's appearance choice, as the one value every surface derives from.
	///
	/// `UIUserInterfaceStyle.unspecified` is "Default", and Default means follow
	/// the iPhone. That is the whole of this feature: the app must not have an
	/// opinion of its own about light or dark unless the user expressed one.
	@AppStorage("Feather.userInterfaceStyle")
	private var _userInterfaceStyle: Int = UIUserInterfaceStyle.unspecified.rawValue

	/// The same choice in SwiftUI's vocabulary. Nil is the system's, and SwiftUI
	/// treats nil exactly as UIKit treats `.unspecified`.
	private var _colorScheme: ColorScheme? {
		switch UIUserInterfaceStyle(rawValue: _userInterfaceStyle) ?? .unspecified {
		case .light: return .light
		case .dark: return .dark
		default: return nil
		}
	}

	/// Hand the choice to the window as well as to SwiftUI.
	///
	/// UIKit-drawn surfaces — alerts, context menus, the share sheet, the text
	/// selection callout — are not SwiftUI views and do not read
	/// `preferredColorScheme`; they follow their window. Both have to be told, and
	/// they have to be told the same thing, or the app is light with dark alerts.
	private func _applyAppearance() {
		let window = UIApplication.topViewController()?.view.window
			?? UIApplication.shared.connectedScenes
				.compactMap { ($0 as? UIWindowScene)?.keyWindow }
				.first
		window?.overrideUserInterfaceStyle =
			UIUserInterfaceStyle(rawValue: _userInterfaceStyle) ?? .unspecified
	}

	var body: some Scene {
		WindowGroup {
			VStack {
				DownloadHeaderView(downloadManager: downloadManager)
					.transition(.move(edge: .top).combined(with: .opacity))

				VariedTabbarView()
					.environment(\.managedObjectContext, storage.context)
					.onOpenURL(perform: _handleURL)
					.transition(.move(edge: .top).combined(with: .opacity))
			}
			// The storefront's ground, behind the whole app, so every screen and
			// every sheet is drawn on the same surface rather than each painting its
			// own. A `background` and not a sibling in a stack, so it can never
			// take part in layout.
			.background {
				BSStoreGround()
			}
			// The accent everywhere at once: the user's chosen tint when there is
			// one, the iOS 27 blue otherwise. One colour, so the storefront's GET
			// and the app's own buttons can never drift apart.
			.tint(BS.accent)
			.animation(.smooth, value: downloadManager.manualDownloads.description)
			.onReceive(NotificationCenter.default.publisher(for: .heartbeatInvalidHost)) { _ in
				DispatchQueue.main.async {
					UIAlertController.showAlertWithOk(
						title: "InvalidHostID",
						message: .localized("Your pairing file is invalid and is incompatible with your device, please import a valid pairing file.")
					)
				}
			}
			// dear god help me
			.fullScreenCover(isPresented: $_isLocked) {
				WSLockView(onUnlock: { _isLocked = false })
			}
			// The user's appearance choice, carried by SwiftUI itself rather than
			// set once on a window. A window override is a snapshot of a decision;
			// this is the decision, so every screen follows the setting — and
			// follows the iPhone when the setting is Default — from the first frame
			// and on every change, without a relaunch.				.preferredColorScheme(_colorScheme)
				// The one question the collect system asks, asked wherever the person
				// happens to be when an app arrives. Attached at the root because an
				// arrival does not wait for them to be looking at the Library.
				.bsPendingSignPrompt()
				.onChange(of: _userInterfaceStyle) { _ in
					_applyAppearance()
				}
			.onAppear {
				// The window's own override, kept in step with the setting. "Default"
				// is `.unspecified`, which is how UIKit is told to follow the system:
				// forcing `.dark` here was what pinned the whole app to dark on a
				// phone set to light, on every launch, no matter what the setting
				// said. The SwiftUI half of the same answer is `preferredColorScheme`
				// on this view.
				_applyAppearance()

				// The same accent SwiftUI draws with: the user's tint, or the
				// iOS 27 blue. UIKit controls (alerts, context menus) resolve the
				// same colour the views do.
				UIApplication.topViewController()?.view.window?.tintColor = UIColor(BS.accent)

				autoUpdateManager.requestNotificationAuthorization()

				// Anything the island is still showing belongs to a job this
				// process does not hold: the hand-off ledger is read first, so a
				// card left by a run that was killed mid-install is settled
				// against the device — reported as landed if the app arrived,
				// ended without a claim if it did not — and only then is whatever
				// nobody can explain taken down.
				BSInstallWatcher.shared.reconcile()

				// And neither is a background grant asked for by the process that
				// died. A pending request outlives the process that submitted it, so
				// left alone the scheduler can start one and the system draws a card
				// for work that ended when that process did.
				BSContinuedProcessing.shared.releaseLeftover()

				#if DEBUG
				// A debug-only rehearsal of the live status, so the island can be
				// checked without a real download: launch with `-livedemo`.
				if CommandLine.arguments.contains("-livedemo") {
					_liveStatusDemo()
				}

				// The rest of the pipeline cannot be reached from a script — it
				// starts with a tap — so these hand it the job instead.
				_applyTestHooks()
				#endif
				autoUpdateManager.start()

				if _biometricLock {
					_isLocked = true
				}
			}
			.onChange(of: scenePhase) { phase in
				switch phase {
				case .active:
					// The window exists by now for certain, which it may not have
					// at the first `onAppear`. UIKit's half of the appearance is
					// applied here as well as there, so a phone whose appearance
					// changed while the app was away — or a first launch that
					// raced the window's creation — is still right.
					_applyAppearance()

					// Back in the foreground, and this is the moment the install
					// hand-off has been waiting for.
					//
					// iOS will not present the confirmation for an `itms-services://`
					// install from a backgrounded app — the dialog belongs to
					// SpringBoard, and SpringBoard only asks on behalf of whatever is
					// on screen. So a hand-off that was refused while the user was
					// elsewhere is presented here instead, with the package, the server
					// and the installer already built behind it: the dialog appears the
					// instant the app is up, not a minute later while it re-archives.
					//
					// The keep-alive deliberately does *not* stop here. Coming back
					// once used to drop the only thing keeping this process scheduled,
					// so the next time the user left — which is exactly what someone
					// does while an install runs — the local server died mid-fetch and
					// the install failed. The watcher releases it when the app lands.
					AutoSignManager.shared.handleForeground()

					autoUpdateManager.tick()

				case .background:
					#if !targetEnvironment(macCatalyst)
					autoUpdateManager.scheduleBackgroundRefresh()
					#endif
					// Leaving the app is not leaving the job. Whatever is running takes
					// its holds again here, because an audio session interrupted while
					// the app was in the foreground — a call, another app taking the
					// output — would otherwise leave a signing job with nothing keeping
					// it up, and it would be suspended at the first moment the user
					// looked away. That is the interruption this whole file is about.
					AutoSignManager.shared.handleBackground()
					if _biometricLock {
						_isLocked = true
					}
				default:
					break
				}
			}
		}
	}

	#if DEBUG
	/// The pipeline, driven from the command line.
	///
	/// Everything else in the app can be poked at from a script through its URL
	/// schemes, but the one path worth checking — add a repository, download from
	/// it, sign with a real certificate, watch the island through all of it —
	/// begins with a tap. These are how it starts without one, and they only
	/// exist in a debug build.
	///
	///     -seedsource <url>                    add a repository
	///     -importcert <p12> <provision> <pw>   import a signing certificate
	///     -download <url>                      start a transfer
	///     -apppage <bundle id>                 open an app's page
	///     -apppagescrolled                     open it as if scrolled, which
	///                                          is the only state the bar's own
	///                                          action pill exists in
	///     -settings                            open Settings
	///     -livedemo                            run the live-status rehearsal
	///     -liveshow <phase>                    hold one phase of the live card up,
	///                                          so the island and the Lock Screen
	///                                          can be looked at at rest
	///     -installlanded <name>                end an install, as the pipeline does
	///     -outcomedelay <seconds>              wait that long first, so the app
	///                                          can be backgrounded in between
	///     -tweakcheck <deb>                    unpack one tweak's deb, the way
	///                                          signing does
	///     -probe <ids> [-proberounds <n>]      report what the device says about
	///                                          each comma-separated bundle id
	///     -lsprobe <ids>                       report which workspace calls answer
	///                                          this process at all, and what they
	///                                          say about each bundle id
	///     -watchland <bundle id> <version> [name]
	///                                          follow an install for that bundle
	///                                          the way the pipeline does, so the
	///                                          landing rules can be tested against
	///                                          a change made by hand
	///     -cardstate                           report what the system says is on
	///                                          screen, once a second — the other
	///                                          half of "the island is blank"
	///     -islandfit                           measure every string the compact
	///                                          island can be asked to draw, at the
	///                                          font the island draws it with
	///
	/// The `-download` hook waits, because the certificate import and the source
	/// fetch above it are asynchronous and a transfer started before them would
	/// fail to sign for a reason that has nothing to do with the test.
	@MainActor
	private func _applyTestHooks() {
		let arguments = CommandLine.arguments

		func value(after flag: String) -> String? {
			guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
			return arguments[index + 1]
		}

		// The appearance, switched on the clock.
		//
		// The picker's own path, at a time a script can photograph. The change is
		// a tap this cannot make, and the cross-fade it starts is 0.28 of a
		// second — long enough to catch in a frame, far too short to catch
		// reliably — so it is started by the clock instead. `-appearancesecond`
		// switches a second time, so one launch proves both directions.
		if let raw = value(after: "-appearanceswitch") {
			let delay = Double(value(after: "-appearancedelay") ?? "6") ?? 6
			let gap = Double(value(after: "-appearancegap") ?? "3") ?? 3
			let first = Int(raw) ?? UIUserInterfaceStyle.dark.rawValue
			let second = value(after: "-appearancesecond").flatMap(Int.init)
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
				BSAppearanceStyle.stored = first
				guard let second else { return }
				try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
				BSAppearanceStyle.stored = second
			}
		}

		// Apps in the Library without an install behind them, so the multi-sign
		// picker has something to pick. Real `Imported` rows and real bundles: the
		// pipeline signs what it finds, and a stand-in that only looked like an
		// app would prove nothing about the pipeline.
		// Which of the two signing systems is running. A launch that does not
		// name one is testing the product's own default, which is what a new
		// install gets.
		if let raw = value(after: "-signmode"), let mode = BSSigningMode(rawValue: raw) {
			BSPendingSign.shared.setMode(mode)
		}

		// The signing option, on its own. A simulator has no signing
		// certificate, so a bare arrival — one the app was not told how to sign —
		// fails at the zsign call for a reason that has nothing to do with when
		// it was signed. `onlyModify` runs every stage of the pipeline but that
		// call, which is what an arrival can be proved with here.
		if value(after: "-signoption") == "onlymodify" {
			OptionsManager.shared.options.signingOption = .onlyModify
		}

		// Which screen the app opens on, for rehearsal shots of a screen the
		// app does not start on. The tab bar reads this key when it builds.
		if let raw = value(after: "-opentab"), TabEnum(rawValue: raw) != nil {
			UserDefaults.standard.set(raw, forKey: "BatSign.defaultTab")
		}

		// The confirmation, without a finger: exactly what the alert's own
		// button does. The alert is a tap no script can make, and the hand-off
		// it starts — tray, run, one card, install — is the half that matters.
		if let delay = value(after: "-signnow").flatMap(Double.init) {
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
				let started = BSPendingSign.shared.signAll()
				Logger(subsystem: "app.batsign.ios", category: "testhooks")
					.notice("signnow: started \(started, privacy: .public) from the tray")
			}
		}

		if let count = value(after: "-seedlibrary").flatMap(Int.init) {
			_seedLibrary(count)

			// `-bulkauto`: pick up where the seeding left off and start the run, so
			// the whole thing — enqueue, batch slots, stages, the card, the run's
			// own strip — can be driven from a launch.
			if arguments.contains("-bulkauto") {
				let options = value(after: "-signoption") ?? "onlymodify"
				if options == "onlymodify" {
					// A simulator has no signing certificate, and a build that cannot
					// sign cannot demonstrate the pipeline that signs. `onlyModify`
					// runs every stage of it but the zsign call itself — which is what
					// the stages, the card, and the install hand-off are about.
					OptionsManager.shared.options.signingOption = .onlyModify
				}

				Task { @MainActor in
					try? await Task.sleep(nanoseconds: 1_500_000_000)
					let apps = (try? Storage.shared.context.fetch(Imported.fetchRequest())) ?? []
					let picked = apps.map { $0 as any AppInfoPresentable }
					let started = BSBulkSign.shared.sign(picked, title: "Sign \(picked.count) Apps")
					Logger(subsystem: "app.batsign.ios", category: "testhooks")
						.notice("bulkauto: run started with \(started, privacy: .public) of \(picked.count, privacy: .public) apps queued")
				}
			}
		}

		if let repository = value(after: "-seedsource") {
			FR.handleSource(repository, silent: true) { }
		}

		if CommandLine.arguments.contains("-islandfit") {
			_measureIslandFit()
		}

		if let index = arguments.firstIndex(of: "-importcert"), arguments.count > index + 3 {
			FR.handleCertificateFiles(
				p12URL: URL(fileURLWithPath: arguments[index + 1]),
				provisionURL: URL(fileURLWithPath: arguments[index + 2]),
				p12Password: arguments[index + 3],
				isDefault: true
			) { error in
				Logger(subsystem: "app.batsign.ios", category: "testhooks")
					.notice("importcert: \(error?.localizedDescription ?? "ok", privacy: .public)")
			}
		}

		if let raw = value(after: "-download"), let url = URL(string: raw) {
			// The size a repository would have declared, for the case the server
			// sends no length of its own.
			let declared = Int64(value(after: "-downloadsize") ?? "") ?? 0
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 3_000_000_000)
				_ = DownloadManager.shared.startDownload(from: url, expectedBytes: declared)
			}
		}

		if CommandLine.arguments.contains("-vanishtemp") {
			// The staging code's drill: the finished temp file is removed before
			// the delegate can stage it. The download must still arrive — the
			// refetch writes it into a file this app owns — so this is the run
			// that proves a reclaimed temp file costs the user nothing.
			UserDefaults.standard.set(true, forKey: "batsign.debug.vanishTemp")
		}

		if CommandLine.arguments.contains("-vanishtempfail") {
			// The last-resort drill: the temp file is reclaimed *and* the refetch
			// cannot save its bytes either. That is the only state in which the
			// user should be told anything, so it is the run that proves the
			// message is reached and is the one they read.
			UserDefaults.standard.set(true, forKey: "batsign.debug.vanishTemp")
			UserDefaults.standard.set(true, forKey: "batsign.debug.vanishTempRescueFails")
		}

		if CommandLine.arguments.contains("-killmidway") {
			// The background-liveness drill: the socket is taken away partway
			// through a transfer, the way a suspension or a network handover
			// takes it. The download must carry on from the bytes it already had
			// — not freeze at that number and not fail.
			UserDefaults.standard.set(true, forKey: "batsign.debug.killMidway")
		}

		if CommandLine.arguments.contains("-checkupdates") {
			// The whole update system on demand: check the sources, then take
			// the updates the toggles would not refuse — the same two calls the
			// user's refresh button makes. Delayed so the launch-time source
			// refresh has finished before the check runs.
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 6_000_000_000)
				_ = await AutoUpdateManager.shared.checkNow(notifyWhenClean: false, silent: true)
				_ = await AutoUpdateManager.shared.downloadAllPendingUpdates()
			}
		}

		if let name = value(after: "-installlanded") {
			// The end of an install, through the same function the watcher and the
			// tunnel call: the notification outside and the popup in the app. The
			// delay is so the app can be sent to the background first, which is
			// the case the popup has to survive.
			let delay = Double(value(after: "-outcomedelay") ?? "0") ?? 0
			Task { @MainActor in
				if delay > 0 {
					try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
				}
				AutoSignManager.shared.announceInstallLanded(name: name, identifier: "com.example.landed")
			}
		}

		if let phase = value(after: "-liveshow") {
			// One phase of the live card, held still.
			//
			// The expanded card and the Lock Screen presentation only exist in a
			// state that has settled: the rehearsal's phases last a second each,
			// which is long enough to prove the app pushes the right numbers and
			// far too short to tell a finished design from an animation caught
			// halfway through. This leaves one phase up so it can be looked at.
			_liveShow(phase)
		}

		if let list = value(after: "-probe") {
			// What the device answers about a bundle, once a second, so the
			// watcher's evidence can be checked against reality rather than
			// assumed. A comma-separated list, because the interesting comparison
			// is an app that is installed against one that is not.
			let identifiers = list.split(separator: ",").map(String.init)
			let rounds = Int(value(after: "-proberounds") ?? "8") ?? 8
			Task { @MainActor in
				for round in 0...rounds {
					for identifier in identifiers {
						let reading = await Task.detached(priority: .utility) {
							BSInstallProbe.read(identifier)
						}.value
						let fraction = reading.fraction.map { String(format: "%.4f", $0) } ?? "nil"
						Logger(subsystem: "app.batsign.ios", category: "probe")
							.notice("probe \(round) \(identifier, privacy: .public): installed=\(reading.isInstalled, privacy: .public) version=\(reading.version ?? "nil", privacy: .public) build=\(reading.build ?? "nil", privacy: .public) fraction=\(fraction, privacy: .public) stamp=\(reading.stamp ?? "nil", privacy: .public)")
					}
					try? await Task.sleep(nanoseconds: 1_000_000_000)
				}
			}
		}

		if arguments.contains("-cardstate") {
			// What the system says is on screen, once a second.
			//
			// A blank island and a card that has gone look identical in a
			// screenshot, and they are not the same thing: the island is drawn by
			// SpringBoard in its own window, and whether a capture composites it is
			// not something this app decides. This is the other half of the
			// question — the card's own existence and state — so a missing pill can
			// be traced to the capture rather than to the card.
			Task { @MainActor in
				while true {
					Logger(subsystem: "app.batsign.ios", category: "livecard")
						.notice("cardstate: \(LiveStatus.describeCards(), privacy: .public)")
					try? await Task.sleep(nanoseconds: 1_000_000_000)
				}
			}
		}

		if arguments.contains("-scanapps") {
			// The whole device, once: what the system's registry says about every
			// app it names, and what it is installing right now. This is the scan
			// the pipeline's own decisions are made from, asked here on its own so
			// the answers it gives can be checked against the phone rather than
			// taken on trust.
			let targets = (value(after: "-scanfor") ?? "").split(separator: ",").map(String.init)
			Task.detached(priority: .utility) {
				let snapshot = BSDeviceApps.snapshot()
				let log = Logger(subsystem: "app.batsign.ios", category: "device")
				log.notice("\(BSDeviceApps.report(snapshot), privacy: .public)")
				for identifier in targets {
					log.notice("\(BSDeviceApps.describe(identifier, using: snapshot), privacy: .public)")
				}
			}
		}

		if arguments.contains("-ledger") {
			// The hand-offs on the books: what this process would find if it had
			// just been launched into the middle of somebody else's install.
			let records = BSInstallLedger.records
			let ledgerLog = Logger(subsystem: "app.batsign.ios", category: "install")
			ledgerLog.notice("ledger: \(records.count, privacy: .public) record(s)")
			for record in records {
				ledgerLog.notice(
					"ledger: \(record.identifier, privacy: .public) “\(record.name, privacy: .public)” \(record.stage.rawValue, privacy: .public) expected=\(record.expected.described, privacy: .public) baseline=\(record.baseline.described, privacy: .public) wasInstalled=\(record.wasInstalled, privacy: .public) progress=\(record.sawProgress, privacy: .public)/\(record.sawInFlight, privacy: .public)/\(record.sawInstallAtEnd, privacy: .public) age=\(Int(Date().timeIntervalSince(record.askedAt)), privacy: .public)s"
				)
			}
		}

		if let identifier = value(after: "-ledgerstage") {
			// A hand-off written down by hand, exactly as the process that made it
			// would have left it. The record is the half of the killed-process
			// case that cannot be produced on a simulator — an install handed to
			// installd and then a process that dies — so the reconcile that
			// settles it is driven from here instead.
			//
			// The expected build is whatever the device has now, and the baseline
			// is something else: that pair is the strongest evidence there is,
			// "the build on the device is the one this job signed and it was not
			// that before", and a staged record that satisfies it must land.
			let index = arguments.firstIndex(of: "-ledgerstage") ?? 0
			let name = arguments.count > index + 2 ? arguments[index + 2] : "Staged"
			let age = arguments.count > index + 3 ? (Double(arguments[index + 3]) ?? 0) : 0
			// A record for an app that was not on the phone: the ordinary case for
			// an install from a source, and the only one where "it is there now" is
			// evidence without a baseline build to compare against.
			let wasNew = arguments.contains("-ledgernew")
			let device = BSDeviceApps.read(identifier)

			BSInstallLedger.clearAll()
			// A staged hand-off is a new question, exactly as `arm` says: a landing
			// already announced for this bundle must not silence this one.
			BSInstallLedger.forgetReported(identifier)
			BSInstallLedger.put(
				BSInstallLedger.Record(
					identifier: identifier,
					name: name,
					expected: wasNew ? BuildIdentity(version: nil, build: nil) : device.identity,
					baseline: BuildIdentity(version: "0.0", build: "0"),
					baselineStamp: nil,
					wasInstalled: !wasNew,
					stage: .handedOff,
					askedAt: Date().addingTimeInterval(-age),
					updatedAt: Date(),
					sawProgress: false,
					sawInFlight: false,
					sawInstallAtEnd: false,
					lastProgressAt: nil
				)
			)
			Logger(subsystem: "app.batsign.ios", category: "install")
				.notice("ledgerstage: \(identifier, privacy: .public) as \(name, privacy: .public), expected \(device.identity.described, privacy: .public), age \(Int(age), privacy: .public)s, wasInstalled \(!wasNew, privacy: .public)")
		}

		if arguments.contains("-homescan") {
			// The scan that notices installs nobody followed: forget what the phone
			// had, read it, and say what has appeared. Run twice with an install in
			// between and the second run is the whole feature — an app that arrived
			// while nothing was watching, found by comparing the phone to itself.
			let forget = arguments.contains("-homescanforget")
			Task.detached(priority: .utility) {
				let log = Logger(subsystem: "app.batsign.ios", category: "device")
				if forget { BSHomeRegistry.forget() }
				let snapshot = BSDeviceApps.snapshot()
				let landings = BSHomeRegistry.landings(using: snapshot)
				log.notice(
					"homescan: \(snapshot.entries.count, privacy: .public) apps on the phone, \(landings.count, privacy: .public) changed since the last scan"
				)
				for landing in landings {
					log.notice(
						"homescan: \(landing.identifier, privacy: .public) “\(landing.name ?? "-", privacy: .public)” \(landing.isNew ? "appeared" : "build changed", privacy: .public) \(landing.previous?.build ?? "-", privacy: .public) → \(landing.current.build ?? "-", privacy: .public)"
					)
				}
			}
		}

		if let shim = value(after: "-homesign") {
			// Attribution, stubbed: a bundle id this app is to be treated as having
			// signed, written through the same store the library uses. The scan can
			// see an app appear but cannot know who put it there, and the only way to
			// test that half on a simulator — where nothing can be signed end to end
			// — is to say so out loud.
			let parts = shim.split(separator: ",").map(String.init)
			if let identifier = parts.first {
				let name = parts.count > 1
					? parts[1]
					: (identifier.split(separator: ".").last.map(String.init) ?? identifier)
				let version = parts.count > 2 ? parts[2] : "1.0"
				Storage.shared.addSigned(
					uuid: UUID().uuidString,
					appName: name,
					appIdentifier: identifier,
					appVersion: version
				) { _ in
					Logger(subsystem: "app.batsign.ios", category: "device")
						.notice("homesign: \(identifier, privacy: .public) is now attributed to this app")
				}
			}
		}

		if arguments.contains("-reconcile") {
			// The same call the launch and every return to the foreground make.
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 3_000_000_000)
				BSInstallWatcher.shared.reconcile()
			}
		}

		if let list = value(after: "-lsprobe") {			// Which parts of the workspace will answer this process, and what they
			// say, for each bundle id given. The install watcher's two best answers
			// — the version on the device and the path it lives at — come from
			// private calls that answer nothing at all when they are unavailable,
			// and a nil is indistinguishable from "no such app" without asking the
			// whole surface at once.
			let identifiers = list.split(separator: ",").map(String.init)
			Task.detached(priority: .utility) {
				BSWorkspaceProbe.run(identifiers)
			}
		}

		if let identifier = value(after: "-settletest") {
			// A rehearsal of the 2.5-second settle: the card appears at
			// "Finishing… 100%" and must be gone two and a half seconds later —
			// the behaviour a device shows when its install object ends, which
			// no simulator can produce for real.
			let name = value(after: "-settlename") ?? "SettleTest"
			Task { @MainActor in
				BSInstallWatcher.shared.debugSettle(identifier, name: name)
			}
		}

		if let identifier = value(after: "-watchland") {
			// A watch armed by hand, so the landing rules can be pointed at a
			// change made outside the app: the expected build is given, the
			// watcher takes its own baseline, and a bundle that appears on the
			// device at that build is what it has to notice. This is the only
			// way to test the build rule against a real install without a
			// signing certificate and a working hand-off in the loop.
			let index = arguments.firstIndex(of: "-watchland") ?? 0
			let version = arguments.count > index + 2 ? arguments[index + 2] : ""
			let name = arguments.count > index + 3 ? arguments[index + 3] : "WatchTest"
			Task { @MainActor in
				// The one number given on the command line stands for both halves
				// of the identity, because the test bundles carry the same string
				// in both fields. The real path passes what it actually built.
				let expected = BuildIdentity(version: version, build: version)
				BSInstallWatcher.shared.arm(identifier, expecting: expected)
				BSInstallWatcher.shared.follow(identifier, name: name, expecting: expected)
				Logger(subsystem: "app.batsign.ios", category: "install")
					.notice("watchland: following \(identifier, privacy: .public) for build \(version, privacy: .public)")
			}
		}

		if let path = value(after: "-tweakcheck") {
			// One deb through the unpacker signing uses. The scratch app carries
			// the substrate framework the real path wants to see, so the deb is
			// what is under test and nothing else is.
			Task { @MainActor in
				var options = Options.defaultOptions
				options.injectionFiles = [URL(fileURLWithPath: path)]

				let scratch = FileManager.default.temporaryDirectory
					.appendingPathComponent("TweakCheck_\(UUID().uuidString)")
				try? FileManager.default.createDirectory(
					at: scratch.appendingPathComponent("Frameworks/CydiaSubstrate.framework"),
					withIntermediateDirectories: true
				)

				do {
					try await TweakHandler(app: scratch, options: options).getInputFiles()
					Logger(subsystem: "app.batsign.ios", category: "testhooks")
						.notice("tweakcheck: unpacked — \(URL(fileURLWithPath: path).lastPathComponent, privacy: .public)")
				} catch {
					Logger(subsystem: "app.batsign.ios", category: "testhooks")
						.notice("tweakcheck: refused — \(error.localizedDescription, privacy: .public)")
				}

				try? FileManager.default.removeItem(at: scratch)
			}
		}
	}

	/// Drives the live status end to end: begin, twenty progress ticks, a phase
	/// change, a finish. Only reachable with `-livedemo`, and only in a debug
	/// build.
	///
	/// It reports the card's own state at each step rather than only at the end,
	/// because the interesting failures are in the middle: a card that never
	/// appears, a phase change that is swallowed, a progress bar that jumps. The
	/// island itself cannot be drawn in a simulator, so the state ActivityKit
	/// holds is the thing worth reading — and "zero cards after a finish" on its
	/// own would also be true of a card that was never created.
	@MainActor
	/// Holds one phase of the live status up, so the surfaces it is drawn on can
	/// be looked at in a state that has stopped moving.
	///
	/// Each case is one of the phases the pipeline really publishes, with the
	/// numbers it really publishes: a fraction for the two phases that have one,
	/// and none for the phases that do not. A card that is shown here with a
	/// number the pipeline would never send would prove nothing about the card.
	private func _liveShow(_ name: String) {
		let appID = "com.example.clarity.https://example.com/Clarity.ipa"
		let bundleID = "com.example.clarity"
		let mode = CompressionMode.turbo.label

		LiveStatus.begin(
			appID: appID,
			appName: "Clarity",
			detail: "Starting…",
			queued: 1,
			bundleID: bundleID,
			mode: mode
		)

		Task {
			try? await Task.sleep(nanoseconds: 700_000_000)

			switch name {
			case "download":
				LiveStatus.update(
					phase: .downloading, appName: "Clarity", progress: 0.42,
					detail: "17 MB of 40 MB", queued: 1, appID: appID, mode: mode
				)
			case "unpack":
				LiveStatus.update(
					phase: .unpacking, appName: "Clarity", progress: 0,
					detail: "Unpacking the app", queued: 1, progressKnown: false,
					force: true, appID: appID, mode: mode
				)
			case "sign":
				LiveStatus.update(
					phase: .signing, appName: "Clarity", progress: 0,
					detail: "Signing and installing", queued: 1, progressKnown: false,
					force: true, appID: bundleID, mode: mode
				)
			case "update":
				LiveStatus.update(
					phase: .updating, appName: "Clarity", progress: 0,
					detail: "Updating to 2.1.0", queued: 1, progressKnown: false,
					force: true, appID: bundleID, mode: mode
				)
			case "install":
				LiveStatus.update(
					phase: .installing, appName: "Clarity", progress: 0.4,
					detail: "Handing the package to iOS", queued: 1, force: true,
					appID: bundleID, mode: mode
				)
			case "finish":
				LiveStatus.finish(
					success: true, appName: "Clarity",
					detail: "Installed on this iPhone", appID: bundleID
				)
			case "fail":
				LiveStatus.finish(
					success: false, appName: "Clarity",
					detail: "Signing failed", appID: bundleID
				)
			default:
				break
			}

			Logger(subsystem: "app.batsign.ios", category: "liveshow")
				.notice("liveshow: holding \(name, privacy: .public)")
		}
	}

	#if DEBUG
	/// Measures every string the compact island can be asked to draw, at the font
	/// the island draws it with.
	///
	/// The compact half is the narrowest place this app puts text and the one
	/// region whose width it does not choose, so the bound the widget sets there —
	/// 32 pt — is only worth something if the widest label really is inside it.
	/// The labels are therefore measured rather than eyeballed: a phase with no
	/// fraction names itself in four characters or fewer, and a transfer names its
	/// own percentage, which is at most four glyphs too.
	@MainActor
	private func _measureIslandFit() {
		let base = UIFont.systemFont(ofSize: 11, weight: .semibold)
		let rounded = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 11) } ?? base
		typealias Phase = DownloadActivityAttributes.ContentState.Phase

		let labels = [
			Phase.downloading.compact,
			Phase.unpacking.compact,
			Phase.signing.compact,
			Phase.updating.compact,
			Phase.installing.compact,
			Phase.finished.compact,
			Phase.failed.compact,
			"0%", "9%", "42%", "100%"
		]

		let log = Logger(subsystem: "app.batsign.ios", category: "islandfit")
		for label in labels {
			let width = (label as NSString).size(withAttributes: [.font: rounded]).width
			log.notice("islandfit: “\(label, privacy: .public)” is \(width, format: .fixed(precision: 1), privacy: .public) pt wide")
		}
	}
	#endif

	/// Apps in the Library, made here rather than downloaded.
	///
	/// A multi-sign run is about the queue, the card, the stages and the install
	/// hand-off, and none of those need a repository behind them — but they do
	/// need apps that are really in the Library, because the Library is what the
	/// queue signs. Each row is therefore a real `Imported` record over a real
	/// (if minimal) bundle, rather than something that merely looks like one in
	/// a list.
	@MainActor
	private func _seedLibrary(_ count: Int) {
		let log = Logger(subsystem: "app.batsign.ios", category: "testhooks")
		let seeds: [(id: String, name: String)] = [
			("com.seed.alpha", "Alpha"),
			("com.seed.bravo", "Bravo"),
			("com.seed.charlie", "Charlie"),
			("com.seed.delta", "Delta"),
			("com.seed.echo", "Echo")
		]

		for index in 0..<max(0, min(count, seeds.count)) {
			let seed = seeds[index]
			let uuid = "SEED-\(index)"
			let bundle = FileManager.default.unsigned(uuid).appendingPathComponent("Seed.app")

			try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

			let info: NSDictionary = [
				"CFBundleIdentifier": seed.id,
				"CFBundleName": seed.name,
				"CFBundleDisplayName": seed.name,
				"CFBundleExecutable": "Seed",
				"CFBundlePackageType": "APPL",
				"CFBundleShortVersionString": "1.0.\(index + 1)",
				"CFBundleVersion": "1",
				"MinimumOSVersion": "16.0"
			]
			info.write(to: bundle.appendingPathComponent("Info.plist"), atomically: true)
			FileManager.default.createFile(
				atPath: bundle.appendingPathComponent("Seed").path,
				contents: Data()
			)

			Storage.shared.addImported(
				uuid: uuid,
				appName: seed.name,
				appIdentifier: seed.id,
				appVersion: "1.0.\(index + 1)"
			) { error in
				if let error {
					log.notice("seed: \(seed.name, privacy: .public) refused — \(error.localizedDescription, privacy: .public)")
				} else {
					log.notice("seed: \(seed.name, privacy: .public) is in the Library")
				}
			}
		}
	}

	private func _liveStatusDemo() {
		// `-livename <name>` `-livepercent <n>` `-livedetail <text>` stage one
		// held state instead of running the whole rehearsal, so a card a user
		// photographed — a long name at a mid fraction — can be put back on the
		// island and measured rather than described.
		let hookValue: (String) -> String? = { flag in
			guard let index = CommandLine.arguments.firstIndex(of: flag),
			      CommandLine.arguments.count > index + 1 else { return nil }
			return CommandLine.arguments[index + 1]
		}
		if let name = hookValue("-livename") {
			let percent = Double(hookValue("-livepercent") ?? "66") ?? 66
			let detail = hookValue("-livedetail") ?? "29.5 MB of 44.8 MB · 577 KB/s"
			LiveStatus.begin(
				appID: "com.example.clarity.https://example.com/Clarity.ipa",
				appName: name,
				detail: detail,
				bundleID: "com.example.clarity",
				mode: CompressionMode.stored.label
			)
			Task {
				try? await Task.sleep(nanoseconds: 600_000_000)
				LiveStatus.update(
					phase: .downloading,
					appName: name,
					progress: percent / 100.0,
					detail: detail,
					appID: "com.example.clarity.https://example.com/Clarity.ipa",
					mode: CompressionMode.stored.label
				)
				_report("staged \(name) at \(Int(percent))% — \(detail)")
			}
			return
		}

		LiveStatus.begin(
			appID: "com.example.clarity.https://example.com/Clarity.ipa",
			appName: "Clarity",
			detail: "Starting…",
			queued: 2,
			bundleID: "com.example.clarity",
			mode: CompressionMode.stored.label
		)

		Task {
			try? await Task.sleep(nanoseconds: 600_000_000)
			_report("after begin")

			for step in 1...20 {
				try? await Task.sleep(nanoseconds: 300_000_000)
				LiveStatus.update(
					phase: .downloading,
					appName: "Clarity",
					progress: Double(step) / 20.0,
					detail: "\(step * 2) MB of 40 MB",
					queued: 2,
					appID: "com.example.clarity.https://example.com/Clarity.ipa",
					mode: CompressionMode.stored.label
				)
			}

			try? await Task.sleep(nanoseconds: 900_000_000)
			_report("after the transfer finished")

			// The real pipeline's own hand-off: the transfer is keyed by the
			// store's composite id, and the install half addresses the app by its
			// bundle id. Both names have to reach the same card, or the install
			// half talks to nothing and the card never goes away.
			LiveStatus.update(
				phase: .signing,
				appName: "Clarity",
				progress: 0,
				detail: "Signing and installing",
				force: true,
				appID: "com.example.clarity",
				mode: CompressionMode.stored.label
			)

			try? await Task.sleep(nanoseconds: 600_000_000)
			// Signing is the silent phase: no bytes, no callbacks, nothing for a
			// progress update to be about. The card must therefore *settle* here.
			//
			// The wave used to be carried by updates, so this phase used to push a
			// fresh phase value every 0.7 seconds to keep the light moving — which
			// is the blink. The light is drawn inside the card now, and what the
			// app must do during a silent phase is nothing at all: two and a half
			// seconds is five of the old beats, so an unchanged number here is a
			// real answer rather than a race.
			let first = _wave()
			try? await Task.sleep(nanoseconds: 2_400_000_000)
			let second = _wave()
			_report("while signing — wave \(first) then \(second), steady=\(first == second)")

			LiveStatus.update(
				phase: .installing,
				appName: "Clarity",
				progress: 0.4,
				detail: "Handing the package to iOS",
				force: true,
				appID: "com.example.clarity",
				mode: CompressionMode.stored.label
			)

			try? await Task.sleep(nanoseconds: 1_200_000_000)
			_report("while installing")

			LiveStatus.finish(
				success: true,
				appName: "Clarity",
				detail: "Installed on this iPhone",
				appID: "com.example.clarity"
			)

			// The hold is the window the result is shown in. A card must still be
			// there — a finish that ends the activity before anything draws it is a
			// result nobody sees.
			try? await Task.sleep(nanoseconds: 800_000_000)
			_report("inside the result hold")

			// The hand-off is the whole test: a card that started under the
			// transfer's own id has to answer to the bundle id the install half
			// uses, or the finish above reaches nothing and the card is still in
			// the island. Zero is the only correct answer.
			//
			// Waited out well past the hold on purpose. The old version checked at
			// 1.5 s against a 1.6 s hold and so passed whatever happened, which is
			// exactly how an island that never goes away survives a test.
			try? await Task.sleep(nanoseconds: 5_000_000_000)
			_report("after the hold expired")
		}
	}

	/// Where the wave is on the card that is up, for the demo's own checks.
	@MainActor
	private func _wave() -> String {
		guard #available(iOS 16.2, *) else { return "-" }
		guard let wave = Activity<DownloadActivityAttributes>.activities.first?.content.state.wave else {
			return "none"
		}
		return String(format: "%.3f", wave)
	}

	/// One line per step: how many cards are up and what the newest one says.
	@MainActor
	private func _report(_ step: String) {
		guard #available(iOS 16.2, *) else { return }
		let cards = Activity<DownloadActivityAttributes>.activities
		let newest = cards.first
		let description = newest.map {
			let state = $0.content.state
			return "\(state.phase.rawValue) \(Int((state.progress * 100).rounded()))% mode=\(state.mode ?? "-")"
		} ?? "-"
		Logger(subsystem: "app.batsign.ios", category: "livedemo")
			.notice("livedemo: \(step, privacy: .public) — cards=\(cards.count, privacy: .public) \(description, privacy: .public)")
	}
	#endif

	private func _handleURL(_ url: URL) {
		if url.scheme == "batsign" || url.scheme == "signos" || url.scheme == "feather" {
			/// feather://import-certificate?p12=<base64>&mobileprovision=<base64>&password=<base64>
			if url.host == "import-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
					let queryItems = components.queryItems
				else {
					return
				}
				
				func queryValue(_ name: String) -> String? {
					queryItems.first(where: { $0.name == name })?.value?.removingPercentEncoding
				}
				
				guard
					let p12Base64 = queryValue("p12"),
					let provisionBase64 = queryValue("mobileprovision"),
					let passwordBase64 = queryValue("password"),
					let passwordData = Data(base64Encoded: passwordBase64),
					let password = String(data: passwordData, encoding: .utf8)
				else {
					return
				}
				
				let generator = UINotificationFeedbackGenerator()
				generator.prepare()
				
				guard
					let p12URL = FileManager.default.decodeAndWrite(base64: p12Base64, pathComponent: ".p12"),
					let provisionURL = FileManager.default.decodeAndWrite(base64: provisionBase64, pathComponent: ".mobileprovision"),
					FR.checkPasswordForCertificate(for: p12URL, with: password, using: provisionURL)
				else {
					generator.notificationOccurred(.error)
					return
				}
				
				FR.handleCertificateFiles(
					p12URL: p12URL,
					provisionURL: provisionURL,
					p12Password: password
				) { error in
					if let error = error {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					} else {
						generator.notificationOccurred(.success)
					}
				}
				
				return
			}
			/// feather://export-certificate?callback_template=<template>
			/// ?callback_template=: This is how we callback to the application requesting the certificate, this will be a url scheme
			/// 	example: livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29
			/// 	decoded: livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)
			/// $(BASE64_CERT) and $(PASSWORD) must be presenting in the callback template so we can replace them with the proper content
			if url.host == "export-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
				else {
					return
				}
				
				let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
				guard let callbackTemplate = queryItems["callback_template"]?.removingPercentEncoding else { return }
				
				FR.exportCertificateAndOpenUrl(using: callbackTemplate)
			}
			/// feather://source/<url>
			if let fullPath = url.validatedScheme(after: "/source/") {
				FR.handleSource(fullPath) { }
			}
			/// feather://install/<url.ipa>
			if
				let fullPath = url.validatedScheme(after: "/install/"),
				let downloadURL = URL(string: fullPath)
			{
				_ = DownloadManager.shared.startDownload(from: downloadURL)
			}
		} else {
			if url.pathExtension == "ipa" || url.pathExtension == "tipa" {
				// A file handed over from Files or the share sheet lives outside
				// this sandbox, and the access has to be released again — the old
				// code took it and never gave it back, leaking one sandbox
				// extension per import.
				//
				// The failure used to go nowhere at all: `{ _ in }` discarded it,
				// and a `guard` on the resource returned bare, so an IPA tapped in
				// Files did nothing with no alert, no Library row and no log.
				if FileManager.default.isFileFromFileProvider(at: url) {
					guard url.startAccessingSecurityScopedResource() else {
						Logger.misc.error("import: could not reach the file that was opened")
						_showImportFailure(url, reason: .localized("The file could not be opened."))
						return
					}

					defer { url.stopAccessingSecurityScopedResource() }

					FR.handlePackageFile(url) { error in
						if let error {
							_showImportFailure(url, reason: error.localizedDescription)
						}
					}
				} else {
					FR.handlePackageFile(url) { error in
						if let error {
							_showImportFailure(url, reason: error.localizedDescription)
						}
					}
				}
				
				return
			}
		}
	}

	/// An import that fails has to say so — the file was opened from outside the
	/// app, so there is no list it can be seen missing from.
	private func _showImportFailure(_ url: URL, reason: String) {
		UIAlertController.showAlertWithOk(
			title: .localized("Import"),
			message: .localized("‘%@’ could not be imported: %@", arguments: url.lastPathComponent, reason)
		)
	}
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		_createPipeline()
		_createDocumentsDirectories()
		ResetView.clearWorkCache()
		_addDefaultCertificates()
		_removeBundledSource()

		// The catalogues this build ships with, put back if they are missing, and
		// the addresses earlier builds used taken away. Both are needed on every
		// launch rather than once: a phone that restored a backup without the
		// source, or upgraded from a build that seeded a different address, must
		// end in the same state as a fresh install — one built-in catalogue, and
		// the retired ones gone.
		BSBuiltInSources.removeLegacyBuiltIns()
		BSBuiltInSources.seed()

		UNUserNotificationCenter.current().delegate = self

		#if !targetEnvironment(macCatalyst)
		// background refresh registration must happen before launching finishes
		AutoUpdateManager.registerBackgroundRefresh()
		// Same constraint, and the same reason: a handler registered after
		// launch returns is one iOS will never call. This is the request that
		// lets the app be woken to finish a job it was killed in the middle of —
		// which is the difference between a background session that keeps
		// downloading and work that actually gets finished.
		BSBackgroundTasks.register()
		#endif

		// Anything the journal is holding belongs to a process that is no longer
		// running: it is written before work starts and cleared when the job ends,
		// so at launch it can only be an interruption. Picking it up here is what
		// makes leaving the app — or losing it — survivable.
		Task { @MainActor in
			BSBackgroundTasks.shared.recoverInterruptedJob()
		}

		return true
	}

	func application(
		_ application: UIApplication,
		handleEventsForBackgroundURLSession identifier: String,
		completionHandler: @escaping () -> Void
	) {
		// iOS is waking the app because a transfer it was running finished while
		// the app was not. The session hands its events to the delegate and calls
		// this when there is nothing left to deliver — so the app must not be
		// allowed to go back to sleep before that, or the package it just
		// downloaded is dropped instead of signed.
		DownloadManager.shared.attachBackgroundCompletion(completionHandler)
	}


	func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		willPresent notification: UNNotification
	) async -> UNNotificationPresentationOptions {
		[.banner, .sound]
	}

	func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse
	) async {
		let action = response.actionIdentifier
		guard
			action == UNNotificationDefaultActionIdentifier || action == "SIGNOS_INSTALL_ACTION",
			response.notification.request.identifier.hasPrefix("signos.install.")
		else { return }
		let identifier = response.notification.request.identifier
		let uuid = String(identifier.dropFirst("signos.install.".count))

		NotificationCenter.default.post(
			name: Notification.Name("BatSign.autoInstallRequested"),
			object: nil,
			userInfo: ["uuid": uuid]
		)
	}
	
	private func _createPipeline() {
		// Screenshots are the heaviest thing this app draws and the thing it draws
		// most of at once. The store's own CDN answers each one slowly, so the
		// page's only chance of feeling instant is to have the bytes already in
		// memory by the time a card asks for them — which is what the prefetch in
		// the app page fills and what this pipeline keeps.
		//
		// `isStoringPreviewsInMemoryCache` is the load-bearing one. A preview is a
		// *rendered* image, and Nuke's default is to keep only the original data
		// on disk and re-decode on every ask. Keeping the decode too is what turns
		// the second paint of a shot — the one after the card scrolled away and
		// came back — into a memory read instead of a disk read plus a decode.
		let sharedCache = URLCache(
			memoryCapacity: 32 * 1024 * 1024,
			diskCapacity: 128 * 1024 * 1024,
			diskPath: nil
		)
		URLCache.shared = sharedCache

		let pipeline = ImagePipeline {
			let dataLoader: DataLoader = {
				let config = URLSessionConfiguration.default
				config.urlCache = sharedCache
				config.requestCachePolicy = .useProtocolCachePolicy
				return DataLoader(configuration: config)
			}()
			let dataCache = try? DataCache(name: "com.signos.app.datacache") // disk cache
			let imageCache = Nuke.ImageCache() // memory cache
			dataCache?.sizeLimit = 500 * 1024 * 1024
			// Raised from 100 MB: a single app page's Preview is up to eight
			// full-width renders, and evicting the first shot to make room for the
			// eighth is what makes a row of cards reload itself while the user is
			// looking at it.
			imageCache.costLimit = 260 * 1024 * 1024
			$0.dataCache = dataCache
			$0.imageCache = imageCache
			$0.dataLoader = dataLoader
			$0.dataCachePolicy = .automatic
			$0.isStoringPreviewsInMemoryCache = true
		}

		ImagePipeline.shared = pipeline
	}
	
	private func _createDocumentsDirectories() {
		let fileManager = FileManager.default

		let directories: [URL] = [
			fileManager.archives,
			fileManager.certificates,
			fileManager.signed,
			fileManager.unsigned
		]
		
		for url in directories {
			try? fileManager.createDirectoryIfNeeded(at: url)
		}
	}
	
	// A fresh install starts with no sources at all. Nothing is pre-subscribed:
	// the only way a repository gets in is the user adding it on the Sources
	// tab, which is the only place that offers to.

	/// Unsubscribes the repository earlier builds shipped with.
	///
	/// Only that one URL, and only once: a source the user added themselves is
	/// theirs, and a source list is not ours to prune. Existing installs already
	/// carry the seeded entry in Core Data, so leaving it there would keep the
	/// app looking like it still ships a storefront of its own.
	private func _removeBundledSource() {
		let flag = "BatSign.didRemoveBundledSource"
		guard !UserDefaults.standard.bool(forKey: flag) else { return }
		UserDefaults.standard.set(true, forKey: flag)

		let bundled = "https://raw.githubusercontent.com/8yy/BatSign/main/app-repo.json"
		for source in Storage.shared.getSources() where source.sourceURL?.absoluteString == bundled {
			Storage.shared.deleteSource(for: source)
		}
	}

	private func _addDefaultCertificates() {
		guard
			UserDefaults.standard.bool(forKey: "feather.didImportDefaultCertificates") == false,
			let signingAssetsURL = Bundle.main.url(forResource: "signing-assets", withExtension: nil)
		else {
			return
		}
		
		do {
			let folderContents = try FileManager.default.contentsOfDirectory(
				at: signingAssetsURL,
				includingPropertiesForKeys: nil,
				options: .skipsHiddenFiles
			)
			
			for folderURL in folderContents {
				guard folderURL.hasDirectoryPath else { continue }
				
				let certName = folderURL.lastPathComponent
				
				let p12Url = folderURL.appendingPathComponent("cert.p12")
				let provisionUrl = folderURL.appendingPathComponent("cert.mobileprovision")
				let passwordUrl = folderURL.appendingPathComponent("cert.txt")
				
				guard
					FileManager.default.fileExists(atPath: p12Url.path),
					FileManager.default.fileExists(atPath: provisionUrl.path),
					FileManager.default.fileExists(atPath: passwordUrl.path)
				else {
					Logger.misc.warning("Skipping \(certName): missing required files")
					continue
				}
				
				let password = try String(contentsOf: passwordUrl, encoding: .utf8)
				
				FR.handleCertificateFiles(
					p12URL: p12Url,
					provisionURL: provisionUrl,
					p12Password: password,
					certificateName: certName,
					isDefault: true
				) { _ in
					
				}
			}
			UserDefaults.standard.set(true, forKey: "feather.didImportDefaultCertificates")
		} catch {
			Logger.misc.error("Failed to list signing-assets: \(error)")
		}
	}

}
