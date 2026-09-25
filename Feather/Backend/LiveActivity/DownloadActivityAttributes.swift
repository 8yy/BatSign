//
//  DownloadActivityAttributes.swift
//  Feather
//
//  The shape of the live download status, shared by the app that publishes it
//  and the widget extension that draws it in the Dynamic Island and on the Lock
//  Screen. This file is compiled into *both* targets — that is the contract; if
//  the two sides ever disagree about the payload, the activity silently never
//  renders.
//
//  It also carries the mark itself. The bat has to be visible on the island and
//  on the Lock Screen, and a widget extension cannot load the app's own assets,
//  so the shape is drawn here, in code, once, and both targets get the same
//  bat.
//

import Foundation
import ActivityKit
import SwiftUI

struct DownloadActivityAttributes: ActivityAttributes {
	/// Everything that changes while the transfer runs. ActivityKit pushes a new
	/// copy to the extension on every update, so it stays deliberately small.
	struct ContentState: Codable, Hashable {
		enum Phase: String, Codable, Hashable {
			case downloading
			case unpacking
			case signing
			/// Re-signing an app that is already in the Library, because a newer
			/// build of it was published. The same work as `signing` and named
			/// differently on purpose: "Signing" is what a fresh install does,
			/// and the user asked for this one with a tap on "Update".
			case updating
			case installing
			case finished
			case failed

			var title: String {
				switch self {
				case .downloading: 	return "Downloading"
				case .unpacking: 	return "Preparing"
				case .signing: 		return "Signing"
				case .updating: 	return "Updating"
				case .installing: 	return "Installing"
				case .finished: 	return "Installed"
				case .failed: 		return "Failed"
				}
			}

			/// What the compact island's trailing half can afford. The island is
			/// one line tall and a few points wide, so a phase with no number of
			/// its own is abbreviated rather than wrapped or clipped.
		var compact: String {
			switch self {
			// Empty only when the download has a fraction of its own to show.
			// A transfer with nothing to divide by lands here instead of on a
			// percentage, and a bare "DL" is the honest short form of a job that
			// is running and cannot be measured.
			case .downloading: 	return "DL"
			case .unpacking: 	return "PREP"
				case .signing: 		return "SIGN"
				case .updating: 	return "UPDT"
				case .installing: 	return "INST"
				case .finished: 	return "100%"
				case .failed: 		return "!"
				}
			}

			/// Whether the work is still moving, for the island's chrome.
			var isActive: Bool {
				switch self {
				case .finished, .failed: return false
				default: return true
				}
			}
		}

		var phase: Phase
		/// Name of the app being worked on.
		var appName: String
		/// 0…1 for everything that has a measurable amount of work.
		var progress: Double
		/// Whatever is worth saying underneath: "12.4 MB of 48.1 MB", "3 more
		/// waiting", "Not enough storage".
		var detail: String
		/// How many other transfers are queued behind this one.
		var queued: Int

		/// How this job is being packaged, named the way the setting names it —
		/// "Turbo", "Balanced", "Speed", "None" — plus the install route when
		/// that is what is running. It is what makes the card adaptive: a Turbo
		/// job packages for a long time and installs quickly, a Speed job the
		/// other way round, and the island says which one it is rather than
		/// showing the same three words for every mode.
		///
		/// Optional on purpose: a card left over from an older build of the app
		/// decodes without it instead of failing to render at all.
		var mode: String?

		/// Where the light is, 0…1 round the card, advanced by the app a little on
		/// every state it hands over.
		///
		/// The highlight that circles the island is carried by this number, and the
		/// number moves when the app has news: a byte count that changed, a phase
		/// that changed, or the beat that keeps a silent phase from going stale.
		/// The views glide to wherever it says — quickly while fractions are
		/// arriving, slowly across the beat while they are not.
		///
		/// The two alternatives were both measured on a running simulator and both
		/// are wrong. Pushing a fresh phase several times a second to keep the
		/// light moving makes the card blink, because the system re-renders and
		/// cross-fades a live activity on every update; letting the view animate
		/// itself with a `repeatForever` animation ends the activity outright —
		/// the card was gone three seconds into the silent signing phase.
		///
		/// So the light is honest: it travels while there is news to travel with
		/// (during a transfer, a byte count changing once a second) and it drifts
		/// on the beat while the job is silent, at one quarter turn per push. An
		/// old card with no wave at all renders a still rim rather than failing to
		/// draw.
		var wave: Double?

