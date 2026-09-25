//
//  BatSignActivityBundle.swift
//  BatSignLiveActivity
//
//  The Live Activity for downloads: the Dynamic Island and Lock Screen side of
//  the status the app publishes. Everything it draws comes from the state in the
//  shared `DownloadActivityAttributes`, so it cannot disagree with the app.
//
//  Four things are deliberate:
//
//  * The mark is the bat, in BatSign blue, in every presentation. A phase glyph
//    that changes shape as the job moves is a different picture every two
//    seconds, and the island is too small to learn a new one each time. The
//    phase is carried by the light, the words and the keyline instead.
//
//  * Each region is sized to the region. The island's compact halves are one
//    line tall; a `.title2` glyph or a padded percentage is what pushes a pill
//    wider than the island it came out of.
//
//  * The light is a value, not an animation. A live activity is rendered as a
//    snapshot, so nothing here loops; the travelling blues come out of
//    `state.wavePhase`, which the app advances on the clock and re-sends while it
//    has work in hand — once a second while bytes are moving, and on a slow beat
//    while the job is silent. Each update repaints the light a little further
//    round and a little further through its hues, and the implicit animation the
//    light views carry turns the steps into a glide: short ones while the numbers
//    are moving, one long twenty-second drift per beat while they are not.
//
//  * Nothing on this card states a figure nobody measured. The bar fills only
//    against a real fraction and passes a band of light through itself when there
//    is none, because a bar that cannot move is a bar that lies — and a job that
//    is over says so, since the card ends on the landing rather than on a timer.
//

import ActivityKit
import OSLog
import SwiftUI
import WidgetKit

#if DEBUG
/// Reports the size a compact half is laid out at, once, when the island draws it.
///
/// "It fits" is a measurement or it is nothing: the island's compact regions are
/// sized by the system, and the only place that knows what they were given is the
/// extension that filled them. Debug only — the shipping build carries neither the
/// probe nor its log line.
private struct IslandFitProbe: ViewModifier {
	@State private var reported = false
	let name: String

	func body(content: Content) -> some View {
		content.background(
			GeometryReader { proxy in
				Color.clear.onAppear {
					guard !reported else { return }
					reported = true
					Logger(subsystem: "app.batsign.ios.status", category: "islandfit")
						.notice("islandfit: \(name, privacy: .public) drew at \(Int(proxy.size.width.rounded()))x\(Int(proxy.size.height.rounded())) pt")
				}
			}
		)
	}
}

extension View {
	func islandFit(_ name: String) -> some View {
		modifier(IslandFitProbe(name: name))
	}
}
#else
extension View {
	/// Nothing is measured in a shipping build: the call sites stay in place so
	/// the two builds lay out exactly the same view tree, and the probe — which
	/// is the only thing that differs — is not compiled at all.
	func islandFit(_ name: String) -> some View { self }
}
#endif

@main
struct BatSignActivityBundle: WidgetBundle {
	var body: some Widget {
		BatSignDownloadActivity()
	}
}

