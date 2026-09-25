//
//  BSArtwork.swift
//  Feather
//
//  What the storefront needs to know about a piece of remote artwork *before*
//  it decides how to draw it: how wide it really is, and which colour it leads
//  with.
//
//  Both answers exist because of one AltStore quirk: a source's `headerURL`
//  slot is meant for a wide banner, but most sources republish the square app
//  icon in it. Stretching that across a 330-pt story card is what turns the
//  Today feed into a wall of blown-up app icons. So the card measures the
//  image instead of trusting the slot, and falls back to the App Store's
//  blurred-artwork ground when the artwork is not genuinely wide.
//

import SwiftUI
import UIKit

actor BSArtwork {
	static let shared = BSArtwork()

	private var sizes: [URL: CGSize] = [:]
	private var tints: [URL: Color] = [:]
	private var inflight: [URL: Task<UIImage?, Never>] = [:]

	/// Anything at least this much wider than it is tall reads as a banner.
	/// 1.35 is the point where a 330-pt card is no longer padded with blur on
	/// both sides; below it the blurred ground is the better-looking choice.
	private static let bannerAspect: CGFloat = 1.35

	/// True when the image is genuinely wide. A square icon in the banner slot
	/// answers `false`, which is exactly the point.
	func isWide(_ url: URL) async -> Bool {
		guard let size = await _size(url), size.height > 0 else { return false }
		return size.width / size.height >= Self.bannerAspect
	}

	/// The artwork's leading colour, so a card with no tint of its own still
	/// reads as *that* app instead of defaulting to a blue panel.
	func dominantColor(_ url: URL) async -> Color? {
		if let cached = tints[url] { return cached }
		guard let image = await _image(url), let color = Self.leadingColor(of: image) else {
			return nil
		}
		tints[url] = color
		return color
	}

	// MARK: - Internals

	private func _size(_ url: URL) async -> CGSize? {
		if let cached = sizes[url] { return cached }
		guard let image = await _image(url) else { return nil }
		sizes[url] = image.size
		return image.size
	}

	/// One decode per URL, shared by every card that asks for the same artwork.
	private func _image(_ url: URL) async -> UIImage? {
		if let existing = inflight[url] { return await existing.value }

		let task = Task<UIImage?, Never> {
			var request = URLRequest(url: url)
			request.timeoutInterval = 12
			request.cachePolicy = .returnCacheDataElseLoad
			guard
				let (data, response) = try? await URLSession.shared.data(for: request),
				response is HTTPURLResponse,
				let image = UIImage(data: data),
				image.size.width > 0,
				image.size.height > 0
			else { return nil }
			return image
		}

		inflight[url] = task
		let image = await task.value
		inflight[url] = nil
		if let image { sizes[url] = image.size }
		return image
	}

	/// The artwork reduced to a single pixel, with the extremes pulled in.
	///
	/// A plain average over a whole screenshot lands on mud, and the darkest or
	/// lightest single pixel is a highlight or a shadow rather than the colour
	/// the app is recognised by. Rendering the image down to 1×1 is what the
	/// system does for a colour-matching tint, so the card ends up agreeing
	/// with the rest of the OS.
	private static func leadingColor(of image: UIImage) -> Color? {
		var pixel: [UInt8] = [0, 0, 0, 0]
		guard
			let space = CGColorSpace(name: CGColorSpace.sRGB),
			let context = CGContext(
				data: &pixel,
				width: 1, height: 1,
				bitsPerComponent: 8,
				bytesPerRow: 4,
				space: space,
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			),
			let cgImage = image.cgImage
		else { return nil }

		context.interpolationQuality = .medium
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

		let red = Double(pixel[0]) / 255
		let green = Double(pixel[1]) / 255
		let blue = Double(pixel[2]) / 255

		// A near-black or near-white average carries no identity — the callers
		// are better off with their own fallback than with a grey card.
		let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
		guard luminance > 0.06, luminance < 0.94 else { return nil }

		return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
	}
}

// MARK: - Deterministic fallback tint

extension Color {
	/// A stable colour for an app that has no artwork tint at all: the same name
	/// always yields the same hue, so a card never changes colour between
	/// launches. Blue is skipped — it is the accent, and a card tinted with the
	/// accent reads as a button rather than as a brand.
	static func bsIdentifierTint(_ seed: String) -> Color {
		var hash: UInt64 = 5381
		for byte in seed.utf8 {
			hash = (hash &* 33) &+ UInt64(byte)
		}
		let hue = Double(hash % 360) / 360
		let adjusted = hue > 0.53 && hue < 0.72 ? hue + 0.25 : hue
		return Color(hue: adjusted.truncatingRemainder(dividingBy: 1),
		             saturation: 0.62,
		             brightness: 0.72)
	}
}
