//
//  BSDesign.swift
//  Feather
//
//  The design tokens every screen shares, in the App Store's own language.
//
//  This file is design only: colours, the ground, the card and glass shapes and
//  the shared headings. Nothing here signs, installs, downloads or stores
//  anything, so the engine underneath is untouched by it.
//
//  The palette is deliberately *semantic* rather than a fixed set of hexes.
//  The App Store is a black ground with #1C1E1E cards in dark mode and the same
//  layout in light greys in light mode, and the system's own colours are the
//  only way to get both right without maintaining two palettes. The story card
//  and pill get their exact values in BSStore.
//

import SwiftUI
import UIKit

// MARK: - Colour helper

extension Color {
	/// The hex initialiser this palette is authored in. Kept separate from the
	/// string-based `Color(hex:)` Feather already has, so neither shadows the
	/// other.
	init(bsHex: UInt32, alpha: Double = 1) {
		self.init(
			.sRGB,
			red: Double((bsHex >> 16) & 0xFF) / 255,
			green: Double((bsHex >> 8) & 0xFF) / 255,
			blue: Double(bsHex & 0xFF) / 255,
			opacity: alpha
		)
	}
}

// MARK: - Tokens

enum BS {
	/// The accent ramp, iOS 27 values: #0088ff light, #0091ff dark — unless the
	/// user chose a tint of their own, which then is the accent everywhere the
	/// accent is used. One colour, so the storefront's blue and the app's own
	/// blue can never drift apart.
	static var accent: Color {
		if let hex = UserDefaults.standard.string(forKey: "Feather.userTintColor"),
		   let user = Color(bsHexString: hex) {
			return user
		}
		return Color(bsLight: 0x0088FF, bsDark: 0x0091FF)
	}

	/// The deeper end of the accent ramp. Derived from the accent itself, so a
	/// user-chosen tint gets a ramp that belongs to it rather than to the
	/// default blue.
	static var accentDeep: Color {
		let base = UIColor(accent)
		var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
		base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
		return Color(
			hue: Double(hue),
			saturation: Double(min(saturation + 0.08, 1)),
			brightness: Double(brightness * 0.78)
		)
	}

	static let onAccent = Color.white

	/// What the bar's *selected* item is drawn in — the label and the glyph on
	/// it. Not an accent: the bar indicates where you are by weight and by the
	/// system's own selection capsule, so a colour there was the only blue on an
	/// otherwise neutral screen.
	static let tabTint = Color.primary

	// Semantics — the iOS 27 system accents.
	static let success = Color(bsLight: 0x34C759, bsDark: 0x30D158)
	static let warning = Color(bsLight: 0xFF8D28, bsDark: 0xFF9230)
	static let danger = Color(bsLight: 0xFF383C, bsDark: 0xFF4245)

	// Glass
	static let stroke = Color(uiColor: .separator)
	static let strokeSoft = Color(uiColor: .separator)

	/// What a card is filled with. The store's grouped cell: #f2f2f7 light,
	/// #1c1c1e dark — the measured grouped secondary background.
	static let cardFill = Color(uiColor: .secondarySystemBackground)
	static let cardFillFaded = Color(uiColor: .secondarySystemBackground)

	/// Chips, wells and search fields — one level above a card.
	static let chipFill = Color(uiColor: .tertiarySystemBackground)

	/// What the screens sit on: the system background, edge to edge.
	static let screen = Color(uiColor: .systemBackground)

	// Radii — the kit's scale, through the surface system.
	static let radiusCard: CGFloat = BSSurface.radiusCard
	static let radiusSmall: CGFloat = BSSurface.radiusSmall
	static let radiusControl: CGFloat = BSSurface.radiusControl
}

// MARK: - Ground

extension View {
	/// Every screen sits on the App Store's ground. A flat system background
	/// rather than a wash: the storefront reads as a product, not as a gradient.
	func bsScreen() -> some View {
		self.background { BSStoreGround() }
	}

