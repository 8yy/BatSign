//
//  DownloadRescue.swift
//  Feather
//
//  A second attempt at a download whose finished file the system took back.
//
//  `URLSessionDownloadTask` hands its bytes over as a temp file that belongs to
//  the system and lives only for the length of the delegate callback. Almost
//  always that is enough. On a device that has just come back from a suspension
//  or through a system update it is not: the file can be gone before the
//  callback runs, and a transfer that used the network for a minute has nothing
//  to show for it.
//
//  This is the answer that does not depend on that file. The same URL is asked
//  for again over a session whose bytes are written, as they arrive, into a file
//  this app created in its own staging directory. Nothing the system does to its
//  own temp files can reach it, so a download that has already been paid for is
//  not lost twice.
//

import Foundation
import OSLog

final class DownloadRescue: NSObject, URLSessionDataDelegate {
	private static let log = Logger(subsystem: "app.batsign.ios", category: "download")

	/// One refetch: the transfer it belongs to, the file being written, and the
	/// two things the manager needs back from it.
	private struct Context {
		let download: Download
		let partial: URL
		let destination: URL
		var handle: FileHandle?
		var received: Int64 = 0
		var expected: Int64 = 0
		let onProgress: (Int64, Int64) -> Void
		let onFinish: (Result<URL, Error>) -> Void
	}

	enum RescueError: Error, LocalizedError {
		case httpStatus(Int)
		case notSaved(String)
		case incomplete(Int64, Int64)
		/// The drill that proves the last-resort message. Never thrown by a
		/// release build.
		case simulatedWriteFailure

		var errorDescription: String? {
			switch self {
			case .httpStatus(let status):
				return "The server answered HTTP \(status) for this file."
			case .notSaved(let reason):
				return reason
			case .incomplete(let got, let want):
				let have = ByteCountFormatter.string(fromByteCount: got, countStyle: .file)
				let needed = ByteCountFormatter.string(fromByteCount: want, countStyle: .file)
				return "The file arrived incomplete — \(have) of \(needed)."
			case .simulatedWriteFailure:
				return "BatSign could not write the file to storage."
			}
		}
	}

	/// The contexts, keyed by task identifier, and the lock that keeps `start`
	/// on the main actor from racing the session's own queue.
	private let lock = NSLock()
	private var contexts: [Int: Context] = [:]

	private var _session: URLSession?

	/// Whether this refetch is required to fail. Set by the `-vanishtempfail`
	/// launch argument, and only ever in a debug build.
	private let alwaysFails: Bool

	override init() {
		#if DEBUG
		alwaysFails = UserDefaults.standard.bool(forKey: "batsign.debug.vanishTempRescueFails")
		#else
		alwaysFails = false
		#endif
		super.init()
	}

	/// A session of this app's own.
	///
	/// Its bytes are delivered to the delegate above and written by this class,
	/// so no temp file of the system's is involved and there is nothing for a
	/// suspension to reclaim. Same shape as the app's ordinary transfer session
	/// otherwise — the request either goes out or fails where it can be seen.
	private var session: URLSession {
		if let _session { return _session }
		let configuration = URLSessionConfiguration.default
		configuration.allowsCellularAccess = true
		configuration.httpMaximumConnectionsPerHost = 4
		let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
		_session = session
		return session
	}

	/// Begin the refetch.
	///
	/// The task is handed to the manager's `Download` before it is resumed, so
	/// every path that cancels work — the row's cancel button, the job stopped
	/// from the card, the stall sweep — reaches this transfer through the same
	/// property it always used.
	func start(
		download: Download,
		destination: URL,
		suggestedFileName: String,
		onProgress: @escaping (Int64, Int64) -> Void,
		onFinish: @escaping (Result<URL, Error>) -> Void
	) {
		let fm = FileManager.default
		// The half-written file is named after the package it will become, so a
		// refetch interrupted by a kill leaves something the next launch can
		// recognise rather than an anonymous blob.
		let partial = destination.appendingPathExtension("rescue")
		try? fm.removeItem(at: partial)

		do {
			try fm.createDirectoryIfNeeded(at: destination.deletingLastPathComponent())
			guard fm.createFile(atPath: partial.path, contents: nil) else {
				throw RescueError.notSaved("BatSign could not create the file in its download folder.")
			}
			let handle = try FileHandle(forWritingTo: partial)

			let task = session.dataTask(with: download.url)
			let context = Context(
				download: download,
				partial: partial,
				destination: destination,
				handle: handle,
				onProgress: onProgress,
				onFinish: onFinish
			)

			lock.lock()
			contexts[task.taskIdentifier] = context
			lock.unlock()

			download.task = task
			Self.log.notice("download: refetching \(download.id.prefix(8), privacy: .public) — \(suggestedFileName, privacy: .public) is being written by BatSign itself")
			task.resume()
		} catch {
			Self.log.error("download: could not begin the refetch — \(error.localizedDescription, privacy: .public)")
			try? fm.removeItem(at: partial)
			onFinish(.failure(error))
		}
	}

