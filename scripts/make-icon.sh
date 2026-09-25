#!/usr/bin/env bash
#
# Draw the BatSign app icon from the bat the app itself draws.
#
# The mark is not redrawn here. Its geometry is cut out of
# `DownloadActivityAttributes.swift` between two markers and compiled into this
# script, so the icon and the thing on the Dynamic Island can never drift into
# two different bats — which is exactly what happened once: the icon kept an
# older, ragged bat for weeks after the shape in the app had been fixed.
#
# Outputs, all 1024 × 1024:
#
#   Assets.xcassets/AppIcon.appiconset/feather.png        light
#   Assets.xcassets/AppIcon.appiconset/feather_dark.png   dark
#   Assets.xcassets/AppIcon.appiconset/feather_tint.png   tinted (greyscale)
#   AppIcon.icon/Assets/feather.png                       the mark layer alone,
#                                                         for Icon Composer
#   feather_extension.png                                 the document icon
#                                                         (512, the type the
#                                                         Files app shows for
#                                                         a signed .ipa)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Feather/Backend/LiveActivity/DownloadActivityAttributes.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- the geometry, cut out of the app's own source -------------------------

awk '/BENCH-MARK-GEOMETRY-BEGIN/{flag=1;next}/BENCH-MARK-GEOMETRY-END/{flag=0}flag' \
  "$SOURCE" > "$WORK/BatGeometry.swift"

if ! grep -q "struct BatMark" "$WORK/BatGeometry.swift" \
   || ! grep -q "struct BatHalf" "$WORK/BatGeometry.swift"; then
  echo "!! could not find the mark's geometry in $SOURCE" >&2
  echo "   the BENCH-MARK-GEOMETRY markers have been moved" >&2
  exit 1
fi

# ---- the renderer ----------------------------------------------------------

cat > "$WORK/Prelude.swift" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

/// One appearance of the icon: its ground and how the mark sits on it.
struct Appearance {
	let name: String
	let top: (r: Double, g: Double, b: Double)
	let bottom: (r: Double, g: Double, b: Double)
	/// How strong the lift at the top of the field is. A flat field reads as a
	/// placeholder; a little light above the mark is what makes it sit *on*
	/// something.
	let highlight: Double
	/// Whether to draw the ground at all. The Icon Composer bundle supplies its
	/// own fill, so its layer must be the mark alone.
	let drawsGround: Bool
	let mark: (r: Double, g: Double, b: Double)
	/// Side of the square to draw, in pixels. Everything else scales off the
	/// shape's own bounding box, so a different size is one number, not a second
	/// set of coordinates.
	var size: Double = 1024
}

/// Where the mark's visible box goes. Centred horizontally, and a little above
/// the middle vertically: the mark's mass is in the wings and the body hangs
/// below, so geometric centring leaves it looking low.
let MARK_WIDTH_RATIO = 0.70
let MARK_CENTRE_Y_RATIO = 0.478
SWIFT

cat > "$WORK/Main.swift" <<'SWIFT'

// MARK: - Drawing

func colour(_ c: (r: Double, g: Double, b: Double), _ a: Double = 1) -> CGColor {
	CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: a)
}

func render(_ appearance: Appearance) -> CGImage? {
	let TILE = appearance.size

	guard let space = CGColorSpace(name: CGColorSpace.sRGB),
	      let context = CGContext(
			data: nil,
			width: Int(TILE), height: Int(TILE),
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: space,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
	      )
	else { return nil }

	// Draw with y running downward, the same way the shape was authored, so the
	// path and the shadows do not have to be reasoned about upside down.
	context.translateBy(x: 0, y: CGFloat(TILE))
	context.scaleBy(x: 1, y: -1)
	context.setAllowsAntialiasing(true)
	context.interpolationQuality = .high

	if appearance.drawsGround {
		// The field.
		if let gradient = CGGradient(
			colorsSpace: space,
			colors: [colour(appearance.top), colour(appearance.bottom)] as CFArray,
			locations: [0, 1]
		) {
			context.drawLinearGradient(
				gradient,
				start: CGPoint(x: 0, y: 0),
				end: CGPoint(x: 0, y: TILE),
				options: []
			)
		}

		// The lift.
		if appearance.highlight > 0,
		   let glow = CGGradient(
			colorsSpace: space,
			colors: [
				CGColor(srgbRed: 1, green: 1, blue: 1, alpha: appearance.highlight),
				CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
			] as CFArray,
			locations: [0, 1]
		) {
			context.drawRadialGradient(
				glow,
				startCenter: CGPoint(x: TILE / 2, y: TILE * 0.13),
				startRadius: 0,
				endCenter: CGPoint(x: TILE / 2, y: TILE * 0.13),
				endRadius: TILE * 0.72,
				options: []
			)
		}
	}

	// Where the mark goes, derived from the shape's own bounding box rather than
	// guessed: the box is what the eye actually sees, and the authored frame
	// around it is not.
	let design = BatMark().path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).boundingRect
	let side = MARK_WIDTH_RATIO * TILE * 100 / design.width
	let originX = TILE / 2 - (design.minX + design.width / 2) * side / 100
	let originY = MARK_CENTRE_Y_RATIO * TILE - (design.minY + design.height / 2) * side / 100
	let frame = CGRect(x: originX, y: originY, width: side, height: side)

	let mark = BatMark().path(in: frame).cgPath

	// The shadow. A mark floating on a gradient with no shadow looks pasted on;
	// one with too much looks like a sticker. This is the range between.
	context.saveGState()
	context.setShadow(
		offset: CGSize(width: 0, height: TILE * 0.017),
		blur: CGFloat(TILE * 0.030),
		color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.32)
	)
	context.addPath(mark)
	context.setFillColor(colour(appearance.mark))
	context.fillPath()
	context.restoreGState()

	// A hair of a second pass, unshadowed, so the edges stay crisp rather than
	// picking up the blur.
	context.addPath(mark)
	context.setFillColor(colour(appearance.mark))
	context.fillPath()

	print("  mark box \(Int(design.minX)),\(Int(design.minY)) \(Int(design.width))x\(Int(design.height)) in \(Int(side))pt frame")
	return context.makeImage()
}