		/// Whether `progress` is a real fraction of a known amount of work.
		///
		/// False is a transfer with nothing to divide by: a chunked response, a
		/// server that sent no length and a repository that declared no size. The
		/// card then says the work is not measurable instead of printing "0%",
		/// which is what a fraction of zero looks like — and which is what the
		/// island used to sit on from the first byte of such a download to the
		/// last, while the file was demonstrably arriving.
		///
		/// Optional on purpose, like `mode`: a card left over from an older build
		/// decodes without it and is taken at face value.
		var progressKnown: Bool?
	}

	/// Stable identity for the activity: one per download, keyed by the store app
	/// id so a re-download reuses the same activity instead of stacking a second.
	var appID: String
}

// MARK: - Presentation helpers

extension DownloadActivityAttributes.ContentState {
	/// Whether `progress` is a true fraction of measurable work, or merely a
	/// phase marker sitting at 1 because the work has no fraction to report.
	///
	/// The island draws the first as a bar and the second as an indeterminate
	/// spinner: a bar that cannot move is a bar that lies.
	var hasFraction: Bool {
		if progressKnown == false { return false }
		switch phase {
		case .downloading, .installing, .finished: return true
		case .unpacking, .signing, .updating, .failed: return false
		}
	}

	/// What the island's trailing edge says. A phase with no fraction of its own
	/// names itself rather than claiming a percentage it cannot know.
	var percentText: String {
		guard hasFraction else { return phase.title }

		switch phase {
		case .finished: return "100%"
		case .failed: 	return "!"
		default: 		return "\(Int((progress * 100).rounded()))%"
		}
	}

	/// The same, cut down to what the compact island can hold.
	var compactText: String {
		guard hasFraction, phase == .downloading || phase == .installing else {
			return phase.compact
		}
		return "\(Int((progress * 100).rounded()))%"
	}

	/// Clamped, because a progress value that is briefly out of range would make
	/// the island's bar jump backwards.
	var clampedProgress: Double {
		min(max(progress, 0), 1)
	}

	/// The line under the bar. The mode is appended rather than replacing the
	/// detail: "12 MB of 40 MB · Turbo" tells the whole story of what the phone
	/// is doing and why it is taking the time it is.
	var subtitle: String {
		guard let mode, !mode.isEmpty else { return detail }
		guard !detail.isEmpty else { return mode }
		return "\(detail) · \(mode)"
	}

	/// Where the wave is, for the views that draw it. An old card that never
	/// carried one sits still rather than failing to draw.
	var wavePhase: Double {
		guard let wave, wave.isFinite else { return 0 }
		return wave.truncatingRemainder(dividingBy: 1) < 0
			? wave.truncatingRemainder(dividingBy: 1) + 1
			: wave.truncatingRemainder(dividingBy: 1)
	}
}

// MARK: - The mark
//
// The two types below are the single source of truth for the bat's geometry:
// the app draws them, the widget extension draws them, and `scripts/make-icon.sh`
// cuts them out of this file to draw the app icon. The markers are what the
// script keys on — do not move or reword them without updating it.
// BENCH-MARK-GEOMETRY-BEGIN

