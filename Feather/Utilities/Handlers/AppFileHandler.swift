//
//  IPAHandler.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import Foundation
import OSLog
import Zip
import SwiftUI

final class AppFileHandler: NSObject, @unchecked Sendable {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private let _uniqueWorkDir: URL
	var uniqueWorkDirPayload: URL?

	private var _ipa: URL
	private let _install: Bool
	private let _download: Download?
	private let _sourceProvenance: SourceAppProvenance?
	/// The transfer this import belongs to, for the paths that import without a
	/// live `Download` object — the no-owner wake-up and the launch recovery.
	private let _transferID: String?
	
	init(
		file ipa: URL,
		install: Bool = false,
		download: Download? = nil,
		sourceProvenance: SourceAppProvenance? = nil,
		transferID: String? = nil
	) {
		self._ipa = ipa
		self._install = install
		self._download = download
		self._sourceProvenance = sourceProvenance ?? download?.sourceProvenance
		self._transferID = transferID ?? download?.id
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("FeatherImport_\(_uuid)", isDirectory: true)
		
		super.init()
	}
	
	func copy() async throws {
		try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)
		
		let destinationURL = _uniqueWorkDir.appendingPathComponent(_ipa.lastPathComponent)

		try _fileManager.removeFileIfNeeded(at: destinationURL)
		
