//
//  AppStoreLookup.swift
//  Feather
//
//  The App Store's own record for an app, asked for by bundle identifier.
//
//  An alt-source repository is a thin catalogue: it knows an app's name, its
//  icon and where to download it, and often nothing else. A repository that
//  publishes no screenshots leaves the app page with no Preview at all, and no
//  repository publishes a rating or an age rating, because those belong to the
//  App Store — the same bundle identifier the App Store serves answers for.
//
//  So the page asks the store: one lookup per app page, keyed by bundle id,
//  decoding only what the page can honestly use. Everything is optional. A
//  miss (a removed app, a region where it was never listed, no network) is a
//  legitimate answer that must not decorate itself as data, which is why a
//  miss is cached as a miss and the page falls back to what the source said.
//
//  Nothing here throws. A storefront that was slow, refused us or answered
//  with a shape we did not expect must leave the page exactly as it was.
//

import Foundation
import AltSourceKit

enum AppStoreLookup {
	/// What a lookup can honestly contribute to an app page.
	struct Item: Sendable {
		var screenshots: [ASRepository.App.Screenshots.Shot] = []
		var rating: Double?
		var ratingCount: Int?
		var age: String?
		var summary: String?
		var developer: String?
		var category: String?
		var version: String?
		var bytes: Int64?
		var released: Date?
	}

	/// The same shot, asked for at a size worth *measuring* rather than drawing.
	///
	/// A shape needs a few dozen pixels to be known, and the render the card
	/// draws is a couple of hundred kilobytes — eight of them is more than the
	/// page can afford before it has laid out a single card. Measured cold, the
	/// difference is between a Preview that is there in a moment and one that
	/// arrives after the rest of the page has been read.
	///
	/// It keeps the shot's own proportions, so it measures the same shape the
	/// sharp render will have, and it is in the pipeline's cache by the time the
	/// card wants something to show while that render is in flight.
	static func probeURL(_ url: URL, width: Int = 160) -> URL {
		Wire.render(url, width: width)
	}

	/// The sized render of a store shot — the same file, at exactly the pixels
	/// a card or a full-screen preview can show. The store answers arbitrary
	/// widths, so a card never has to decode a full-size asset; a URL that is
	/// not a store shot is returned unchanged, and the image pipeline's
	/// downsampling handles it instead.
	static func renderURL(_ url: URL, width: Int) -> URL {
		Wire.render(url, width: width)
	}

	/// The store's record for a bundle id, or nil when the store has none.
	static func item(bundleID: String) async -> Item? {
		// A repository may mark a build as a beta by suffixing the identifier;
		// that build's record is still the store's record for the app.
		var identifier = bundleID
		if identifier.hasSuffix("Beta") {
			identifier = String(identifier.dropLast(4))
		}
		let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !key.isEmpty else { return nil }

		return await Store.shared.item(for: key)
	}
}

// MARK: - Cache

/// One lookup per bundle id per launch, shared by every page that asks.
///
/// The storefront is not a hot loop, but a user can open the same page more
/// than once and a cold page can be opened while its own request is still in
/// flight; both collapse onto a single request here rather than racing.
private actor Store {
	static let shared = Store()

	private var cache: [String: AppStoreLookup.Item?] = [:]
	private var inFlight: [String: Task<AppStoreLookup.Item?, Never>] = [:]

	func item(for bundleID: String) async -> AppStoreLookup.Item? {
		if let cached = cache[bundleID] { return cached }
		if let running = inFlight[bundleID] { return await running.value }

		let task = Task<AppStoreLookup.Item?, Never> { await Lookup.run(bundleID: bundleID) }
		inFlight[bundleID] = task
		let item = await task.value
		inFlight[bundleID] = nil
		cache[bundleID] = item
		return item
	}
}

// MARK: - Wire

private enum Lookup {
	static func run(bundleID: String) async -> AppStoreLookup.Item? {
		// The device's own storefront first, so ratings and screenshots are
		// the ones this user would see. US is the fallback: an app is more
		// likely to be listed there than in a small storefront, and a
		// storefront that answers nothing at all costs one extra request.
		if let item = await fetch(bundleID: bundleID, country: storefront()) {
			return item
		}
		return await fetch(bundleID: bundleID, country: "us")
	}

	private static func storefront() -> String {
		if let region = Locale.current.region?.identifier, !region.isEmpty {
			return region.lowercased()
		}
		return "us"
	}