/// The BatSign bat: two ears, two swept wings and a body that comes to a point.
///
/// Only one half is authored — the right — and the left is that half mirrored
/// about the centre line, so the two sides cannot drift apart the way two
/// hand-drawn halves do. The whole thing scales from the island's 15-pt glyph to
/// the app icon without a bitmap anywhere.
///
/// The geometry is traced, not invented. The outline is read off the reference
/// artwork, mirrored onto an exact centre line, simplified and re-fitted as
/// Béziers with the corners left sharp; the fit sits within 1.2 px of the
/// drawing it came from, a quarter of one per cent of the bat's width and below
/// what a 1024-px icon can resolve. Cutting the same shape by hand — which is
/// what the earlier versions did — kept producing a stepped head, because the
/// eye cannot place a Bézier control point and a raster can.
///
/// Every landmark is still load-bearing:
///
///  * The ears are short uprights a third of the way out from the centre, with
///    a shallow dip between them. Wider or taller ears turn the head into a
///    crown, or into three spikes.
///
///  * The shoulder is a soft corner where the leading edge leaves the body and
///    runs almost straight out and down to the tip, which is the outer extreme
///    at mid-height.
///
///  * The underside returns in a shallow scallop, turns at the membrane's
///    trailing point and folds into the hip before the flank drops to the tail.
///    That fold — rather than a row of finger points — is what a membrane looks
///    like, and it is still legible at 17 pt where scallops turn into noise.
///
/// Everything here is in a 100 × 100 box. The mark is 100 wide by 50.4 tall, on
/// y 24.8…75.2, so a square frame centres it and the icon script can size it off
/// its own bounding box.
struct BatMark: Shape {
	func path(in rect: CGRect) -> Path {
		let half = BatHalf().path(in: rect)

		// Mirror about the vertical centre, written out rather than composed:
		// `x' = -x + 2·midX`. The chainable builders flip the transform they are
		// called on, and which end of the chain wins is exactly the kind of thing
		// that is not worth being clever about in a shape.
		var mirror = CGAffineTransform.identity
		mirror.a = -1
		mirror.tx = 2 * rect.midX

		var path = Path()
		path.addPath(half)
		path.addPath(half, transform: mirror)
		return path
	}
}

/// The right half of the mark, closed along the centre line.
private struct BatHalf: Shape {
	func path(in rect: CGRect) -> Path {
		var path = Path()

		// Authored in a 100 × 100 box, then fitted to whatever it is given.
		let scale = min(rect.width, rect.height) / 100
		let originX = rect.midX - 50 * scale
		let originY = rect.midY - 50 * scale

		func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
			CGPoint(x: originX + x * scale, y: originY + y * scale)
		}

		// Traced from the reference silhouette instead of cut by hand: the outline is
		// read off the image, mirrored onto an exact centre line, simplified and
		// re-fitted as Béziers with the ear, the wing tip and the tail left sharp.
		// 100 units of bat width, x from the centre line, y 24.78…75.22.
		path.move(to: point(50.00, 29.31))
		path.addCurve(to: point(51.51, 29.31), control1: point(50.25, 29.31), control2: point(50.75, 29.49))
		path.addCurve(to: point(54.53, 28.23), control1: point(52.26, 29.13), control2: point(53.38, 28.99))
		// The ear tip: a corner, not a curve. It is the same height as the wing's
		// shoulder and only a little above the dip, which is what keeps the head
		// from reading as a crown.
		path.addCurve(to: point(58.41, 24.78), control1: point(55.68, 27.48), control2: point(58.41, 24.78))
		path.addCurve(to: point(60.13, 25.00), control1: point(58.41, 24.78), control2: point(60.13, 25.00))
		path.addCurve(to: point(60.88, 26.19), control1: point(60.13, 25.00), control2: point(60.88, 26.19))
		// Down the outside of the ear and into the valley behind the shoulder.
		path.addCurve(to: point(60.99, 37.28), control1: point(60.88, 26.19), control2: point(60.99, 37.28))
		// Out of the valley and along the leading edge: the wing springs from
		// behind the head rather than stepping away from it.
		path.addCurve(to: point(67.03, 35.34), control1: point(60.99, 37.28), control2: point(65.01, 36.21))
		path.addCurve(to: point(73.06, 32.11), control1: point(69.04, 34.48), control2: point(71.52, 33.05))
		path.addCurve(to: point(76.29, 29.74), control1: point(74.60, 31.18), control2: point(75.54, 30.17))
		// The shoulder, where the leading edge stops climbing and falls away. Both
		// sides of it run close to level, so it is a soft corner and not a step.
		path.addCurve(to: point(77.59, 29.53), control1: point(77.05, 29.31), control2: point(77.59, 29.53))
		// The near-straight run out to the wing tip — the mark's outer extreme, at
		// mid-height, which is what makes the silhouette read as swept rather than
		// as a dome.
		path.addCurve(to: point(99.89, 51.83), control1: point(77.59, 29.53), control2: point(99.89, 51.83))
		path.addCurve(to: point(99.89, 53.13), control1: point(99.89, 51.83), control2: point(99.89, 53.13))
		// Around the tip, which is sharp.
		path.addCurve(to: point(98.71, 54.31), control1: point(99.89, 53.13), control2: point(98.71, 54.31))
		path.addCurve(to: point(95.47, 53.66), control1: point(98.71, 54.31), control2: point(96.77, 53.81))
		path.addCurve(to: point(90.95, 53.45), control1: point(94.18, 53.52), control2: point(92.31, 53.38))
		path.addCurve(to: point(87.28, 54.09), control1: point(89.58, 53.52), control2: point(88.40, 53.81))
		path.addCurve(to: point(84.27, 55.17), control1: point(86.17, 54.38), control2: point(85.52, 54.49))
		// The underside, coming back in a shallow scallop.
		path.addCurve(to: point(79.74, 58.19), control1: point(83.01, 55.85), control2: point(81.18, 56.93))
		// The membrane's trailing point: the fold that still reads as a wing at the
		// 15-pt the island draws, where a row of fingers would turn into noise.
		path.addCurve(to: point(75.65, 62.72), control1: point(78.30, 59.45), control2: point(75.65, 62.72))
		path.addCurve(to: point(71.77, 62.07), control1: point(75.65, 62.72), control2: point(73.10, 62.18))
		path.addCurve(to: point(67.67, 62.07), control1: point(70.44, 61.96), control2: point(69.22, 61.85))
		// The hip, then the flank down to the tail — which the mirrored half meets
		// in a point on the centre line.
		path.addCurve(to: point(62.50, 63.36), control1: point(66.13, 62.28), control2: point(63.86, 62.90))
		path.addCurve(to: point(59.48, 64.87), control1: point(61.14, 63.83), control2: point(60.38, 64.33))
		path.addCurve(to: point(57.11, 66.59), control1: point(58.58, 65.41), control2: point(58.14, 65.61))
		path.addCurve(to: point(53.34, 70.80), control1: point(56.09, 67.58), control2: point(54.26, 69.52))
		path.addCurve(to: point(51.62, 74.25), control1: point(52.42, 72.07), control2: point(52.07, 73.51))
		path.addCurve(to: point(50.65, 75.22), control1: point(51.17, 74.98), control2: point(50.65, 75.22))
		path.addCurve(to: point(50.00, 75.22), control1: point(50.65, 75.22), control2: point(50.11, 75.22))
		path.closeSubpath()												// centre line back up

