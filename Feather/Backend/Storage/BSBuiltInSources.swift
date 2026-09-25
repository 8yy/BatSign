//
//  BSBuiltInSources.swift
//  Feather
//
//  The catalogues BatSign ships with.
//
//  A built-in source is not a subscription the user made and not one they can
//  manage: it is part of what the app is, in the same way its own screen is.
//  Two consequences follow from that, and both are load-bearing:
//
//  * It is never listed. The Sources tab is a list of what the *user* added —
//    every row there can be renamed, paused or removed, and a row that cannot
//    be removed does not belong in a list where every other row can be. Its
//    apps still appear everywhere apps appear, because that is a different
//    question from who put the catalogue there.
//
//  * It is always present. It is re-seeded at launch if it is missing, so
//    deleting the app's data, restoring a backup without it, or an upgrade from
//    a build that never had it all end with the same catalogue available.
//
//  The store is represented as an ordinary `AltSource` object rather than a
//  side-car list, so every existing reader — the fetch pipeline, the app index,
//  the download path, the update checker — keeps working without knowing that
//  this source is special. The special part is confined to two places: the
//  seeding below, and the filter the management surfaces apply.
//

import Foundation
import CoreData
import OSLog

enum BSBuiltInSources {
	/// Where the shipped catalogue comes from.
	///
	/// A plain AltStore repository, which is what the app already knows how to
	/// read: name, identifier, icon and an `apps` array of the usual shape.
	static let ipaVaultURL = URL(
		string: "https://raw.githubusercontent.com/927tx/IPA-Vault/refs/heads/main/ipavaultsource.json"
	)!

	/// The identifier the stored object carries.
	///
	/// Taken from the repository's own `identifier` field rather than the URL, so
	/// a future move of the file between hosts does not turn one built-in source
	/// into two. It is also the name `_removeLegacyBuiltIns` looks for when an
	/// older build shipped a different address for the same catalogue.
	static let ipaVaultIdentifier = "com.ipavault.source"

	/// Every built-in source, as the URLs the fetch pipeline consumes.
	static var allURLs: [URL] { [ipaVaultURL] }

	/// Whether an identifier names a source this build ships with.
	static func isBuiltIn(_ identifier: String?) -> Bool {
		guard let identifier, !identifier.isEmpty else { return false }
		return identifier == ipaVaultIdentifier
	}

	/// Whether a stored source is one of ours, by either of its names.
	///
	/// Matched on the URL as well as the identifier, because a record written by
	/// an earlier build — or by a hand-edited backup — carries whichever of the
	/// two that build knew about.
	static func isBuiltIn(_ source: AltSource) -> Bool {
		if isBuiltIn(source.identifier) { return true }
		return source.sourceURL?.absoluteString == ipaVaultURL.absoluteString
	}

	/// Put the shipped catalogue in place, if it is not already there.
	///
	/// Called at launch. Idempotent by construction: `addSource` refuses a
	/// duplicate identifier, so a second call is a no-op rather than a second
	/// row, and the whole of this is safe to run on every start.
	///
	/// The record is written without a fetch of the repository first. It has to
	/// be: seeding must not wait on the network, or a phone that is offline at
	/// first launch would have no catalogue until it next found a connection.
	/// The name and icon are filled in by the ordinary refresh path, which is
	/// the same path every user-added source goes through.
	@MainActor
	static func seed() {
		guard !Storage.shared.sourceExists(ipaVaultIdentifier) else { return }

		Storage.shared.addSource(
			ipaVaultURL,
			name: "IPA Vault",
			identifier: ipaVaultIdentifier,
			iconURL: nil
		) { error in
			if let error {
				BuiltInSourceLog.log.error(
					"sources: built-in catalogue could not be seeded — \(error.localizedDescription, privacy: .public)"
				)
			} else {
				BuiltInSourceLog.log.notice("sources: built-in catalogue seeded")
			}
		}
	}

	/// Unsubscribe the addresses earlier builds shipped with.
	///
	/// The catalogue moved hosts, and a phone upgrading from a build that seeded
	/// the old address would otherwise keep both: one live, one dead, both
	/// invisible in the Sources tab and therefore both impossible for the user to
	/// clear. Removing them here is what keeps "built in" meaning one source.
	@MainActor
	static func removeLegacyBuiltIns() {
		let retired: Set<String> = [
			"https://raw.githubusercontent.com/8yy/BatSign/main/app-repo.json",
			"https://repository.apptesters.org/apps.json"
		]
		for source in Storage.shared.getSources() {
			guard let url = source.sourceURL?.absoluteString, retired.contains(url) else { continue }
			BuiltInSourceLog.log.notice(
				"sources: removing a retired built-in catalogue — \(url, privacy: .public)"
			)
			Storage.shared.deleteSource(for: source)
		}
	}
}

private enum BuiltInSourceLog {
	static let log = Logger(subsystem: "app.batsign.ios", category: "sources")
}