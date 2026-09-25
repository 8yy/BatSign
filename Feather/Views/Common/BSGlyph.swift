//
//  BSGlyph.swift
//  Feather
//
//  BatSign's own icon set.
//
//  Every icon in this app is drawn here, in code, in one 100 × 100 box, and
//  stroked with one weight. That is the whole point of the file: a settings
//  screen assembled from a system symbol library borrows someone else's
//  drawings, and they never quite line up — some are outlined, some solid, some
//  heavy, some thin, and two of them mean three different things. One family,
//  drawn to one grid at one weight, reads as one product.
//
//  Two conventions make the set cohere:
//
//  * Anything that wants to be a solid dot is a *tiny stroked circle*. With a
//    weight of nine in a hundred-box, a radius-six ring closes up and reads as
//    a dot, which means there is exactly one drawing style in the whole set.
//
//  * Filled glyphs are the exceptions, and there are four of them — the moon,
//    the folder, the puzzle piece and the bat — because those shapes are
//    silhouettes or nothing.
//

import SwiftUI

// MARK: - The set

enum BSGlyph: String, CaseIterable {
	case gear
	case launch
	case refresh
	case clock
	case wifi
	case moon
	case quill
	case shield
	case pulse
	case swap
	case bell
	case badge
	case seal
	case drive
	case activity
	case health
	case transfer
	case sliders
	case archive
	case install
	case puzzle
	case brush
	case face
	case folder
	case bin
	case bat
	case plus
	case link
	case share
	case more

	/// The glyphs that are a silhouette rather than a line drawing.
	var isFilled: Bool {
		switch self {
		case .moon, .puzzle, .folder, .bat: return true
		default: return false
		}
	}

