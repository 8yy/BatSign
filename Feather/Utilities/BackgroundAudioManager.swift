//
//  BackgroundAudioManager.swift
//  Feather
//
//  Created by Nagata Asami on 12/10/25.
//
//  The hold that lets a signing job outlive the app being left.
//
//  A transfer is URLSession's business and survives suspension on its own. A
//  signing job is not: it is minutes of CPU work inside this process, and the
//  install hand-off after it is a local server that has to keep answering
//  installd while the user is on the Home Screen. Suspended in the middle of
//  either and the job simply stops — which is what "I left the app and it never
//  finished" is.
//
//  iOS schedules a process that has an audio session playing, for as long as it
//  plays. So a session is held active with a silent file playing on a loop, and
//  the app stays up for as long as it has work to do.
//
//  The player is a plain `AVAudioPlayer` over a one-second silent WAV this file
//  writes into the caches directory the first time it is asked to play. That is
//  deliberate, and it replaces an `AVAudioEngine` with a source node: an engine
//  has to be started against a hardware format, and when the source node's
//  format does not match what the output is running at — which is what a route
//  change or a different device produces — `start()` throws, the session is
//  never actually up, and the hold silently does nothing. That failure is
//  invisible: the app looks like it is holding, the job is suspended at the
//  first lock, and the only symptom is a download that stopped and an install
//  that never happened. A looping file has no format to negotiate and no start
//  to fail: it is the oldest and most reliable version of this hold.
//
//  Two things were missing from the version that did not work:
//
//  * `isRunning` was a belief. The engine could be stopped by a phone call, by
//    another app taking the output, by a route change or a media-services
//    reset, and the hold went on reporting itself as up. It now reports what is
//    actually playing — `player.isPlaying` — and puts the session back when the
//    system takes it away.
//
//  * Nothing ever checked. Recovery hung on the background-task assertion
//    expiring, which it does not do while something else is keeping the process
//    up. The keep-alive now asks this class every few seconds whether the hold
//    is still real, so a session that died quietly is put back within a tick
//    instead of being discovered by a job that stopped.
//

#if !targetEnvironment(macCatalyst)

import AVFoundation
import OSLog

final class BackgroundAudioManager {
	static let shared = BackgroundAudioManager()

	private static let log = Logger(subsystem: "app.batsign.ios", category: "keepalive")

	/// The silent source, played on a loop for as long as the hold is wanted.
	private var player: AVAudioPlayer?

	/// Where the silence comes from. Written once, on first use.
	private var fileURL: URL?

	private var isObserving = false
	private let lock = NSLock()
	private var _isRunning = false

	/// The last reason the hold could not be taken, for the console.
	private(set) var lastFailure: String?

	/// Whether the silent session is actually playing.
	///
	/// This is the honest answer, and it is deliberately not "we called
	/// `start()`": a caller that trusts a belief instead of a fact is a caller
	/// that does not notice the moment the hold is gone.
	var isRunning: Bool {
		lock.lock(); defer { lock.unlock() }
		return _isRunning && (player?.isPlaying ?? false)
	}

	private init() {
		observe()
	}

	// MARK: - Start and stop

	func start() {
		lock.lock()
		defer { lock.unlock() }

		if _isRunning, player?.isPlaying == true { return }

		do {
			let session = AVAudioSession.sharedInstance()

			// `.playback` with `.mixWithOthers` is the combination that both
			// keeps the process scheduled and does not stop whatever the user
			// is actually listening to. The silence is inaudible either way,
			// but a hold that pauses someone's music is a hold they will find.
			try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
			try session.setActive(true)

			let source = try sourceURL()
			let player: AVAudioPlayer
			if let existing = self.player {
				player = existing
			} else {
				player = try AVAudioPlayer(contentsOf: source)
			}
			// A file that never ends: the hold is not a playlist entry, and a
			// player that finishes is a process that becomes suspendable again
			// the moment it does.
			player.numberOfLoops = -1
			player.volume = 1
			player.prepareToPlay()

			guard player.play() else {
				_isRunning = false
				lastFailure = "play() returned false"
				Self.log.error("keepalive: silent hold refused to play")
				return
			}

			self.player = player
			_isRunning = player.isPlaying
			lastFailure = _isRunning ? nil : "player not playing after play()"
			Self.log.notice("keepalive: silent hold up (loops forever, sdk session active)")
		} catch {
			// Nothing to fall back to here. The background-task assertion over
			// the top of this is what covers the gap, and it is re-armed while
			// the work lasts — but the failure is logged rather than swallowed,
			// because a hold that fails silently is a job that stops silently.
			_isRunning = false
			lastFailure = error.localizedDescription
			Self.log.error("keepalive: silent hold failed — \(error.localizedDescription, privacy: .public)")
		}
	}

