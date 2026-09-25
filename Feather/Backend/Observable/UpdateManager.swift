//
//  UpdateManager.swift
//  Feather
//
//  Created by Dominic on 24.05.2026.
//

import AltSourceKit
import CoreData
import Foundation
import NimbleJSON

struct AppUpdate: Identifiable, Equatable {
	let id: String
	let localUUID: String
	let localVersion: String?
	let remoteVersion: String
	let appName: String
	let bundleIdentifier: String
	let downloadURL: URL
	let sourceURL: URL
	let sourceProvenance: SourceAppProvenance
	let whatsNew: String?
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?
	
	private let _dataService = NBFetchService()
	
	private init() {}
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid else { return nil }
		return updates[uuid]
	}
	
	func checkForUpdates(
		sources: [AltSource],
		localApps: [AppInfoPresentable],
		preserveOnFailure: Bool = false
	) async {
		guard !isChecking else { return }
		
		isChecking = true
		defer {
			isChecking = false
			lastCheckedDate = Date()
		}
		
		let repositories = await _fetchRepositories(from: sources)
		// No repository answered. The last known list is the truth until a
		// repository does — replacing it with "nothing" on a flapped link is
		// how one failed fetch made every pending update vanish from the
		// screen, and the badge with them.
		if repositories.isEmpty, preserveOnFailure { return }
		updates = _applySkips(_findUpdates(repositories: repositories, localApps: localApps))
	}

	// MARK: - Skips & Holds

	/// Updates the user dismissed by skipping or holding. Kept rather than
	/// discarded: "Unskip" is the reversal of "Skip", and re-running a full
	/// network check to get the entry back is not something a tap should depend
	/// on. A newer version published in the meantime replaces the stored one on
	/// the next check, and the stored one is dropped by `_applySkips` if the skip
	/// is still in force.
	private var _dismissedUpdates: [String: AppUpdate] = [:]

	func dismissUpdate(withLocalUUID id: String) {
		guard let removed = updates.removeValue(forKey: id) else { return }
		_dismissedUpdates[id] = removed
	}

	func isHeld(for identifier: String) -> Bool {
		let held = UserDefaults.standard.dictionary(forKey: "BatSign.heldApps") as? [String: Bool] ?? [:]
		return held[identifier] ?? false
	}

	func setHeld(_ held: Bool, for identifier: String) {
		var dict = UserDefaults.standard.dictionary(forKey: "BatSign.heldApps") as? [String: Bool] ?? [:]
		dict[identifier] = held
		UserDefaults.standard.set(dict, forKey: "BatSign.heldApps")
		// A held app's updates were removed from the list when it was held; the
		// release of the hold is the moment they come back, and nothing else
		// re-fetches them.
		if !held { _restoreDismissed(for: identifier) }
		objectWillChange.send()
	}

	func skip(version: String, for identifier: String) {
		var dict = UserDefaults.standard.dictionary(forKey: "BatSign.skippedVersions") as? [String: String] ?? [:]
		dict[identifier] = version
		UserDefaults.standard.set(dict, forKey: "BatSign.skippedVersions")
		objectWillChange.send()
	}

	func clearSkip(for identifier: String) {
		var dict = UserDefaults.standard.dictionary(forKey: "BatSign.skippedVersions") as? [String: String] ?? [:]
		dict.removeValue(forKey: identifier)
		UserDefaults.standard.set(dict, forKey: "BatSign.skippedVersions")
		// The whole point of the button. Without this the skip clears and the
		// update is still gone, which reads as Unskip having deleted it.
		_restoreDismissed(for: identifier)
		objectWillChange.send()
	}

	/// Puts back every update dismissed for this app that the skip/hold rules no
	/// longer suppress. Re-running the same filter that removed them is what
	/// keeps a *different* still-skipped version from sneaking back in, and it
	/// is also why the store only drops what was actually restored: an app can
	/// be held and skipped at once, and releasing one of the two must not burn
	/// the entry the other one still needs.
	private func _restoreDismissed(for identifier: String) {
		let matching = _dismissedUpdates.filter { $0.value.bundleIdentifier == identifier }
		guard !matching.isEmpty else { return }
		let restored = _applySkips(matching)
		// A newer version may already be showing — the source published again
		// after the skip, and a check found it. Restoring the old one over it
		// would turn an Unskip into a downgrade.
		for entry in restored where updates[entry.key] == nil {
			updates[entry.key] = entry.value
		}
		let restoredKeys = Set(restored.keys)
		_dismissedUpdates = _dismissedUpdates.filter { key, _ in
			!(matching[key] != nil && restoredKeys.contains(key))
		}
	}

	func skippedVersion(for identifier: String) -> String? {
		let skipped = UserDefaults.standard.dictionary(forKey: "BatSign.skippedVersions") as? [String: String] ?? [:]
		return skipped[identifier]
	}

	/// Removes held apps and skipped versions; a skipped version
	/// resurfaces automatically once something newer is published.
	private func _applySkips(_ found: [String: AppUpdate]) -> [String: AppUpdate] {
		let skipped = UserDefaults.standard.dictionary(forKey: "BatSign.skippedVersions") as? [String: String] ?? [:]
		let held = UserDefaults.standard.dictionary(forKey: "BatSign.heldApps") as? [String: Bool] ?? [:]

		return found.filter { entry in
			let update = entry.value
			if held[update.bundleIdentifier] == true { return false }
			if skipped[update.bundleIdentifier] == update.remoteVersion { return false }
			return true
		}
	}
	
	private func _fetchRepositories(from sources: [AltSource]) async -> [(AltSource, ASRepository)] {
		var repositories: [(AltSource, ASRepository)] = []
		
		for source in sources {
			guard let url = source.sourceURL else {
				continue
			}
			
			guard let repository = await _fetchRepository(from: url) else {
				continue
			}
			
			repositories.append((source, repository))
		}
		
		return repositories
	}
	
	private func _fetchRepository(from url: URL) async -> ASRepository? {
		await withCheckedContinuation { continuation in
			_dataService.fetch(from: url) { (result: RepositoryDataHandler) in
				switch result {
				case .success(let repository):
					continuation.resume(returning: repository)
				case .failure:
					continuation.resume(returning: nil)
				}
			}
		}
	}
	
	private func _findUpdates(
		repositories: [(AltSource, ASRepository)],
		localApps: [AppInfoPresentable]
	) -> [String: AppUpdate] {
		var foundUpdates: [String: AppUpdate] = [:]
		let metadataByUUID = Storage.shared.getSourceMetadata().reduce(into: [String: AppSourceMetadata]()) {
			$0[$1.appUUID] = $1
		}
		let metadataCandidates = localApps.compactMap { app -> SourceMetadataCandidate? in
			guard
				let uuid = app.uuid,
				let metadata = metadataByUUID[uuid]
			else {
				return nil
			}
			return SourceMetadataCandidate(appUUID: uuid, app: app, metadata: metadata)
		}
		
		for localApp in localApps {
			guard let localUUID = localApp.uuid else {
				continue
			}
			
			let sourceAppIdentifier: String
			let sourceAppVersion: String?
			let storedSourceURL: URL
			if
				let directMetadata = metadataByUUID[localUUID],
				let metadataSourceAppIdentifier = directMetadata.sourceAppIdentifier,
				let metadataSourceURL = directMetadata.sourceRepositoryURL
			{
				// A row that is missing either half is not a reason to stop
				// checking this app for ever. It used to `continue`, which meant
				// one half-written metadata row permanently silenced updates for
				// an app — the banner that never came back. Falling through to the
				// branches below re-derives what a complete row would have said.
				sourceAppIdentifier = metadataSourceAppIdentifier
				sourceAppVersion = directMetadata.sourceAppVersion
				storedSourceURL = metadataSourceURL
			} else if let fallback = _fallbackMetadataCandidate(
				for: localApp,
				localUUID: localUUID,
				candidates: metadataCandidates
			) {
				guard
					let metadataSourceAppIdentifier = fallback.metadata.sourceAppIdentifier,
					let metadataSourceURL = fallback.metadata.sourceRepositoryURL
				else {
					continue
				}
				
				sourceAppIdentifier = metadataSourceAppIdentifier
				sourceAppVersion = fallback.metadata.sourceAppVersion
				storedSourceURL = metadataSourceURL
				Storage.shared.copySourceMetadata(
					from: fallback.appUUID,
					to: localUUID,
					kind: localApp.isSigned ? .signed : .imported
				)
			} else if
				let localSourceURL = localApp.source,
				let localIdentifier = localApp.identifier
			{
				sourceAppIdentifier = localIdentifier
				sourceAppVersion = localApp.version
				storedSourceURL = localSourceURL
			} else {
				continue
			}
			
			for (source, repository) in repositories {
				guard let sourceURL = source.sourceURL else {
					continue
				}
				
				guard _matchesStoredRepository(storedSourceURL: storedSourceURL, sourceURL: sourceURL) else {
					continue
				}
				
				guard let remoteApp = repository.apps.first(where: { $0.id == sourceAppIdentifier }) else {
					continue
				}
				
				guard let remoteVersion = remoteApp.currentVersion, !remoteVersion.isEmpty else {
					continue
				}
				
				// An update is a *newer* build, not merely a different one. The
				// old test was plain string inequality, which made every one of
				// these read as an update: a downgrade published by a source, a
				// version re-published after a re-sign, and "1.0" against "1.0.0"
				// — a banner that installing never cleared, because the installed
				// version never became the string the source was comparing it to.
				guard _isRemoteNewer(remoteVersion, than: sourceAppVersion) else {
					continue
				}
				
				guard let downloadURL = remoteApp.currentDownloadUrl else {
					continue
				}
				
				guard let provenance = SourceAppProvenance(
					sourceURL: sourceURL,
					repository: repository,
					app: remoteApp
				) else {
					continue
				}
				
				foundUpdates[localUUID] = AppUpdate(
					id: localUUID,
					localUUID: localUUID,
					localVersion: sourceAppVersion ?? localApp.version,
					remoteVersion: remoteVersion,
					appName: remoteApp.currentName,
					bundleIdentifier: sourceAppIdentifier,
					downloadURL: downloadURL,
					sourceURL: sourceURL,
					sourceProvenance: provenance,
					whatsNew: remoteApp.currentAppVersion?.localizedDescription
				)
				break
			}
		}
		
		return foundUpdates
	}
	
	private func _matchesStoredRepository(
		storedSourceURL: URL,
		sourceURL: URL
	) -> Bool {
		_normalizedSourceURL(storedSourceURL) == _normalizedSourceURL(sourceURL)
	}

	/// Whether the version a source is publishing is genuinely newer than the
	/// one already on the device.
	///
	/// Version strings in this world are dot-separated numeric runs — "1.2",
	/// "2.0.4", "1.0b3" — and the only honest way to order them is by their
	/// numeric components, not as strings: "10" is newer than "9" and "1.0" is
	/// the same release as "1.0.0". A source that cannot be parsed at all falls
	/// back to a string comparison, because refusing to compare would mean a
	/// source publishing something unparseable never updates anything.
	private func _isRemoteNewer(_ remote: String, than local: String?) -> Bool {
		guard let local else { return true }
		if remote == local { return false }

		let remoteParts = remote.split(separator: ".").map { String($0) }
		let localParts = local.split(separator: ".").map { String($0) }

		// Both sides numeric enough to order: compare component by component,
		// a missing component counting as zero ("1.0" == "1.0.0").
		if remoteParts.allSatisfy({ Int($0) != nil }), localParts.allSatisfy({ Int($0) != nil }) {
			let count = max(remoteParts.count, localParts.count)
			for index in 0..<count {
				let remotePart = index < remoteParts.count ? Int(remoteParts[index]) ?? 0 : 0
				let localPart = index < localParts.count ? Int(localParts[index]) ?? 0 : 0
				if remotePart != localPart { return remotePart > localPart }
			}
			return false
		}

		return remote > local
	}
	
	private func _normalizedSourceURL(_ url: URL) -> String {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let scheme = components?.scheme?.lowercased()
		let host = components?.host?.lowercased()
		components?.scheme = scheme
		components?.host = host
		components?.fragment = nil
		
		let normalized = components?.url ?? url
		let absoluteString = normalized.absoluteString
		return absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
	}
	
	private func _fallbackMetadataCandidate(
		for localApp: AppInfoPresentable,
		localUUID: String,
		candidates: [SourceMetadataCandidate]
	) -> SourceMetadataCandidate? {
		guard
			localApp.isSigned,
			let localIdentifier = localApp.identifier,
			let localVersion = localApp.version
		else {
			return nil
		}
		
		return candidates.first {
			$0.appUUID != localUUID &&
			!$0.app.isSigned &&
			$0.app.identifier == localIdentifier &&
			$0.app.version == localVersion
		}
	}
}

private struct SourceMetadataCandidate {
	let appUUID: String
	let app: AppInfoPresentable
	let metadata: AppSourceMetadata
}
