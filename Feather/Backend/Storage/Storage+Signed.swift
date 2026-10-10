//
//  Storage+Signed.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: Signed Apps
extension Storage {
	func addSigned(
		uuid: String,
		source: URL? = nil,
		certificate: CertificatePair? = nil,

		appName: String? = nil,
		appIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil,

		completion: @escaping (Error?) -> Void
	) {
		var saveError: Error?
		perform {
			let new = Signed(context: self.context)
			new.uuid = uuid
			new.source = source
			new.date = Date()
			new.certificate = certificate
			new.identifier = appIdentifier
			new.name = appName
			new.icon = appIcon
			new.version = appVersion
			saveError = self.saveContext()
			if saveError != nil {
				self.context.delete(new)
			}
		} then: {
			UIImpactFeedbackGenerator(style: .light).impactOccurred()
			completion(saveError)
		}
	}

	/// The apps this app has signed, by bundle id, with the version it signed.
	///
	/// The scan that reads the phone can see that an app appeared, but not who put
	/// it there — an app from the App Store is exactly as new as one installed
	/// from a source. This is the other half of that answer: what this app has
	/// produced, and therefore what it may claim.
	func signedAppsByIdentifier() -> [String: String] {
		let fetchRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
		let results = (try? context.fetch(fetchRequest)) ?? []

		var signed: [String: String] = [:]
		for app in results {
			guard let identifier = app.identifier, !identifier.isEmpty else { continue }
			signed[identifier] = app.version ?? ""
		}
		return signed
	}
}