	func stop() {
		lock.lock()
		defer { lock.unlock() }
		_isRunning = false
		player?.stop()
		player = nil
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
		Self.log.notice("keepalive: silent hold released")
	}

	// MARK: - The silence

	/// A one-second silent WAV, written once and reused.
	///
	/// Generated rather than bundled: an asset that ships in the app is an asset
	/// that has to be right in every build, and this is 44 bytes of header and a
	/// second of zeroes.
	private func sourceURL() throws -> URL {
		if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
			return fileURL
		}

		let directory = FileManager.default
			.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("BatSignHold", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

		let url = directory.appendingPathComponent("hold.wav")
		if FileManager.default.fileExists(atPath: url.path) {
			fileURL = url
			return url
		}

		try Self.silentWAV(seconds: 1, sampleRate: 44_100).write(to: url, options: .atomic)
		fileURL = url
		return url
	}

	/// A minimal 16-bit mono PCM WAV of silence.
	private static func silentWAV(seconds: Double, sampleRate: UInt32) -> Data {
		let frameCount = UInt32(Double(sampleRate) * seconds)
		let byteCount = frameCount * 2

		var data = Data()
		func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		func append(_ ascii: String) { data.append(contentsOf: Array(ascii.utf8)) }

		append("RIFF")
		append(UInt32(36) + byteCount)
		append("WAVE")
		append("fmt ")
		append(UInt32(16))          // PCM header
		append(UInt16(1))           // linear PCM
		append(UInt16(1))           // mono
		append(sampleRate)
		append(sampleRate * 2)      // byte rate
		append(UInt16(2))           // block align
		append(UInt16(16))          // bits per sample
		append("data")
		append(byteCount)
		data.append(Data(count: Int(byteCount)))
		return data
	}

	// MARK: - Putting the session back

	/// Put the session back when the system takes it away.
	private func observe() {
		guard !isObserving else { return }
		isObserving = true

		let center = NotificationCenter.default
		let session = AVAudioSession.sharedInstance()

		center.addObserver(
			forName: AVAudioSession.interruptionNotification,
			object: session,
			queue: .main
		) { [weak self] note in
			guard
				let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
				let type = AVAudioSession.InterruptionType(rawValue: raw)
			else { return }

			switch type {
			case .began:
				// The session is gone and the process is suspendable again.
				// Saying so is the point: `isRunning` has to be false or the
				// keep-alive will never think to put it back.
				Self.log.notice("keepalive: audio session interrupted")
				self?.lock.lock()
				self?._isRunning = false
				self?.lock.unlock()
			case .ended:
				self?.restart()
			@unknown default:
				break
			}
		}

		// A route change — headphones in or out, a Bluetooth device arriving,
		// the speaker changing over — can stop a player without an
		// interruption being reported at all.
		center.addObserver(
			forName: AVAudioSession.routeChangeNotification,
			object: session,
			queue: .main
		) { [weak self] _ in
			self?.restart()
		}

		center.addObserver(
			forName: AVAudioSession.mediaServicesWereResetNotification,
			object: session,
			queue: .main
		) { [weak self] _ in
			self?.restart()
		}

		center.addObserver(
			forName: AVAudioSession.mediaServicesWereLostNotification,
			object: session,
			queue: .main
		) { [weak self] _ in
			self?.restart()
		}

		// The two moments a hold tends to be lost without anyone noticing: on
		// the way out, which is exactly when it starts to matter, and on the way
		// back in, where a session that died while the app was away would
		// otherwise sit dead until the next assertion expiry.
		center.addObserver(
			forName: UIApplication.didEnterBackgroundNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?.restart()
		}

		center.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?.restart()
		}
	}

	/// Start again if the hold is still wanted.
	///
	/// The manager does not know who is holding it, so the keep-alive is asked.
	/// Reaching back the other way would be a cycle between two singletons that
	/// both want to be the one at the top; asking is the cheaper relationship.
	func restart() {
		Task { @MainActor in
			guard BSJobKeepAlive.shared.isHolding else { return }
			self.lock.lock()
			self._isRunning = false
			self.player?.stop()
			self.player = nil
			self.lock.unlock()
			self.start()
		}
	}
}

#endif
