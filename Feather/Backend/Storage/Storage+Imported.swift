//
//  Storage+Imported.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: Imported Apps
extension Storage {
	func addImported(
		uuid: String,
		source: URL? = nil,
		
		appName: String? = nil,
		appIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil,
		
		completion: @escaping (Error?) -> Void
	) {
		// The insert happens where the context lives, not on whatever thread the
		// import pipeline happens to be on. See `Storage.perform`.
		//
		// The save's error travels out: the importer waits on this completion,
		// and a Library row that did not land must not be reported as one that
		// did.
		var saveError: Error?
		perform {
			let new = Imported(context: self.context)
			
			new.uuid = uuid
			new.source = source
			new.date = Date()
			// could possibly be nil, but thats fine.
			new.identifier = appIdentifier
			new.name = appName
			new.icon = appIcon
			new.version = appVersion
			
			saveError = self.saveContext()
		} then: {
			UIImpactFeedbackGenerator(style: .light).impactOccurred()
			completion(saveError)
		}
	}
}