		return path
	}
}

// BENCH-MARK-GEOMETRY-END

/// The mark in BatSign blue, which is what every live status is stamped with —
/// the island, the Lock Screen and the in-app surfaces alike. The phase is
/// carried by the bar and the keyline around it, never by repainting the mark,
/// so the one image a user learns to read for "BatSign is working" is always the
/// same image.
struct BatBadge: View {
	var size: CGFloat = 17
	var color: Color = Color(red: 0.04, green: 0.52, blue: 1.00)

	var body: some View {
		BatMark()
			.fill(color)
			.frame(width: size, height: size)
	}
}

// MARK: - The light
//
// One idea, five shapes: a light made of blues that travels around the card the
// status is shown in, along the rail under it, through the bar the progress is
// on, and as a soft field behind the words on the Lock Screen. Every one of them
// is driven by the same number out of the content state, so no two of them can
// disagree about where the light is.
//
// The colours are *mixed*, not picked. A ring of blues is sampled at a position
// that moves with the wave, so what travels is not one blue band around a blue
// ring but a hue that gives way to the next — cyan leaning into azure, azure
// into indigo and back — which is the quality the light is for. Anything that
// interpolates has to work in components rather than in `Color`s, because a
// colour written down is a stop and what is wanted here is everything between
// two stops.

/// One colour of the light, in components, so two of them can be mixed.
struct BatHue {
	var r: Double
	var g: Double
	var b: Double

	var color: Color { Color(red: r, green: g, blue: b) }

	func mixed(_ other: BatHue, _ t: Double) -> BatHue {
		let u = min(max(t, 0), 1)
		return BatHue(
			r: r + (other.r - r) * u,
			g: g + (other.g - g) * u,
			b: b + (other.b - b) * u
		)
	}

	/// The colour of a ring of hues at `t`, where the ring wraps: 0 and 1 are the
	/// same place, which is what lets the light be sampled at `t + wave` forever
	/// without a seam.
	static func at(_ ring: [BatHue], _ t: Double) -> BatHue {
		guard !ring.isEmpty else { return BatAura.azure }
		let steps = Double(ring.count)
		let scaled = (t - floor(t)) * steps
		let index = Int(scaled) % ring.count
		let next = (index + 1) % ring.count
		return ring[index].mixed(ring[next], scaled - floor(scaled))
	}
}

