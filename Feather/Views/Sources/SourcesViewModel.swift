//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import Foundation
import AltSourceKit
import SwiftUI
import NimbleJSON

// MARK: - Class
/// Holds the repository of every fetched source.
///
/// Main-actor bound, because `sources` is keyed by `AltSource` — a `viewContext`
/// object — and the batch fetches below run off the main actor.
@MainActor
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	private let _dataService = NBFetchService()
	
	var isFinished = true
	private var _fetchTask: Task<Void, Never>?
	@Published var sources: [AltSource: ASRepository] = [:]
	
	/// Fetch the repositories behind `sources`.
	///
	/// Takes any collection of sources, not just Core Data's fetched results: the
	/// Sources tab hands over a filtered array (the built-in catalogues are hidden
	/// from management there), while Apps and Today pass their full fetch results.
	@MainActor
	func fetchSources(_ sources: some Collection<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		// If another tab started the same shared fetch first, wait for it instead
		// of dropping this caller's request. This avoids Today remaining empty when
		// Sources or Apps owns the initial fetch during cold launch.
		if !isFinished {
			await _fetchTask?.value
			if !refresh, sources.allSatisfy({ self.sources[$0] != nil }) { return }
		}
		
		if !refresh, sources.allSatisfy({ self.sources[$0] != nil }) { return }
		isFinished = false
		let fetchTask = Task { @MainActor in
			defer { isFinished = true; _fetchTask = nil }
			await _performFetch(sources, refresh: refresh, batchSize: batchSize)
		}
		_fetchTask = fetchTask
		await fetchTask.value
	}

	private func _performFetch(
		_ sources: some Collection<AltSource>,
		refresh: Bool,
		batchSize: Int
	) async {
		
		let previouslyFetched = self.sources
		self.sources = [:]
		
		// The fetches run off the main actor and the sources are viewContext
		// objects, so each one is reduced to the value the fetch needs — its url —
		// here on the main actor. The object comes back into play only when the
		// results are written to `sources`, which happens on the main actor too.
		let sourcesArray: [(source: AltSource, url: URL)] = sources.compactMap { source in
			guard let url = source.sourceURL else { return nil }
			return (source: source, url: url)
		}
		let dataService = _dataService
		
		for startIndex in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, sourcesArray.count)
			let batch = sourcesArray[startIndex..<endIndex]
			
			let batchResults = await withTaskGroup(of: (URL, ASRepository?).self, returning: [URL: ASRepository].self) { group in
				for (_, url) in batch {
					group.addTask {
						return await withCheckedContinuation { (continuation: CheckedContinuation<(URL, ASRepository?), Never>) in
							dataService.fetch(from: url) { (result: RepositoryDataHandler) in
								switch result {
								case .success(let repo):
									continuation.resume(returning: (url, repo))
								case .failure(_):
									continuation.resume(returning: (url, nil))
								}
							}
						}
					}
				}
				
				var results = [URL: ASRepository]()
				for await (url, repo) in group {
					if let repo {
						results[url] = repo
					}
				}
				return results
			}
			
			for (source, url) in batch {
				guard let repo = batchResults[url] else {
					if let previous = previouslyFetched[source] {
						self.sources[source] = previous
					}
					continue
				}
				self.sources[source] = repo
			}
		}
	}
}