		try _fileManager.copyItem(at: _ipa, to: destinationURL)
		_ipa = destinationURL
	}
	
	func extract() async throws {
		if _ipa.pathExtension == "ipa" {
			Zip.addCustomFileExtension("ipa")
		}
		if _ipa.pathExtension == "tipa" {
			Zip.addCustomFileExtension("tipa")
		}
		
		let download = self._download
		
		try await withCheckedThrowingContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				do {
					// the zip library joins entry names onto the destination as
					// they are, so a crafted ipa gets a say in where its files
					// land — the archive is checked over before it is unpacked
					try Self._rejectUnsafeArchiveEntries(self._ipa, base: self._uniqueWorkDir)
					
					try Zip.unzipFile(
						self._ipa,
						destination: self._uniqueWorkDir,
						overwrite: true,
						password: nil,
						progress: { progress in
							if let download = download {
								DispatchQueue.main.async {
									download.unpackageProgress = progress
									DownloadManager.shared.progressDidMove()
								}
							}
						}
					)
					
					self.uniqueWorkDirPayload = self._uniqueWorkDir.appendingPathComponent("Payload")
					continuation.resume()
				} catch let error as ImportedFileHandlerError {
					// Already a sentence the user can act on — the safety refusal
					// in particular must keep its own words.
					continuation.resume(throwing: error)
				} catch {
					// The zip library names the symptom, not the cause: a
					// corrupt or non-package file comes out as "Zip.ZipError
					// error 1", which is the sentence the user reported. The
					// package was never a package, or it is damaged — that is
					// what is said instead, with the file's own name on it.
					continuation.resume(throwing: ImportedFileHandlerError.unreadablePackage(self._ipa.lastPathComponent))
				}
			}
		}
	}
	
	func move() async throws {
		guard let payloadURL = uniqueWorkDirPayload else {
			throw ImportedFileHandlerError.payloadNotFound
		}
		
		let destinationURL = try await _directory()
		
		guard _fileManager.fileExists(atPath: payloadURL.path) else {
			throw ImportedFileHandlerError.payloadNotFound
		}
		
		try _fileManager.moveItem(at: payloadURL, to: destinationURL)
		
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}
	
	func addToDatabase() async throws {
		let app = try await _directory()
		
		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			// Returning here is how a finished download vanishes: the package is
			// unpacked, no app is found inside it, and the job ends looking like
			// a success — nothing in the Library, and nothing said about it.
			//
			// The bundle was already moved into `Unsigned/<uuid>` by `move()`,
			// and no Library row will ever point at it — it goes with the
			// failure rather than sitting there ownerless.
			try? _fileManager.removeFileIfNeeded(at: app)
			throw ImportedFileHandlerError.appNotFound
		}
		
		let bundle = Bundle(url: appUrl)

		// Wait for the Library row to be committed before anything reads it
		// back. The signing queue looks the record up by uuid, and `addImported`
		// used to be fire-and-forget: its completion was discarded, so the save
		// was only *scheduled* on the main queue while this function went on to
		// enqueue signing. Nothing guaranteed the save ran first, and a fetch
		// that found nothing meant an app that downloaded, appeared in the
		// Library, and was never signed — the card stuck on "Signing" for ever.
		do {
			try await _awaitImport(bundle: bundle)
		} catch {
			// Same ownerless-directory rule: the row did not land, so the moved
			// bundle must not stay behind as a directory nothing points at.
			try? _fileManager.removeFileIfNeeded(at: app)
			throw error
		}

		// The Library row exists: this transfer's job in the journal is spent,
		// whatever happens to the signing that follows. Left there, the record
		// blocks the signing-resume record the queue writes next (the journal is
		// one slot, and `record(signing:)` yields to an existing entry) and the
		// next launch re-imports the staged package — a second Library row for
		// one download. Clearing it here is what lets a signing job killed
		// mid-work be resumed from the Library instead of duplicated from disk.
		if let transferID = _transferID {
			BSJobJournal.shared.clearIf(transferID: transferID)
		}

		if let sourceProvenance = _sourceProvenance {
			Storage.shared.addSourceMetadata(
				for: _uuid,
				kind: .imported,
				provenance: sourceProvenance
			)
		}

		// The job has just learned the bundle id the app is actually going to
		// be signed and installed as. The live card was started under the
		// transfer's own id, and every phase from here on addresses the app by
		// this one — so the card is taught the second name before anything else
		// happens, and it keeps updating instead of being left behind.
		if let download = _download, let identifier = bundle?.bundleIdentifier {
			await MainActor.run {
				LiveStatus.addAlias(identifier, for: download.liveID)
			}
		}

		// BatSign: route fresh imports into the background signing queue.
		// Automatic update downloads skip the queue when auto-signing is
		// disabled for that app, manual imports always honour the toggle.
		//
		// Every refusal here has to be paid for with an ending. The card was
		// set to "Signing"/"Updating" before this ran, and the queue retires a
		// card only for a job it accepted — so a refusal that returns silently
		// leaves the card on that phase for as long as the app runs. That is
		// the whole of "it downloaded and then nothing happened": the app is in
		// the Library and the island is still promising to sign it.
		let transferID = _download?.id
		let isAutoUpdateDownload = transferID?.hasPrefix(BatSignAuto.downloadPrefix) ?? false
		// A manual update is the same job from the user's point of view — an
		// app they already have, being replaced — and it is named as one. The
		// automatic gating below does not apply: the user asked for this one
		// directly, so the per-app automatic toggle has no say in it.
		let isManualUpdateDownload = transferID?.hasPrefix(BatSignAuto.manualUpdatePrefix) ?? false
		let autoIdentifier = bundle?.bundleIdentifier
		let cardName = _download?.cardName ?? bundle?.name ?? "App"
		let cardID = _download?.liveID ?? autoIdentifier ?? _uuid
		await MainActor.run {
				if isManualUpdateDownload {
					_collectOrEnqueue(
						uuid: _uuid, reason: .autoUpdate, name: cardName, id: cardID, identifier: autoIdentifier
					)
				} else if isAutoUpdateDownload {
					guard
						let identifier = autoIdentifier,
						AutoUpdateManager.shared.isAutoUpdateEnabled(for: identifier)
					else {
						_autoSignRefused(name: cardName, id: cardID, reason: "Automatic signing is off for this app.")
						return
					}
					// Named as an update, not an import: this is the half of the
					// job that replaces an app already in the Library, and the
					// card that has been saying "Updating" since the download
					// started keeps saying it.
					//
					// And signed here and now, in either mode. This is the
					// app keeping *itself* current on a schedule the person
					// already switched on; holding it in a tray would leave
					// them running the build they asked to have replaced.
					_enqueueOrFail(uuid: _uuid, reason: .autoUpdate, name: cardName, id: cardID)
				} else {
					_collectOrEnqueue(
						uuid: _uuid, reason: .autoSign, name: cardName, id: cardID, identifier: autoIdentifier
					)
				}
			}
	}

	/// The arriving app, routed by the system the person chose.
	///
	/// Both systems start here, which is the only place that knows an app has
	/// just landed — so neither can be left out of a path that forgot it, and
	/// "which of the two is running" is answered once, in the tray's own mode.
	///
	/// The order of the three answers is the whole of the design:
	///
	///   1. A run that is waiting for this very package takes it, in either
	///      mode. The person picked those apps by name and pressed the button;
	///      a mode about arrivals nobody has confirmed cannot overrule a tap.
	///   2. Collect mode holds it in the tray, and the card is ended — the
	///      download is over and this app is not being signed now, so leaving
	///      the card on "Signing" would be the island promising work nobody
	///      started.
	///   3. Otherwise it is signed the way it always was: at once.
	@MainActor
	private func _collectOrEnqueue(
		uuid: String,
		reason: AutoSignManager.Reason,
		name: String,
		id: String,
		identifier: String?
	) {
		guard !BSBulkSign.shared.isWaiting(for: id) else {
			_enqueueOrFail(uuid: uuid, reason: reason, name: name, id: id)
			return
		}

		if BSPendingSign.shared.collect(uuid: uuid, name: name, identifier: identifier) {
			// The transfer's journal entry goes with this decision, and it has
			// to: the journal exists to finish jobs at the next launch, and a
			// package held for a confirmation is a job the person has *paused*,
			// not one they abandoned. Left armed, the recovery did exactly what
			// it is written to do — re-imported and signed the package while the
			// app sat in the tray — and the mode promised the opposite of that.
			if let transferID = _download?.id {
				BSJobJournal.shared.clearIf(transferID: transferID)
			}
			LiveStatus.finish(
				success: true,
				appName: name,
				detail: "Waiting for you to sign",
				appID: id
			)
			return
		}

		_enqueueOrFail(uuid: uuid, reason: reason, name: name, id: id)
	}

	/// Enqueue, and say it out loud when the queue will not take the job.
	@MainActor
	private func _enqueueOrFail(uuid: String, reason: AutoSignManager.Reason, name: String, id: String) {
		// A package that arrived as part of a multi-sign run is signed whatever
		// the automatic-signing preference says: the person picked these apps by
		// name and pressed the button for them, and this import is the answer to
		// that. The run is told which of its own rows this is, so its strip and
		// the card can say "2 of 5" rather than showing an unrelated single job
		// beside work that is already under way.
		if let claim = BSBulkSign.shared.claim(transferID: id) {
			let queued = AutoSignManager.shared.enqueueImported(
				uuid: uuid,
				reason: reason,
				batch: claim.batch,
				force: true
			)
			if !queued {
				BSBulkSign.shared.markFailed(claim.itemID, reason: "It could not be queued for signing")
			}
			return
		}

		if AutoSignManager.shared.enqueueImported(uuid: uuid, reason: reason) { return }

		let detail: String
		if AutoSignManager.shared.isAutoSignEnabled {
			// The toggle is on and the queue still refused, which means the
			// Library row this hand-off just wrote could not be read back.
			detail = "The app was imported but could not be queued for signing. Open BatSign and sign it from your Library."
		} else {
			detail = "Automatic signing is turned off. Sign \(name) from your Library to install it."
		}
		_autoSignRefused(name: name, id: id, reason: detail)
	}

	/// The queue did not take the job. The card has to end, and the user has to
	/// be the one told — the download is over either way, and an app sitting
	/// unsigned in the Library is news, not a stuck progress ring.
	@MainActor
	private func _autoSignRefused(name: String, id: String, reason: String) {
		LiveStatus.finish(success: false, appName: name, detail: reason, appID: id)
		AutoSignManager.shared.announceDownloadRefused(name: name, identifier: id, message: reason)
		// The import succeeded — the Library row exists — so this transfer's
		// record is spent. Left in the journal, the next launch's recovery
		// re-imports the same staged package under a fresh UUID: a duplicate
		// row for an app the user has already been told is waiting to sign.
		if let transferID = _download?.id {
			BSJobJournal.shared.clearIf(transferID: transferID)
		}
	}
	
	/// Runs the Library insert to completion and reports whether it landed.
	///
	/// `Storage.addImported` hops to the main queue and only saves once it is
	/// there, so a caller that returns without waiting has not necessarily
	/// written anything. The continuation is resumed from `addImported`'s own
	/// `then:`, which runs after `saveContext()`.
	private func _awaitImport(bundle: Bundle?) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			Storage.shared.addImported(
				uuid: _uuid,
				source: _sourceProvenance?.sourceRepositoryURL,
				appName: bundle?.name,
				appIdentifier: bundle?.bundleIdentifier,
				appVersion: bundle?.version,
				appIcon: bundle?.iconFileName
			) { error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume()
				}
			}
		}
	}

	private func _directory() async throws -> URL {
		// Documents/Feather/Unsigned/\(UUID)
		_fileManager.unsigned(_uuid)
	}
	
	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
	}
	
	// MARK: - Archive entry validation
	
	/// Reads the entry names out of an archive's central directory and refuses
	/// the archive if any of them would be unpacked outside of `base`.
	private static func _rejectUnsafeArchiveEntries(_ url: URL, base: URL) throws {
		guard let entryNames = _zipEntryNames(in: url) else {
			// a central directory we cannot read is one the unzip is going to
			// trip over itself, so this is worth a note rather than a refusal
			Logger.misc.warning("Skipped archive entry validation for \(url.lastPathComponent, privacy: .public)")
			return
		}
		
		let basePath = base.standardized.path
		
		for name in entryNames {
			// both separators are legal in a zip, and one can hide the other
			let normalized = name.replacingOccurrences(of: "\\", with: "/")
			let resolved = base.appendingPathComponent(normalized).standardized.path
			
			guard
				!normalized.hasPrefix("/"),
				resolved == basePath || resolved.hasPrefix(basePath + "/")
			else {
				throw ImportedFileHandlerError.unsafeArchiveEntry(name)
			}
		}
	}
	
	/// Reads the entry names out of a zip's central directory. Only the tail of
	/// the file and the directory itself are read, so a multi gigabyte ipa is
	/// never pulled into memory. A nil means the layout could not be parsed.
	private static func _zipEntryNames(in url: URL) -> [String]? {
		guard let handle = try? FileHandle(forReadingFrom: url) else {
			return nil
		}
		defer { try? handle.close() }
		
		let fileSize = Int64(handle.seekToEndOfFile())
		guard fileSize >= 22 else {
			return nil
		}
		
		// the end of central directory record sits at the end of the file,
		// behind however much archive comment there is, 65535 bytes at most
		let tailLength = Int(min(fileSize, 65557))
		guard let tail = _read(handle, at: fileSize - Int64(tailLength), length: tailLength) else {
			return nil
		}
		guard let eocd = _lastIndex(of: 0x06054b50, in: tail) else {
			return nil
		}
		
		var directoryOffset = UInt64(_uint32(tail, eocd + 16) ?? 0)
		var directoryLength = UInt64(_uint32(tail, eocd + 12) ?? 0)
		
		// zip64 keeps the real offsets and sizes in a record of its own, which
		// a locator sitting in front of the usual record points at
		if
			eocd >= 20,
			_uint32(tail, eocd - 20) == 0x07064b50,
			let locatorOffset = _uint64(tail, eocd - 12),
			locatorOffset <= UInt64(Int64.max),
			let record = _read(handle, at: Int64(locatorOffset), length: 56),
			_uint32(record, 0) == 0x06064b50
		{
			directoryLength = _uint64(record, 40) ?? directoryLength
			directoryOffset = _uint64(record, 48) ?? directoryOffset
		}
		
		// a directory that large is not one worth chasing, and the offsets have
		// to land inside the file either way
		guard
			directoryLength > 0,
			directoryLength <= 64 * 1024 * 1024,
			directoryOffset <= UInt64(fileSize),
			directoryLength <= UInt64(fileSize) - directoryOffset
		else {
			return nil
		}
		
		guard let directory = _read(handle, at: Int64(directoryOffset), length: Int(directoryLength)) else {
			return nil
		}
		
		return _entryNames(in: directory)
	}
	
	/// Walks the records of a central directory, each one names an entry.
	private static func _entryNames(in directory: Data) -> [String]? {
		guard _uint32(directory, 0) == 0x02014b50 else {
			return nil
		}
		
		var names: [String] = []
		var offset = 0
		
		while offset + 46 <= directory.count {
			// anything that is not another record is the end of the directory,
			// or a record that carries no name of its own
			guard _uint32(directory, offset) == 0x02014b50 else {
				break
			}
			
			guard
				let nameLength = _uint16(directory, offset + 28),
				let extraLength = _uint16(directory, offset + 30),
				let commentLength = _uint16(directory, offset + 32),
				offset + 46 + nameLength <= directory.count
			else {
				return nil
			}
			
			let nameData = directory.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
			// utf8 is what the format asks for, a latin-1 reading still keeps
			// the separators and dots of an older archive intact
			names.append(String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? "")
			
			offset += 46 + nameLength + extraLength + commentLength
		}
		
		return names
	}
	
	private static func _read(_ handle: FileHandle, at offset: Int64, length: Int) -> Data? {
		guard offset >= 0, length > 0 else {
			return nil
		}
		
		do {
			try handle.seek(toOffset: UInt64(offset))
			guard let data = try handle.read(upToCount: length), data.count == length else {
				return nil
			}
			return data
		} catch {
			return nil
		}
	}
	
	// every signature and number in a zip record is stored little endian
	private static func _lastIndex(of signature: UInt32, in data: Data) -> Int? {
		let bytes: [UInt8] = [
			UInt8(signature & 0xff),
			UInt8((signature >> 8) & 0xff),
			UInt8((signature >> 16) & 0xff),
			UInt8((signature >> 24) & 0xff)
		]
		
		guard data.count >= bytes.count else {
			return nil
		}
		
		for index in stride(from: data.count - bytes.count, through: 0, by: -1) {
			if
				data[index] == bytes[0],
				data[index + 1] == bytes[1],
				data[index + 2] == bytes[2],
				data[index + 3] == bytes[3]
			{
				return index
			}
		}
		
		return nil
	}
	
	private static func _uint16(_ data: Data, _ offset: Int) -> Int? {
		guard offset >= 0, offset + 2 <= data.count else {
			return nil
		}
		
		return Int(data[offset]) | (Int(data[offset + 1]) << 8)
	}
	
	private static func _uint32(_ data: Data, _ offset: Int) -> UInt32? {
		guard offset >= 0, offset + 4 <= data.count else {
			return nil
		}
		
		var value: UInt32 = 0
		for byte in (0..<4).reversed() {
			value = (value << 8) | UInt32(data[offset + byte])
		}
		return value
	}
	
	private static func _uint64(_ data: Data, _ offset: Int) -> UInt64? {
		guard offset >= 0, offset + 8 <= data.count else {
			return nil
		}
		
		var value: UInt64 = 0
		for byte in (0..<8).reversed() {
			value = (value << 8) | UInt64(data[offset + byte])
		}
		return value
	}
}

private enum ImportedFileHandlerError: Error, LocalizedError {
	case payloadNotFound
	case appNotFound
	case unsafeArchiveEntry(String)
	case unreadablePackage(String)

	/// What the user is told when a package they asked for cannot be opened.
	/// These sentences are the whole of it: the download failed, this is why, and
	/// the alternative is an enum's own description, which says nothing.
	var errorDescription: String? {
		switch self {
		case .payloadNotFound:
			"The package has no Payload folder — it is not an app."
		case .appNotFound:
			"The package has no app inside its Payload folder."
		case .unsafeArchiveEntry(let entry):
			"The package tries to write outside its own folder (\(entry)), so it was refused."
		case .unreadablePackage(let name):
			"‘\(name)’ could not be opened — the file is not a valid app package."
		}
	}
}