func write(_ image: CGImage, to path: String) throws {
	let url = URL(fileURLWithPath: path)
	guard let destination = CGImageDestinationCreateWithURL(
		url as CFURL, UTType.png.identifier as CFString, 1, nil
	) else {
		throw NSError(domain: "make-icon", code: 1)
	}
	CGImageDestinationAddImage(destination, image, nil)
	guard CGImageDestinationFinalize(destination) else {
		throw NSError(domain: "make-icon", code: 2)
	}
}

// MARK: - The set

let resources = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Feather/Resources"

let appearances: [Appearance] = [
	Appearance(
		name: "light",
		top: (0.055, 0.520, 1.000),
		bottom: (0.000, 0.200, 0.700),
		highlight: 0.22,
		drawsGround: true,
		mark: (1, 1, 1)
	),
	Appearance(
		name: "dark",
		// Dark icons are a deeper field, not a dimmed one: the mark stays white
		// and the ground goes down to meet the black of the Home Screen.
		top: (0.043, 0.170, 0.440),
		bottom: (0.008, 0.031, 0.110),
		highlight: 0.14,
		drawsGround: true,
		mark: (1, 1, 1)
	),
	Appearance(
		name: "tint",
		// Tinted icons are a greyscale mask the system paints the user's tint
		// through, so this one is luminance only: a mid grey field with the mark
		// as its lightest element.
		top: (0.66, 0.66, 0.66),
		bottom: (0.34, 0.34, 0.34),
		highlight: 0.16,
		drawsGround: true,
		mark: (1, 1, 1)
	),
	Appearance(
		name: "icon-layer",
		top: (0, 0, 0),
		bottom: (0, 0, 0),
		highlight: 0,
		drawsGround: false,
		mark: (1, 1, 1)
	),
	Appearance(
		name: "extension",
		// The document icon the Files app and the share sheet show for a signed
		// .ipa. Same field and same mark as the light icon — it is the same app,
		// one size down — and drawn at 512, which is what the type declares.
		top: (0.055, 0.520, 1.000),
		bottom: (0.000, 0.200, 0.700),
		highlight: 0.22,
		drawsGround: true,
		mark: (1, 1, 1),
		size: 512
	),
]

for appearance in appearances {
	print("drawing \(appearance.name)")
	guard let image = render(appearance) else {
		FileHandle.standardError.write(Data("!! could not render \(appearance.name)\n".utf8))
		exit(1)
	}

	if appearance.name == "icon-layer" {
		try write(image, to: "\(resources)/AppIcon.icon/Assets/feather.png")
	} else if appearance.name == "extension" {
		try write(image, to: "\(resources)/feather_extension.png")
	} else {
		try write(image, to: "\(resources)/Assets.xcassets/AppIcon.appiconset/feather\(appearance.name == "light" ? "" : "_\(appearance.name)").png")
	}
}

print("done")
SWIFT

cat "$WORK/Prelude.swift" "$WORK/BatGeometry.swift" "$WORK/Main.swift" > "$WORK/make-icon.swift"

echo "==> compiling"
swiftc -O -o "$WORK/make-icon" "$WORK/make-icon.swift"

echo "==> drawing"
cd "$ROOT"
"$WORK/make-icon" "$ROOT/Feather/Resources"

echo "==> wrote"
ls -la Feather/Resources/Assets.xcassets/AppIcon.appiconset/*.png Feather/Resources/AppIcon.icon/Assets/*.png Feather/Resources/feather_extension.png