	private static func fetch(bundleID: String, country: String) async -> AppStoreLookup.Item? {
		var components = URLComponents(string: "https://itunes.apple.com/lookup")
		components?.queryItems = [
			URLQueryItem(name: "bundleId", value: bundleID),
			URLQueryItem(name: "country", value: country),
			URLQueryItem(name: "entity", value: "software"),
			URLQueryItem(name: "limit", value: "1")
		]
		guard let url = components?.url else { return nil }

		var request = URLRequest(url: url)
		request.timeoutInterval = 10
		request.setValue("application/json", forHTTPHeaderField: "Accept")

		guard
			let (data, response) = try? await URLSession.shared.data(for: request),
			let http = response as? HTTPURLResponse,
			http.statusCode == 200,
			let decoded = try? JSONDecoder().decode(Response.self, from: data),
			let entry = decoded.results.first
		else {
			return nil
		}

		return AppStoreLookup.Item(
			screenshots: entry.shots,
			rating: entry.averageUserRating,
			ratingCount: entry.userRatingCount,
			age: entry.contentAdvisoryRating?.nilWhenEmpty,
			summary: entry.description?.nilWhenEmpty,
			developer: entry.sellerName?.nilWhenEmpty,
			category: entry.primaryGenreName?.nilWhenEmpty,
			version: entry.version?.nilWhenEmpty,
			bytes: entry.fileSizeBytes.flatMap { Int64($0) },
			released: entry.releaseDate.flatMap { Wire.date($0) }
		)
	}

	/// The lookup's own shape. Every field is optional: the endpoint is not a
	/// contract we control, and a field that goes missing must not take the
	/// page's whole lookup down with it.
	private struct Response: Decodable {
		let results: [Entry]
	}

	private struct Entry: Decodable {
		let screenshotUrls: [String]?
		let ipadScreenshotUrls: [String]?
		let averageUserRating: Double?
		let userRatingCount: Int?
		let contentAdvisoryRating: String?
		let description: String?
		let sellerName: String?
		let primaryGenreName: String?
		let version: String?
		let fileSizeBytes: String?
		let releaseDate: String?

		/// iPad shots are the fallback, never the first choice: the page is
		/// read on a phone far more often than not.
		var shots: [ASRepository.App.Screenshots.Shot] {
			if let phone = screenshotUrls, !phone.isEmpty { return phone.compactMap(Wire.shot) }
			if let pad = ipadScreenshotUrls, !pad.isEmpty { return pad.compactMap(Wire.shot) }
			return []
		}
	}
}

// MARK: - Decoding helpers

private enum Wire {
	/// How wide a render to ask the store for. The store never upsizes, so this
	/// is a ceiling and not a promise — every shot comes back at the asset's own
	/// size, which is the sharpest it can be drawn at.
	///
	/// 1200 and not 1600: the tallest card the page draws is a 560-pt portrait
	/// shot, which needs 777 px across at 3× to be pixel-exact, and the widest is
	/// a full-width landscape shot at about 1060 px. Everything above that is
	/// bytes the page pays for and never shows.
	private static let renderWidth = 1200

	/// A shot from the store, at the full size it will be drawn at.
	///
	/// The store's URL is a *request*, not a description. `…/320x480bb.jpg`
	/// asks for a 320-wide render, and the store answers with the image's own
	/// shape: a landscape game shot comes back 320×148, a portrait one 320×480.
	/// So the token in the path says nothing about the shot — and taken as a
	/// thumbnail it is a 148-pixel-tall picture drawn across a phone screen.
	///
	/// The shape is therefore left unset rather than invented. The page resolves
	/// it from the image itself, once, which is the only place the truth is.
	static func shot(_ raw: String) -> ASRepository.App.Screenshots.Shot? {
		guard let url = URL(string: raw) else { return nil }
		return ASRepository.App.Screenshots.Shot(url: render(url, width: renderWidth))
	}

	/// The same shot, asked for at full width.
	///
	/// `…/1290x2796bb.png` becomes `…/1600x0w.png`: "0w" asks the store to keep
	/// the image's own proportions, which is exactly what a shot should have.
	/// A URL without a render token is left alone.
	private static func fullSize(_ url: URL) -> URL {
		render(url, width: renderWidth)
	}

	/// The URL rewritten to a different render width. `0w` asks the store to
	/// keep the image's own proportions, so every width of the same shot has
	/// the same shape — which is why a thumbnail can measure a shot the page
	/// will draw at full size.
	static func render(_ url: URL, width: Int) -> URL {
		let name = url.lastPathComponent
		let parts = name.split(separator: "x", maxSplits: 1)
		guard parts.count == 2, Int(parts[0]) != nil else { return url }

		let ext = (name as NSString).pathExtension
		let render = "\(width)x0w.\(ext.isEmpty ? "jpg" : ext)"

		// `deletingLastPathComponent` keeps the trailing slash, and the store
		// answers a `//` in the path with a 400 rather than a redirect.
		var base = url.deletingLastPathComponent().absoluteString
		while base.hasSuffix("/") { base.removeLast() }
		return URL(string: base + "/" + render) ?? url
	}

	/// The store's dates are ISO-8601 without fractional seconds.
	static func date(_ raw: String) -> Date? {
		let formatter = ISO8601DateFormatter()
		return formatter.date(from: raw)
	}
}

private extension String {
	var nilWhenEmpty: String? {
		let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}
}
