//
//  Persistence.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import CoreData
import Foundation
import OSLog

// MARK: - Storage
final class Storage: ObservableObject {
	static let shared = Storage()
	let container: NSPersistentContainer
	
	private let _name: String = "Feather"

	init(inMemory: Bool = false) {
		container = NSPersistentContainer(name: _name)

		if inMemory {
			container.persistentStoreDescriptions.first?.url =
				URL(fileURLWithPath: "/dev/null")
		}
		
		container.persistentStoreDescriptions.first?.shouldMigrateStoreAutomatically = true
		container.persistentStoreDescriptions.first?.shouldInferMappingModelAutomatically = true

		_loadPersistentStoreAggressively()
		container.viewContext.automaticallyMergesChangesFromParent = true
		container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
	}

	var context: NSManagedObjectContext {
		container.viewContext
	}

	/// Run a change against the store on the queue that owns it.
	///
	/// `viewContext` is confined to the main queue and a managed object belongs
	/// to the queue that made it, but the import and signing pipelines run on
	/// detached tasks — so their inserts used to build objects on one thread and
	/// save them from another. Most of the time that works; sometimes it corrupts
	/// the store or takes the process down in the middle of an install, which the
	/// user sees as the app closing for no reason.
	///
	/// Every write goes through here, and the completion runs *after* the write
	/// has been made, so a caller that reports success is reporting something
	/// that actually happened.
	func perform(_ work: @escaping () -> Void, then completion: (() -> Void)? = nil) {
		let run = {
			work()
			completion?()
		}

		if Thread.isMainThread {
			run()
		} else {
			DispatchQueue.main.async(execute: run)
		}
	}

	/// Saves, and returns the error instead of only logging it.
	///
	/// Callers that merely log keep ignoring the result; the import pipeline
	/// uses it, because a save that failed is an app that is *not* in the
	/// Library even though its files on disk say it is — and reporting that as
	/// success is how a download appears to import and is never there.
	@discardableResult
	func saveContext() -> Error? {
		let save: () -> Error? = {
			guard self.context.hasChanges else { return nil }

			do {
				try self.context.save()
				return nil
			} catch {
				// `try?` used to swallow the one error that means the Library no
				// longer matches what is on disk.
				Logger.storage.error(
					"store: save failed — \(error.localizedDescription, privacy: .public)"
				)
				return error
			}
		}

		if Thread.isMainThread {
			return save()
		} else {
			var result: Error?
			let semaphore = DispatchSemaphore(value: 0)
			DispatchQueue.main.async {
				result = save()
				semaphore.signal()
			}
			semaphore.wait()
			return result
		}
	}
	
	func clearContext<T: NSManagedObject>(request: NSFetchRequest<T>) {
		let deleteRequest = NSBatchDeleteRequest(fetchRequest: (request as? NSFetchRequest<NSFetchRequestResult>)!)
		_ = try? context.execute(deleteRequest)
	}
	
	func countContent<T: NSManagedObject>(for type: T.Type) -> String {
		let request = T.fetchRequest()
		return "\((try? context.count(for: request)) ?? 0)"
	}

	/// Bring the store up, and never take the app down trying.
	///
	/// Two things were wrong with the old version. It destroyed the user's entire
	/// Library on *any* first-load error, including the transient ones — a device
	/// that is locked, a disk that is momentarily full — and if the reload after
	/// that also failed it called `fatalError`, so the app did not open at all.
	/// Data loss on a recoverable error, and a launch crash on an unrecoverable
	/// one, is the worst pair of answers available.
	///
	/// Now: only a store that genuinely cannot be read is destroyed, and a store
	/// that still will not load leaves a running app with an empty Library rather
	/// than no app. An app that opens and says the Library is unavailable is
	/// something the user can act on; a launch crash loop is not.
	private func _loadPersistentStoreAggressively() {
		container.loadPersistentStores { description, error in
			guard let error else { return }

			Logger.storage.error(
				"store: load failed — \(error.localizedDescription, privacy: .public)"
			)

			if Self._isUnrecoverable(error), let url = description.url {
				self._destroyStore(at: url)
			}

			self.container.loadPersistentStores { _, secondError in
				guard let secondError else { return }

				Logger.storage.error(
					"store: still unavailable — \(secondError.localizedDescription, privacy: .public)"
				)

				// Everything the app reads goes through this container, so it has
				// to have somewhere to read from. In memory means the session
				// works and nothing persists, which is visible and harmless; the
				// alternative was not launching.
				let fallback = NSPersistentStoreDescription(
					url: URL(fileURLWithPath: "/dev/null")
				)
				fallback.type = NSInMemoryStoreType
				self.container.persistentStoreDescriptions = [fallback]

				self.container.loadPersistentStores { _, thirdError in
					if let thirdError {
						Logger.storage.fault(
							"store: in-memory fallback failed — \(thirdError.localizedDescription, privacy: .public)"
						)
					}
				}
			}
		}
	}

	/// Whether a store is damaged rather than merely out of reach.
	///
	/// Destroying a store is the last resort, and these are the codes that
	/// justify it: the model no longer matches the file, or the file is not a
	/// store at all. A busy, locked or full device reports something else, and
	/// for those the data is still good and must be left alone.
	private static func _isUnrecoverable(_ error: Error) -> Bool {
		let codes: Set<Int> = [
			134100, // NSPersistentStoreIncompatibleVersionHashError
			134110, // NSMigrationMissingSourceModelError
			134130  // NSFileReadCorruptFileError — the SQLite file itself is broken
		]
		let ns = error as NSError
		return ns.domain == NSCocoaErrorDomain && codes.contains(ns.code)
	}

	private func _destroyStore(at url: URL?) {
		guard let url else { return }

		let base = url.deletingPathExtension()
		let fm = FileManager.default

		let files = [
			base.appendingPathExtension("sqlite"),
			base.appendingPathExtension("sqlite-wal"),
			base.appendingPathExtension("sqlite-shm")
		]

		for file in files {
			try? fm.removeItem(at: file)
		}
		
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.signed)
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.unsigned)
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.certificates)
		UserDefaults.standard.set(0, forKey: "feather.selectedCert")
	}
}