	/// Kept so screens that used to draw their own backdrop have one call site
	/// to change rather than a modifier that quietly does nothing.
	func bsAuroraScreen() -> some View {
		bsScreen()
	}

	/// The bar and the lists are see-through, so the ground is what the whole
	/// screen is drawn on rather than a slab with panels on top.
	func bsChrome() -> some View {
		self
			.scrollContentBackground(.hidden)
			.toolbarBackground(.hidden, for: .navigationBar)
			.toolbarBackground(.hidden, for: .tabBar)
	}

	/// A floating pane on the system's own glass.
	///
	/// On iOS 26 and later this is one call and one layer: the system's glass is
	/// a single material with its own edge treatment, and adding a stroke over it
	/// would draw a second outline just inside the first. Below 26 the iOS 27
	/// recipe is built by hand from the measured material, fill, rim and lit
	/// edge — see BSSurface.
	@ViewBuilder
	func bsGlass(cornerRadius: CGFloat = BS.radiusCard, interactive: Bool = false) -> some View {
		bsGlassPanel(cornerRadius: cornerRadius, interactive: interactive)
	}

	/// The same glass, cut as a circle — the shape every top-corner control on
	/// the storefront uses.
	@ViewBuilder
	func bsGlassCircle(interactive: Bool = false) -> some View {
		if #available(iOS 26.0, *) {
			self.glassEffect(interactive ? .regular.interactive() : .regular, in: .circle)
		} else {
			self
				.background(BSSurface.glassMaterial, in: Circle())
				.background(Circle().fill(BSSurface.glassFill))
				.overlay(Circle().strokeBorder(BSSurface.rim, lineWidth: 0.6))
		}
	}

	/// Glass in a shape of the caller's choosing — a capsule for the storefront's
	/// pills. Same single-surface rule as above.
	@ViewBuilder
	func bsGlassCapsule(interactive: Bool = false) -> some View {
		bsGlassPill(interactive: interactive)
	}

	/// The card surface: a grouped cell, flat and quiet, with a hairline.
	@ViewBuilder
	func bsCard(cornerRadius: CGFloat = BS.radiusCard, padding: CGFloat? = nil) -> some View {
		Group {
			if let padding {
				self.padding(padding)
			} else {
				self
			}
		}
		.background(
			RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
				.fill(BS.cardFill)
		)
		.overlay(
			RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
				.strokeBorder(BS.strokeSoft.opacity(0.5), lineWidth: 0.5)
		)
	}
}

// MARK: - Corner control

/// A screen's top-right control, the way the App Store draws its own: a small
/// circular glyph on real Liquid Glass on iOS 26, and on a material below it.
///
/// It is shared so Today's gear, Today's refresh, Sources' "+" and any future
/// corner action are the same object rather than three near-copies that drift —
/// and it takes a `BSGlyph`, so the whole app's chrome is drawn from the one
/// icon set instead of borrowing a symbol per control.
struct BSCornerButton: View {
	let glyph: BSGlyph
	var label: String
	/// Whether this control stands on its own surface.
	///
	/// The toolbar on iOS 26 draws one shared Liquid Glass background around
	/// *adjacent* items and groups them into a single capsule — so two corner
	/// controls side by side (Today's Updates and Settings) used to render as one
	/// button holding two glyphs, measured at 128 pt across on the simulator
	/// where a lone control is a 46 pt circle. Positions that show more than one
	/// corner control opt in here and hide the shared surface at the call site
	/// (`.sharedBackgroundVisibility(.hidden)`), and this control then draws the
	/// same circle it draws below iOS 26 — one button per control, each the size
	/// of Sources' single "+".
	var standalone: Bool = false
	var action: () -> Void

	/// The circle's diameter. A lone control's system-drawn surface measures
	/// 46 pt on iOS 26; below it this control has always drawn a 38 pt circle.
	private var _diameter: CGFloat {
		if standalone, #available(iOS 26.0, *) { return 44 }
		return 38
	}