struct BatSignDownloadActivity: Widget {
var body: some WidgetConfiguration {
			ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
				LockScreenStatusView(state: context.state, stale: context.isStale)
					.activityBackgroundTint(Color.black.opacity(0.55))
					.activitySystemActionForegroundColor(.white)
			} dynamicIsland: { context in
				let state = context.state
				// Whether the app behind this card has stopped reporting. Every live
				// state is stamped with a freshness date a minute out and the app
				// re-stamps it as it works, so a card the system calls stale is a
				// card whose app is gone — suspended past the window, or killed.
				//
				// What it must not do then is keep printing the last fraction it was
				// handed. A number frozen at 90% with a light still drifting round it
				// is the island claiming work that nobody is doing, and "it stops at a
				// random number" is what that reads as. The phase is what the job got
				// to, and the phase is still true; the number is not, so the number is
				// what goes.
				let stale = context.isStale
				// The one change a stale card gets: no figure. `progressKnown` is what
				// every number-bearing view reads — the percentage, the compact text
				// and the bar's fill — so clearing it here turns all three back into
				// the phase at once, with one edit and no chance of the three
				// disagreeing about whether the number still stands.
				var display = state
				if stale { display.progressKnown = false }
				let glide = BatAura.glide(state)

			return DynamicIsland {
				DynamicIslandExpandedRegion(.leading) {
					// Lit, not pasted on: the glow is the phase's own colour and
					// it is the one part of the light that does not move, so the
					// mark stays the still point the rest of the card turns on.
					ZStack {
						BatGlow(phase: state.phase, size: 32, intensity: 0.45)
						BatBadge(size: 18)
					}
					.frame(width: 32, height: 32)
					.padding(.leading, 2)
				}

				DynamicIslandExpandedRegion(.trailing) {
					// The number claims the width its own glyphs need, whatever the
					// region is offered. A percentage that is handed less room than it
					// needs used to truncate to "6…" — the one figure on the card that
					// must always be readable, cut in half by a layout it had no say
					// in. `fixedSize` makes the text independent of the proposal: it
					// draws "100%" at its own size rather than accepting a squeeze, and
					// the scale factor is the fallback for a region narrower still.
					Text(display.percentText)
						.font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
						.foregroundStyle(BatAura.tint(state.phase))
						.shadow(color: BatAura.tint(state.phase).opacity(0.45), radius: 4)
						.lineLimit(1)
						.fixedSize(horizontal: true, vertical: false)
						.minimumScaleFactor(0.75)
						.padding(.trailing, 2)
						.islandFit("expandedTrailing")
				}

				DynamicIslandExpandedRegion(.center) {
					VStack(alignment: .leading, spacing: 1) {
						// A long name shrinks a little before it is cut. The tail of a
						// name is the least useful part of it, but "FitbittoAppleHeal…"
						// is easier to place than "FitbittoAppleHealth 3.3.0 Pro @t…"
						// is, and the name is the only thing on this card that says
						// *which* app the job is about.
						Text(state.appName)
							.font(.subheadline.weight(.semibold))
							.lineLimit(1)
							.minimumScaleFactor(0.7)
						HStack(spacing: 4) {
							// A dot in the phase's colour, so the phase is legible
							// at a glance and in one place, the way the keyline and
							// the bar already agree with it.
							Circle()
								.fill(BatAura.tint(state.phase))
								.frame(width: 5, height: 5)
							Text(state.phase.title)
								.font(.caption2)
								.textCase(.uppercase)
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
						.islandFit("expandedCenter")
				}

				DynamicIslandExpandedRegion(.bottom) {
					VStack(spacing: 6) {
						// A measured bar while there is a fraction, and a band of
						// light crossing the track while there is not. Signing has
						// no percentage, and a bar parked at 100% for its length
						// reads as a stall.
						AuraBar(
							phase: state.phase,
							wave: state.wavePhase,
							progress: display.clampedProgress,
							known: display.hasFraction,
							height: 6,
							glide: glide
						)

						HStack(spacing: 6) {
							Text(state.subtitle)
								.font(.caption2)
								.foregroundStyle(.secondary)
								.lineLimit(1)
								.minimumScaleFactor(0.8)
							Spacer(minLength: 4)
							if state.queued > 0 {
								Text("+\(state.queued) more")
									.font(.caption2.weight(.semibold))
									.foregroundStyle(.secondary)
									.fixedSize(horizontal: true, vertical: false)
							}
						}

						// The rail the light runs along, on the card's own bottom
						// edge: the one place in the expanded island that is a long,
						// still, horizontal line, which is what a travelling band
						// needs to read as travel rather than as a flicker.
						WaveRail(
							phase: state.phase,
							wave: state.wavePhase,
							height: 2,
							glide: glide
						)
						.padding(.top, 1)
					}
				}
			} compactLeading: {
				// The compact half is one line tall — 36.67 pt, and 7 pt of that is
				// the island's own inset — so the mark is laid out to the width the
				// region actually has, glow included.
				//
				// Glow included is the whole point. `BatGlow` is a blurred circle,
				// and blur draws *outside* the frame it is given: a 24 pt glow
				// carries its light roughly half again as far as its own edge, so
				// the mark this used to draw reached well past the pill it sat in.
				// The island clips at its own edge, which is why it read as a hard
				// edge hanging off the island rather than as light. The glow is
				// sized so its blurred footprint lands inside the 20 pt square, and
				// the square is clipped to the mark's own circle so nothing can
				// leave it whatever the phase does.
				ZStack {
					BatGlow(phase: state.phase, size: 11, intensity: 0.40)
					BatBadge(size: 13)
				}
				.frame(width: 20, height: 20)
				.clipShape(Circle())
				.islandFit("compactLeading")
			} compactTrailing: {
				// The trailing half is bounded rather than merely small. Four
				// glyphs is the most any phase can ask for ("100%", "UPDT"), and
				// measured at this font the widest of them is 30.4 pt — so 31 pt is
				// the bound, and the text scales rather than pushing at the island's
				// edge. Nothing here is truncated: a squeezed label still reads, a
				// clipped one does not.
				Text(display.compactText)
					.font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
					.lineLimit(1)
					.minimumScaleFactor(0.85)
					.frame(maxWidth: 31)
					.foregroundStyle(BatAura.tint(state.phase))
					.islandFit("compactTrailing")
			} minimal: {
				// One glyph, for when another activity is sharing the island. The
				// same bounded square as the compact half, so it cannot be the
				// thing that does not fit.
				ZStack {
					BatGlow(phase: state.phase, size: 11, intensity: 0.35)
					BatBadge(size: 13)
				}
				.frame(width: 20, height: 20)
				.clipShape(Circle())
			}
			// The island's own edge. The light inside is the card's; this is the
			// keyline the system draws around it, tinted to the phase so the edge
			// and the bar agree about what is happening.
			.keylineTint(BatAura.tint(state.phase))
		}
	}
}

// MARK: - Lock screen

private struct LockScreenStatusView: View {
	let state: DownloadActivityAttributes.ContentState
	/// Whether the system has marked this card stale — see the island above.
	var stale: Bool = false