	// MARK: - URLSessionDataDelegate

	func urlSession(
		_ session: URLSession,
		dataTask: URLSessionDataTask,
		didReceive response: URLResponse,
		completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
	) {
		let status = (response as? HTTPURLResponse)?.statusCode
		let expected = max(response.expectedContentLength, 0)

		lock.lock()
		let known = contexts[dataTask.taskIdentifier] != nil
		if var context = contexts[dataTask.taskIdentifier] {
			context.expected = expected
			contexts[dataTask.taskIdentifier] = context
		}
		lock.unlock()

		guard known else {
			completionHandler(.allow)
			return
		}

		if alwaysFails {
			// Drill: the refetch runs and its bytes cannot be saved, which is the
			// state the last-resort message exists for.
			Self.log.error("download: the refetch is being failed on purpose (vanishtempfail drill)")
			completionHandler(.cancel)
			_finish(dataTask.taskIdentifier, result: .failure(RescueError.simulatedWriteFailure))
			return
		}

		if let status, !(200...299).contains(status) {
			// A refusal is not a package. The status says so before a byte of the
			// body is written anywhere, and it is what the user reads.
			completionHandler(.cancel)
			_finish(dataTask.taskIdentifier, result: .failure(RescueError.httpStatus(status)))
			return
		}

		completionHandler(.allow)
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		lock.lock()
		guard var context = contexts[dataTask.taskIdentifier], let handle = context.handle else {
			lock.unlock()
			return
		}

		do {
			try handle.write(contentsOf: data)
		} catch {
			// Storage refused the bytes — out of space, or a file this process
			// may no longer write. The task is taken down with it so nothing
			// keeps streaming into a file that is not being written.
			lock.unlock()
			Self.log.error("download: the refetch could not write — \(error.localizedDescription, privacy: .public)")
			_finish(dataTask.taskIdentifier, result: .failure(RescueError.notSaved(error.localizedDescription)))
			dataTask.cancel()
			return
		}

		context.received += Int64(data.count)
		let received = context.received
		let expected = context.expected
		let onProgress = context.onProgress
		contexts[dataTask.taskIdentifier] = context
		lock.unlock()

		onProgress(received, expected)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		if let error {
			_finish(task.taskIdentifier, result: .failure(error))
			return
		}
		// No error: the bytes are all in. Where they go is decided below.
		_finish(task.taskIdentifier, result: nil)
	}

	// MARK: - Finishing

	/// The one place a refetch ends.
	///
	/// A second call for the same task finds no context and does nothing: the
	/// status path above finishes the task itself, and the cancellation error
	/// that follows must not become a second ending.
	private func _finish(_ identifier: Int, result: Result<URL, Error>?) {
		lock.lock()
		let context = contexts.removeValue(forKey: identifier)
		lock.unlock()

		guard let context else { return }
		try? context.handle?.close()

		guard let result else {
			// A body that stopped where the network did is not a package. The
			// length the server declared is the only thing that can say so here;
			// the zip signature downstream catches everything else.
			if context.expected > 0, context.received < context.expected {
				_clean(context)
				context.onFinish(.failure(RescueError.incomplete(context.received, context.expected)))
				return
			}

			do {
				// The same staging decision the ordinary delivery makes, from a
				// file this app wrote. It copies, so the partial can then go.
				_ = try DownloadManager._installFinishedFile(from: context.partial, to: context.destination)
				_clean(context)
				context.onFinish(.success(context.destination))
			} catch {
				_clean(context)
				context.onFinish(.failure(error))
			}
			return
		}

		_clean(context)
		context.onFinish(result)
	}

	/// The partial file goes in every ending.
	///
	/// A failed refetch leaves bytes that are not a package, and the name they
	/// carry is the name a later legitimate download would be given.
	private func _clean(_ context: Context) {
		try? FileManager.default.removeItem(at: context.partial)
	}
}