/// The blues, and how they move.
enum BatAura {
	static let azure = BatHue(r: 0.04, g: 0.52, b: 1.00)
	static let cyan = BatHue(r: 0.24, g: 0.84, b: 1.00)
	static let indigo = BatHue(r: 0.35, g: 0.42, b: 0.99)
	static let sky = BatHue(r: 0.56, g: 0.78, b: 1.00)
	static let mint = BatHue(r: 0.29, g: 0.87, b: 0.50)
	static let rose = BatHue(r: 1.00, g: 0.36, b: 0.36)

	/// The ring one phase's light is made of.
	///
	/// Every one of these is a blue, and deliberately: the light says *how* the
	/// job is going, and the words and the symbol say *what* it is doing. A green
	/// wave on the transfer and a red one on the failure are the two exceptions,
	/// because those two outcomes are the two a user must be able to read from
	/// across a room.
	static func ring(_ phase: DownloadActivityAttributes.ContentState.Phase) -> [BatHue] {
		switch phase {
		case .downloading:	return [azure, cyan, sky, azure]
		case .unpacking:	return [cyan, sky, azure, cyan]
		case .signing:		return [indigo, azure, cyan, indigo]
		case .updating:		return [sky, azure, indigo, sky]
		case .installing:	return [cyan, sky, azure, cyan]
		case .finished:		return [mint, BatHue(r: 0.55, g: 0.95, b: 0.72), mint]
		case .failed:		return [rose, BatHue(r: 1.00, g: 0.55, b: 0.45), rose]
		}
	}

	/// The one colour the words on the card are allowed to take.
	///
	/// A single colour and not a gradient: this is what a percentage is printed
	/// in, and a figure that shifts hue as it is read is a figure that is harder
	/// to read for no gain. The movement belongs to the light around it.
	static func tint(_ phase: DownloadActivityAttributes.ContentState.Phase) -> Color {
		switch phase {
		case .finished:	return mint.color
		case .failed:	return rose.color
		case .unpacking:	return cyan.color
		case .signing:	return indigo.color
		case .installing:	return sky.color
		case .updating:	return sky.color
		case .downloading:	return azure.color
		}
	}

	/// The light across something long: a bar, a rail, the width of the card.
	static func flow(
		_ phase: DownloadActivityAttributes.ContentState.Phase,
		wave: Double,
		stops count: Int = 6
	) -> LinearGradient {
		let ring = ring(phase)
		let stops = (0...max(count, 1)).map { step -> Gradient.Stop in
			let t = Double(step) / Double(max(count, 1))
			return Gradient.Stop(color: BatHue.at(ring, t + wave).color, location: t)
		}
		return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
	}

	/// The light round an edge: a comet with a head and a tail, both of which
	/// change hue as the head travels.
	static func halo(
		_ phase: DownloadActivityAttributes.ContentState.Phase,
		wave: Double,
		intensity: Double
	) -> AngularGradient {
		let ring = ring(phase)
		let head = BatHue.at(ring, wave)
		let tail = BatHue.at(ring, wave - 0.12)
		let stops: [Gradient.Stop] = [
			.init(color: tail.color.opacity(0), location: 0.00),
			.init(color: tail.color.opacity(intensity * 0.28), location: 0.05),
			.init(color: head.color.opacity(intensity * 0.85), location: 0.13),
			.init(color: head.color.opacity(intensity), location: 0.17),
			.init(color: BatHue.at(ring, wave + 0.10).color.opacity(intensity * 0.35), location: 0.26),
			.init(color: head.color.opacity(0.04), location: 0.52),
			.init(color: tail.color.opacity(0), location: 1.00)
		]
		return AngularGradient(stops: stops, center: .center, angle: .degrees(wave * 360))
	}

	/// How long a step of the light takes to travel.
	///
	/// The rule is one thing: a step has to finish crossing before the next push
	/// arrives, or the movement is a stutter and the card looks like it is being
	/// yanked rather than drifting. So it is measured against the cadence the
	/// state actually arrives at, which is roughly once a second while a transfer
	/// is moving — and once every twenty-five while the job is silent, because
	/// that is the beat that keeps the card fresh and the wave rides on it.
	static func glide(_ state: DownloadActivityAttributes.ContentState) -> Double {
		state.hasFraction ? 0.9 : silentGlide
	}