	/// The drawing, in the 100 × 100 box.
	///
	/// Authored clockwise from the top wherever the shape has an obvious start,
	/// so the file reads in the order the pen moves.
	var path: Path {
		var p = Path()

		/// A ring that closes into a dot at this weight.
		func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat = 6) {
			p.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
		}
		func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
			p.move(to: CGPoint(x: x1, y: y1))
			p.addLine(to: CGPoint(x: x2, y: y2))
		}
		func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from: Double, to: Double, clockwise: Bool = false) {
			p.addArc(
				center: CGPoint(x: cx, y: cy),
				radius: r,
				startAngle: .degrees(from),
				endAngle: .degrees(to),
				clockwise: clockwise
			)
		}

		switch self {
		case .gear:
			// A cog: eight trapezoidal teeth cut from one polygon, which is both
			// cheaper and steadier than eight rotated rectangles.
			let teeth = 8
			for index in 0..<(teeth * 2) {
				let radius: CGFloat = index % 2 == 0 ? 47 : 33
				let angle = Double(index) / Double(teeth * 2) * 2 * .pi - .pi / 2
				let point = CGPoint(x: 50 + radius * cos(angle), y: 50 + radius * sin(angle))
				if index == 0 { p.move(to: point) } else { p.addLine(to: point) }
			}
			p.closeSubpath()
			arc(50, 50, 13, from: 0, to: 360)

		case .launch:
			// The launch tab: a page with its own title bar, and the arrow that
			// points into it.
			p.addRoundedRect(
				in: CGRect(x: 16, y: 22, width: 68, height: 56),
				cornerSize: CGSize(width: 12, height: 12)
			)
			line(16, 38, 84, 38)
			line(50, 74, 50, 50)
			line(50, 50, 40, 60)
			line(50, 50, 60, 60)

		case .refresh:
			// An open circle with an arrowhead, set off-centre so it reads as
			// motion rather than as a clock.
			arc(50, 50, 30, from: -40, to: 250)
			line(74, 22, 78, 34)
			line(74, 22, 62, 26)

		case .clock:
			arc(50, 50, 34, from: 0, to: 360)
			line(50, 50, 50, 28)
			line(50, 50, 68, 58)

		case .wifi:
			// Three arcs and a dot, centred low so the arcs stack upward.
			arc(50, 78, 10, from: 225, to: 315)
			arc(50, 78, 26, from: 217, to: 323)
			arc(50, 78, 42, from: 213, to: 327)
			dot(50, 76, 7)

		case .moon:
			// A crescent is one circle cut by another, so it is filled with the
			// even-odd rule rather than drawn as an outline.
			p.addEllipse(in: CGRect(x: 20, y: 18, width: 62, height: 62))
			p.addEllipse(in: CGRect(x: 38, y: 4, width: 62, height: 62))
			// A four-pointed spark, drawn as two thin diamonds.
			p.move(to: CGPoint(x: 82, y: 66))
			p.addLine(to: CGPoint(x: 86, y: 76))
			p.addLine(to: CGPoint(x: 90, y: 66))
			p.addLine(to: CGPoint(x: 86, y: 56))
			p.closeSubpath()

		case .quill:
			// A nib: a long tapered body, the slit down its middle, and the
			// feather's spine behind it.
			p.move(to: CGPoint(x: 30, y: 78))
			p.addQuadCurve(to: CGPoint(x: 62, y: 16), control: CGPoint(x: 34, y: 34))
			p.addQuadCurve(to: CGPoint(x: 74, y: 40), control: CGPoint(x: 78, y: 20))
			p.addQuadCurve(to: CGPoint(x: 30, y: 78), control: CGPoint(x: 40, y: 56))
			p.closeSubpath()
			line(48, 50, 62, 64)
			line(30, 78, 18, 88)

		case .shield:
			p.move(to: CGPoint(x: 50, y: 14))
			p.addLine(to: CGPoint(x: 82, y: 27))
			p.addLine(to: CGPoint(x: 82, y: 52))
			p.addQuadCurve(to: CGPoint(x: 50, y: 88), control: CGPoint(x: 82, y: 76))
			p.addQuadCurve(to: CGPoint(x: 18, y: 52), control: CGPoint(x: 18, y: 76))
			p.addLine(to: CGPoint(x: 18, y: 27))
			p.closeSubpath()
			line(37, 50, 47, 62)
			line(47, 62, 66, 39)

		case .pulse:
			// A heartbeat inside a ring: the line is what makes it a pulse and
			// not a gauge.
			arc(50, 50, 34, from: 0, to: 360)
			p.move(to: CGPoint(x: 20, y: 50))
			p.addLine(to: CGPoint(x: 36, y: 50))
			p.addLine(to: CGPoint(x: 44, y: 32))
			p.addLine(to: CGPoint(x: 54, y: 68))
			p.addLine(to: CGPoint(x: 62, y: 50))
			p.addLine(to: CGPoint(x: 80, y: 50))

		case .swap:
			// Two panes, and the arrow that trades one for the other. The panes
			// are kept apart far enough to leave the arrow its own space — when
			// they overlap, the arrow lands on top of a corner and disappears.
			p.addRoundedRect(in: CGRect(x: 12, y: 12, width: 40, height: 40), cornerSize: CGSize(width: 9, height: 9))
			p.addRoundedRect(in: CGRect(x: 48, y: 48, width: 40, height: 40), cornerSize: CGSize(width: 9, height: 9))
			line(58, 34, 42, 50)
			line(58, 34, 58, 44)
			line(58, 34, 48, 34)

		case .bell:
			p.move(to: CGPoint(x: 24, y: 72))
			p.addQuadCurve(to: CGPoint(x: 32, y: 52), control: CGPoint(x: 30, y: 72))
			p.addLine(to: CGPoint(x: 32, y: 44))
			p.addQuadCurve(to: CGPoint(x: 68, y: 44), control: CGPoint(x: 50, y: 20))
			p.addLine(to: CGPoint(x: 68, y: 52))
			p.addQuadCurve(to: CGPoint(x: 76, y: 72), control: CGPoint(x: 70, y: 72))
			p.closeSubpath()
			arc(50, 79, 10, from: 200, to: 340)

		case .badge:
			p.addRoundedRect(in: CGRect(x: 16, y: 20, width: 58, height: 58), cornerSize: CGSize(width: 14, height: 14))
			dot(45, 49, 8)
			arc(71, 27, 14, from: 0, to: 360)

		case .seal:
			// A certificate: a seal with two ribbons under it.
			arc(50, 38, 24, from: 0, to: 360)
			line(38, 58, 32, 88)
			line(32, 88, 50, 78)
			line(62, 58, 68, 88)
			line(68, 88, 50, 78)
			line(42, 38, 48, 45)
			line(48, 45, 60, 30)

		case .drive:
			p.addRoundedRect(in: CGRect(x: 14, y: 24, width: 72, height: 52), cornerSize: CGSize(width: 12, height: 12))
			line(14, 58, 86, 58)
			dot(28, 67, 6)

		case .activity:
			// A history: bars of different heights, oldest shortest.
			line(28, 78, 28, 54)
			line(46, 78, 46, 40)
			line(64, 78, 64, 62)
			line(82, 78, 82, 30)
			line(16, 88, 90, 88)

		case .health:
			p.addRoundedRect(in: CGRect(x: 14, y: 14, width: 72, height: 72), cornerSize: CGSize(width: 18, height: 18))
			line(50, 32, 50, 68)
			line(32, 50, 68, 50)

		case .transfer:
			p.addRoundedRect(in: CGRect(x: 14, y: 20, width: 72, height: 60), cornerSize: CGSize(width: 14, height: 14))
			line(38, 66, 38, 38)
			line(38, 38, 30, 48)
			line(38, 38, 46, 48)
			line(62, 34, 62, 62)
			line(62, 62, 54, 52)
			line(62, 62, 70, 52)

		case .sliders:
			line(16, 28, 84, 28)
			line(16, 50, 84, 50)
			line(16, 72, 84, 72)
			dot(38, 28, 10)
			dot(66, 50, 10)
			dot(30, 72, 10)

		case .archive:
			p.addRoundedRect(in: CGRect(x: 16, y: 18, width: 68, height: 24), cornerSize: CGSize(width: 7, height: 7))
			p.addRoundedRect(in: CGRect(x: 22, y: 42, width: 56, height: 42), cornerSize: CGSize(width: 8, height: 8))
			line(50, 52, 50, 74)
			line(42, 63, 58, 63)

		case .install:
			// Down into a tray: the arrow lands, the shelf catches it.
			line(50, 16, 50, 58)
			line(50, 58, 34, 42)
			line(50, 58, 66, 42)
			p.move(to: CGPoint(x: 18, y: 66))
			p.addLine(to: CGPoint(x: 18, y: 80))
			p.addQuadCurve(to: CGPoint(x: 30, y: 90), control: CGPoint(x: 18, y: 90))
			p.addLine(to: CGPoint(x: 70, y: 90))
			p.addQuadCurve(to: CGPoint(x: 82, y: 80), control: CGPoint(x: 82, y: 90))
			p.addLine(to: CGPoint(x: 82, y: 66))

		case .puzzle:
			// A piece: a body with a knob out of one side and a socket in the
			// middle, filled even-odd so the socket is a hole.
			p.addRoundedRect(in: CGRect(x: 20, y: 24, width: 56, height: 56), cornerSize: CGSize(width: 10, height: 10))
			p.addEllipse(in: CGRect(x: 62, y: 42, width: 26, height: 26))
			p.addEllipse(in: CGRect(x: 30, y: 6, width: 26, height: 26))
			p.addEllipse(in: CGRect(x: 38, y: 42, width: 20, height: 20))

		case .brush:
			// A brush at rest: handle, ferrule, bristles.
			p.addRoundedRect(in: CGRect(x: 58, y: 12, width: 20, height: 46), cornerSize: CGSize(width: 9, height: 9))
			p.move(to: CGPoint(x: 56, y: 60))
			p.addLine(to: CGPoint(x: 80, y: 60))
			p.addLine(to: CGPoint(x: 74, y: 82))
			p.addQuadCurve(to: CGPoint(x: 62, y: 82), control: CGPoint(x: 68, y: 90))
			p.closeSubpath()
			line(68, 20, 68, 50)

		case .face:
			// A scan frame around a face: the frame is what makes it "lock"
			// rather than "profile".
			p.move(to: CGPoint(x: 14, y: 34))
			p.addLine(to: CGPoint(x: 14, y: 20))
			p.addQuadCurve(to: CGPoint(x: 28, y: 14), control: CGPoint(x: 14, y: 14))
			p.addLine(to: CGPoint(x: 34, y: 14))
			p.move(to: CGPoint(x: 66, y: 14))
			p.addLine(to: CGPoint(x: 72, y: 14))
			p.addQuadCurve(to: CGPoint(x: 86, y: 20), control: CGPoint(x: 86, y: 14))
			p.addLine(to: CGPoint(x: 86, y: 34))
			p.move(to: CGPoint(x: 86, y: 66))
			p.addLine(to: CGPoint(x: 86, y: 80))
			p.addQuadCurve(to: CGPoint(x: 72, y: 86), control: CGPoint(x: 86, y: 86))
			p.addLine(to: CGPoint(x: 66, y: 86))
			p.move(to: CGPoint(x: 34, y: 86))
			p.addLine(to: CGPoint(x: 28, y: 86))
			p.addQuadCurve(to: CGPoint(x: 14, y: 80), control: CGPoint(x: 14, y: 86))
			p.addLine(to: CGPoint(x: 14, y: 66))
			dot(38, 46, 6)
			dot(62, 46, 6)
			arc(50, 58, 14, from: 30, to: 150)

		case .folder:
			p.move(to: CGPoint(x: 10, y: 76))
			p.addLine(to: CGPoint(x: 10, y: 30))
			p.addQuadCurve(to: CGPoint(x: 22, y: 20), control: CGPoint(x: 10, y: 20))
			p.addLine(to: CGPoint(x: 38, y: 20))
			p.addLine(to: CGPoint(x: 46, y: 32))
			p.addLine(to: CGPoint(x: 84, y: 32))
			p.addQuadCurve(to: CGPoint(x: 90, y: 40), control: CGPoint(x: 90, y: 32))
			p.addLine(to: CGPoint(x: 90, y: 76))
			p.addQuadCurve(to: CGPoint(x: 82, y: 84), control: CGPoint(x: 90, y: 84))
			p.addLine(to: CGPoint(x: 18, y: 84))
			p.addQuadCurve(to: CGPoint(x: 10, y: 76), control: CGPoint(x: 10, y: 84))
			p.closeSubpath()

		case .bin:
			line(18, 30, 82, 30)
			p.move(to: CGPoint(x: 38, y: 30))
			p.addQuadCurve(to: CGPoint(x: 62, y: 30), control: CGPoint(x: 50, y: 10))
			p.move(to: CGPoint(x: 28, y: 30))
			p.addLine(to: CGPoint(x: 34, y: 84))
			p.addQuadCurve(to: CGPoint(x: 42, y: 90), control: CGPoint(x: 34, y: 90))
			p.addLine(to: CGPoint(x: 58, y: 90))
			p.addQuadCurve(to: CGPoint(x: 66, y: 84), control: CGPoint(x: 66, y: 90))
			p.addLine(to: CGPoint(x: 72, y: 30))
			line(42, 46, 44, 76)
			line(58, 46, 56, 76)

		case .bat:
			return BatMark().path(in: CGRect(x: 0, y: 0, width: 100, height: 100))

		case .plus:
			line(50, 20, 50, 80)
			line(20, 50, 80, 50)

		case .link:
			// A chain link: two capsules on one diagonal, one through the
			// other. Drawn at the family's own angle — the same 45° the share
			// arrow and the swap panes use — so a link and a share read as one
			// hand rather than as two borrowed icons. The two are offset along
			// the diagonal far enough that the overlap is a link and not a blob.
			//
			// Authoring them upright and letting the transform set them down is
			// deliberate: a rounded rectangle has to be built axis-aligned, and
			// a link drawn as eight lines and two arcs would be the same shape
			// spelled out in a way nothing can read.
			func capsule(_ centre: CGPoint) -> Path {
				var part = Path()
				part.addRoundedRect(
					in: CGRect(x: -25, y: -13, width: 50, height: 26),
					cornerSize: CGSize(width: 13, height: 13)
				)
				let transform = CGAffineTransform(rotationAngle: -CGFloat.pi / 4)
					.concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
				return part.applying(transform)
			}
			p.addPath(capsule(CGPoint(x: 38, y: 62)))
			p.addPath(capsule(CGPoint(x: 62, y: 38)))

		case .share:
			// The tray and the arrow leaving it, drawn as our own rather than
			// borrowed — this is the one control that appears on every app page.
			line(84, 56, 84, 84)
			line(16, 56, 16, 84)
			line(16, 84, 84, 84)
			line(50, 66, 50, 18)
			line(50, 18, 32, 38)
			line(50, 18, 68, 38)

		case .more:
			// Three dots: one ring each, which at this weight read as solids.
			dot(26, 50, 7)
			dot(50, 50, 7)
			dot(74, 50, 7)
		}

		return p
	}
}