	var body: some View {
		Button {
			BSHaptics.tap()
			action()
		} label: {
			if standalone {
				BSGlyphView(kind: glyph, size: 19)
					.foregroundStyle(Color.primary)
					.frame(width: _diameter, height: _diameter)
					.bsGlassCircle(interactive: true)
			} else if #available(iOS 26.0, *) {
				// The toolbar already draws its own Liquid Glass around its items
				// on 26 — and groups adjacent items into one capsule. Painting a
				// second glass inside the label stacks glass on glass, which is
				// exactly what renders as a washed-out white square next to a
				// correct circle. The glyph alone lets the system draw the one surface.
				BSGlyphView(kind: glyph, size: 19)
					.foregroundStyle(Color.primary)
					.frame(width: 38, height: 38)
			} else {
				BSGlyphView(kind: glyph, size: 19)
					.foregroundStyle(Color.primary)
					.frame(width: 38, height: 38)
					.bsGlassCircle(interactive: true)
			}
		}
		.buttonStyle(.plain)
		.accessibilityLabel(label)
	}
}

/// A card container, for the places that want the shape without a modifier.
struct BSCard<Content: View>: View {
	var cornerRadius: CGFloat = BS.radiusCard
	var padding: CGFloat = 16
	@ViewBuilder var content: Content

	init(cornerRadius: CGFloat = BS.radiusCard, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
		self.cornerRadius = cornerRadius
		self.padding = padding
		self.content = content()
	}

	var body: some View {
		content
			.padding(padding)
			.frame(maxWidth: .infinity, alignment: .leading)
			.bsCard(cornerRadius: cornerRadius)
	}
}

// MARK: - Headings, pills, buttons

/// A quiet section heading, uppercase and tracked.
struct BSSectionHeader: View {
	let title: String
	var trailing: String? = nil

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Text(title)
				.font(.footnote.weight(.semibold))
				.textCase(.uppercase)
				.foregroundStyle(.secondary)
				.kerning(0.6)
			Spacer()
			if let trailing {
				Text(trailing)
					.font(.footnote.weight(.semibold))
					.textCase(.uppercase)
					.foregroundStyle(.tertiary)
					.kerning(0.6)
			}
		}
		.padding(.horizontal, 4)
	}
}

/// A status pill: a capsule, coloured by state, on the system's glass rather
/// than under a tint and an outline stacked on top of each other.
struct BSStatusPill: View {
	let title: String
	var tint: Color = BS.success
	var glyph: BSGlyph? = nil

	var body: some View {
		HStack(spacing: 6) {
			if let glyph {
				BSGlyphView(kind: glyph, size: 11)
			}
			Text(title)
				.font(.caption.weight(.semibold))
		}
		.foregroundStyle(tint)
		.padding(.horizontal, 12)
		.padding(.vertical, 7)
		.bsGlassCapsule()
	}
}

struct BSPrimaryButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.system(.headline, design: .rounded, weight: .semibold))
			.foregroundStyle(BS.onAccent)
			.padding(.vertical, 15)
			.frame(maxWidth: .infinity)
			.background(
				LinearGradient(colors: [BS.accent, BS.accentDeep],
							   startPoint: .topLeading, endPoint: .bottomTrailing),
				in: RoundedRectangle(cornerRadius: BS.radiusControl, style: .continuous)
			)
			.overlay(
				// The lit rim — the one detail that moves a blue slab into the
				// same light as the glass around it.
				LinearGradient(
					colors: [Color.white.opacity(0.22), .clear],
					startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.42)
				)
				.clipShape(RoundedRectangle(cornerRadius: BS.radiusControl, style: .continuous))
			)
			.opacity(configuration.isPressed ? 0.82 : 1)
			.scaleEffect(configuration.isPressed ? 0.97 : 1)
			.animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
	}
}

enum BSHaptics {
	static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
	static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
	static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