	/// Matched to `LiveActivityController.keepFresh` — the beat the app pushes on
	/// while a phase has nothing of its own to report. A shade under it, so the
	/// light arrives before the next state does.
	static let silentGlide: Double = 20
}

/// The soft light behind the mark, in the colour of whatever is running.
///
/// The one part of the light that is not motion but presence: it is what makes
/// the badge read as lit rather than as pasted on, and it is what carries the
/// phase's hue into the parts of the card that have no room for a bar.
struct BatGlow: View {
	var phase: DownloadActivityAttributes.ContentState.Phase
	var size: CGFloat = 26
	var intensity: Double = 0.55

	var body: some View {
		Circle()
			.fill(
				RadialGradient(
					colors: [
						BatAura.tint(phase).opacity(intensity),
						BatAura.tint(phase).opacity(0)
					],
					center: .center,
					startRadius: 0,
					endRadius: size / 2
				)
			)
			.frame(width: size, height: size)
			.blur(radius: size / 8)
	}
}

/// A highlight travelling around the rim of a shape.
///
/// The stops matter more than the shape does. Almost the whole gradient is clear
/// and one narrow band near its start is bright, so what moves around the edge is
/// a comet rather than a ring that swaps colour; rotating the gradient's own
/// angle is what moves it, which needs no second view and no layout of its own.
/// Stop 0 and stop 1 are both clear, so the closed gradient has no seam.
struct WaveRim<S: InsettableShape>: View {
	var shape: S
	var phase: DownloadActivityAttributes.ContentState.Phase
	/// 0…1 round the rim.
	var wave: Double
	var lineWidth: CGFloat = 1
	/// How bright the comet's head gets. The tail falls away from it.
	var intensity: Double = 0.55
	/// How long a step of the light takes to glide. See `BatAura.glide`.
	var glide: Double = 0.9

	var body: some View {
		// The light moves when — and only when — the card is handed a new state,
		// and the change is what carries it round.
		//
		// Both of the other arrangements have been tried against this one on a
		// running simulator, and both are worse:
		//
		//  * pushing a fresh phase several times a second to move the light makes
		//    the island blink, because the system re-renders and cross-fades a
		//    live activity on every update it is handed;
		//  * letting the view animate itself — a `repeatForever` rotation — ends
		//    the activity outright. Measured, not guessed: with the self-animation
		//    in place the card was gone (cards=0) three seconds into the silent
		//    signing phase, and with it removed the same run held one card
		//    throughout and ended clean.
		//
		// So the light is carried by real news, at the rate real news arrives:
		// it travels while bytes are moving, and while the job is silent it drifts
		// on the beat that keeps the card alive — one long, slow step every
		// twenty-five seconds, which reads as breathing rather than as stutter
		// because the step takes twenty of those seconds to complete.
		shape
			.strokeBorder(BatAura.halo(phase, wave: wave, intensity: intensity), lineWidth: lineWidth)
			.animation(.linear(duration: glide), value: wave)
	}
}

/// The same light, running along a rail instead of round a rim.
///
/// A wide, short card is no place for an angular gradient — the comet would
/// crawl along the long edge and flash round the short ones. A band that crosses
/// the rail and slides off the end reads as the same motion in the place the eye
/// is already looking: the bar the progress is on.
struct WaveRail: View {
	var phase: DownloadActivityAttributes.ContentState.Phase
	/// 0…1 across the rail.
	var wave: Double
	var height: CGFloat = 2
	/// How much of the rail the band covers at once.
	var width: Double = 0.34
	var intensity: Double = 0.8
	/// How long a step of the band takes to glide. Same reasoning as the rim's:
	/// the motion is carried by the states the card is handed, not by the view.
	var glide: Double = 0.9

	var body: some View {
		GeometryReader { geometry in
			let span = max(geometry.size.width, 1)
			let band = span * width
			// The band starts fully off one end and finishes fully off the other,
			// so it enters and leaves rather than appearing in place at 0.
			let travel = span + band

			Capsule()
				.fill(Color.white.opacity(0.10))
				.overlay(alignment: .leading) {
					Capsule()
						.fill(BatAura.flow(phase, wave: wave, stops: 4))
						.opacity(intensity)
						.frame(width: band)
						.offset(x: travel * wave - band)
						.animation(.linear(duration: glide), value: wave)
				}
				.clipShape(Capsule())
		}
		.frame(height: height)
	}
}

