//
//  BSShotCache.swift
//  Feather
//
//  Starts an app page's screenshots downloading before anything asks to draw
//  them.
//
//  A Preview is eight full-width renders from a CDN that answers each one in a
//  few hundred milliseconds, and they are laid out in a horizontal carousel —
//  so without this, the page pays for two shots on open and the other six only
//  when the user scrolls to them, one at a time, each one visibly arriving.
//
//  Warming them all at once turns that into a single parallel wait that has
//  already started by the time the row is on screen. It is the same trick the
//  reference app uses: the prefetcher writes into the identical
//  `ImagePipeline.shared` cache that the cards read from, so a card that
//  appears a moment later finds its image already decoded in memory rather than
//  starting a request of its own.
//
//  Two deliberate choices:
//
//  * `destination: .memoryCache`. Warming the *disk* cache would help the next
//    launch and do nothing for this one — the decode is most of the wait, and
//    only the memory cache holds the decoded image.
//
//  * Six at a time. Enough to fetch a whole row in about the time of its
//    slowest shot, few enough that a page opening does not starve the icon and
//    the banner that are above the fold.
//

import Foundation
import Nuke

enum BSShotCache {
	private static let prefetcher = ImagePrefetcher(
		pipeline: .shared,
		destination: .memoryCache,
		maxConcurrentRequestCount: 6
	)

	/// Start fetching these, in the background, right now.
	///
	/// Safe to call repeatedly — the prefetcher de-duplicates against what it is
	/// already fetching and against what the cache already holds, which is what
	/// makes it fine to warm the same row again when the page's shots change from
	/// what the repository published to what the App Store answered.
	static func warm(_ urls: [URL]) {
		guard !urls.isEmpty else { return }
		prefetcher.startPrefetching(with: Array(Set(urls)))
	}

	/// Same, one URL.
	static func warm(_ url: URL?) {
		guard let url else { return }
		warm([url])
	}
}