// MARK: - Drawing it

/// One glyph, fitted to whatever it is given, stroked at the family's weight.
struct BSGlyphView: View {
	let kind: BSGlyph
	var size: CGFloat

	var body: some View {
		let shape = BSGlyphShape(kind: kind)

		// The stroke is part of the drawing, so its width is a fraction of the
		// box rather than a fixed number of points — that is what keeps a 28-pt
		// tile glyph and a 15-pt inline glyph the same drawing at two sizes.
		let width = max(size * 0.085, 1)

		Group {
			if kind.isFilled {
				shape.fill(style: FillStyle(eoFill: true))
			} else {
				shape.stroke(style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
			}
		}
		.frame(width: size, height: size)
	}
}

/// The 100 × 100 drawing, mapped onto a rectangle.
struct BSGlyphShape: Shape {
	let kind: BSGlyph

	func path(in rect: CGRect) -> Path {
		let scale = min(rect.width, rect.height) / 100
		let transform = CGAffineTransform(
			translationX: rect.midX - 50 * scale,
			y: rect.midY - 50 * scale
		)
		.scaledBy(x: scale, y: scale)

		var mapped = Path()
		mapped.addPath(kind.path, transform: transform)
		return mapped
	}
}

// MARK: - The tile

/// A settings icon tile: a gradient square with the glyph cut out of it in
/// white, the way the system's own settings rows are built — and with our own
/// glyph inside instead of a borrowed one.
struct BSIconTile: View {
	let glyph: BSGlyph
	var tint: Color = BS.accent
	var size: CGFloat = 29

	private var top: Color { tint }
	private var bottom: Color {
		// A touch darker at the foot of the tile, so the square has a light
		// direction and a grid of them does not read as flat stickers.
		tint.opacity(0.82)
	}

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
				.fill(
					LinearGradient(
						colors: [top, bottom],
						startPoint: .top,
						endPoint: .bottom
					)
				)

			BSGlyphView(kind: glyph, size: size * 0.62)
				.foregroundStyle(.white)
		}
		.frame(width: size, height: size)
	}
}