/// The bar the job's progress is on.
///
/// Drawn rather than borrowed, for one reason that matters and one that is
/// cosmetic. The reason: a measured fraction fills the bar, and a phase with
/// nothing to measure fills nothing at all and sends a band of light down the
/// track instead — the two states must not look alike, because the whole point
/// of the honest card is that a figure nobody measured is never painted as a
/// fraction somebody did.
///
/// The cosmetic one: the system's linear bar is a fixed picture, and this bar is
/// where the light lives. It fills with a gradient that travels as the transfer
/// does, and its leading edge glows, so a job that is moving looks like it is
/// moving even in the fraction of a second between two numbers.
struct AuraBar: View {
	var phase: DownloadActivityAttributes.ContentState.Phase
	var wave: Double
	/// 0…1. Read only when `known` is true.
	var progress: Double
	/// Whether `progress` is a fraction somebody measured.
	var known: Bool
	var height: CGFloat = 6
	var glide: Double = 0.9

	var body: some View {
		GeometryReader { geometry in
			let span = max(geometry.size.width, 1)
			let filled = max(span * min(max(progress, 0), 1), height)

			ZStack(alignment: .leading) {
				Capsule().fill(Color.white.opacity(0.12))

				if known {
					// The measured half: the fill, with a sheen that runs along
					// it. The sheen is inside the fill's own capsule, so it can
					// never be seen crossing the part that is not done.
					Capsule()
						.fill(BatAura.flow(phase, wave: wave))
						.frame(width: filled)
						.overlay(alignment: .leading) {
							Rectangle()
								.fill(
									LinearGradient(
										colors: [
											.white.opacity(0),
											.white.opacity(0.45),
											.white.opacity(0)
										],
										startPoint: .leading,
										endPoint: .trailing
									)
								)
								.frame(width: filled * 0.55)
								.offset(x: (filled + filled * 0.55) * wave - filled * 0.55)
						}
						.clipShape(Capsule())
						.shadow(color: BatAura.tint(phase).opacity(0.45), radius: 2)
				} else {
					// Nothing to measure: no fill, and a band of light that
					// passes through. Deliberately not a fill that creeps along
					// on its own — that would be a number invented by a view.
					Capsule()
						.fill(BatAura.flow(phase, wave: wave, stops: 4))
						.frame(width: span * 0.38)
						.offset(x: (span + span * 0.38) * wave - span * 0.38)
				}
			}
			.animation(.linear(duration: glide), value: wave)
			.clipShape(Capsule())
		}
		.frame(height: height)
	}
}

/// The light behind the Lock Screen card.
///
/// Three soft fields of the phase's own blues, drifting on the same wave as
/// everything else. On the Lock Screen there is room for the light to be a place
/// rather than an edge, and this is what makes the card look lit from within
/// instead of tinted — the difference between a rectangle with a border and a
/// thing that is glowing.
///
/// Positions come out of the wave, so nothing here animates itself: the fields
/// move when the card is handed a state, and the glide carries them.
struct AuroraField: View {
	var phase: DownloadActivityAttributes.ContentState.Phase
	var wave: Double
	var glide: Double = 0.9

	var body: some View {
		GeometryReader { geometry in
			let width = geometry.size.width
			let height = geometry.size.height
			let diameter = max(width, 180) * 0.95

			ZStack {
				ForEach(0..<3, id: \.self) { index in
					let turn = (wave + Double(index) / 3).truncatingRemainder(dividingBy: 1)
					let angle = turn * 2 * .pi
					let hue = BatHue.at(BatAura.ring(phase), wave + Double(index) * 0.22)

					Circle()
						.fill(
							RadialGradient(
								colors: [
									hue.color.opacity(0.50),
									hue.color.opacity(0.16),
									hue.color.opacity(0)
								],
								center: .center,
								startRadius: 0,
								endRadius: diameter / 2
							)
						)
						.frame(width: diameter, height: diameter)
						.offset(
							x: cos(angle) * width * 0.34,
							y: sin(angle * 0.8 + Double(index)) * height * 0.40
						)
				}
			}
			.frame(width: width, height: height)
			.blur(radius: 20)
			.animation(.easeInOut(duration: glide), value: wave)
		}
	}
}