	/// The state the number-bearing views read. A stale card shows its phase
	/// rather than its last fraction, for the reason given at the island.
	private var display: DownloadActivityAttributes.ContentState {
		var copy = state
		if stale { copy.progressKnown = false }
		return copy
	}

	private var tint: Color { BatAura.tint(state.phase) }
	private var glide: Double { BatAura.glide(state) }

	var body: some View {
		ZStack {
			// The light as a place rather than an edge: three soft fields of the
			// phase's blues, drifting on the same wave as the bar and the rim, so
			// the card looks lit from within.
			AuroraField(phase: state.phase, wave: state.wavePhase, glide: glide)

			VStack(alignment: .leading, spacing: 11) {
				HStack(alignment: .center, spacing: 12) {
					ZStack {
						RoundedRectangle(cornerRadius: 13, style: .continuous)
							.fill(Color.white.opacity(0.07))
						RoundedRectangle(cornerRadius: 13, style: .continuous)
							.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
						BatGlow(phase: state.phase, size: 36, intensity: 0.35)
						BatBadge(size: 23)
					}
					.frame(width: 44, height: 44)

					VStack(alignment: .leading, spacing: 3) {
						Text(state.appName)
							.font(.headline)
							.lineLimit(1)
							.minimumScaleFactor(0.75)
						Text(state.phase.title)
							.font(.caption)
							.fontWeight(.medium)
							.textCase(.uppercase)
							.foregroundStyle(tint.opacity(0.95))
							.lineLimit(1)
							.minimumScaleFactor(0.8)
					}

					Spacer(minLength: 8)

					// The figure keeps its room: the name beside it is the thing that
					// gives way when the card is narrow, because a name that is cut is
					// still the app's name and a percentage that is cut is not a number.
					Text(display.percentText)
						.font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
						.foregroundStyle(tint)
						.lineLimit(1)
						.fixedSize(horizontal: true, vertical: false)
						.minimumScaleFactor(0.75)
						.layoutPriority(1)
				}

				AuraBar(
					phase: state.phase,
					wave: state.wavePhase,
					progress: display.clampedProgress,
					known: display.hasFraction,
					height: 7,
					glide: glide
				)

					HStack(spacing: 6) {
						Text(state.subtitle)
							.font(.caption2)
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.minimumScaleFactor(0.8)
						Spacer(minLength: 4)
						if state.queued > 0 {
							Text("+\(state.queued) more")
								.font(.caption2.weight(.semibold))
								.foregroundStyle(.secondary)
								.fixedSize(horizontal: true, vertical: false)
						}
					}

				WaveRail(
					phase: state.phase,
					wave: state.wavePhase,
					height: 2.5,
					intensity: 0.7,
					glide: glide
				)
			}
			.padding(15)
		}
		// The same light that runs round the island runs round the card, so the
		// two presentations of one job look like one thing. Faint on purpose:
		// this sits behind text the user is trying to read.
		.overlay {
			WaveRim(
				shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
				phase: state.phase,
				wave: state.wavePhase,
				lineWidth: 1,
				intensity: 0.30,
				glide: glide
			)
		}
	}
}
