//
//  BSSurface.swift
//  Feather
//
//  The iOS 27 Liquid Glass system, translated from the measured tokens in
//  https://github.com/seunghan91/ios27-design-system (packages/tokens/src:
//  colors.json, materials.json). That repo is a web implementation and says so
//  itself — for SwiftUI it is a colour and dimension spec — so this file is the
//  spec, in Swift: the transparency slider's five presets, the glass fill and
//  rim values, and the corner radii, applied through one surface language.
//
//  Design only. Nothing here signs, installs, downloads or stores anything.
//

import SwiftUI
import UIKit

// MARK: - Adaptive colour

extension Color {
	/// A colour that resolves against the trait's own style, so a screen never
	/// carries two palettes. The hexes are the iOS 27 kit's measured values —
	/// sRGB approximations of the system's Display P3 colours.
	init(bsLight: UInt32, bsDark: UInt32) {
		self.init(uiColor: UIColor { trait in
			let hex = trait.userInterfaceStyle == .dark ? bsDark : bsLight
			return UIColor(
				red: CGFloat((hex >> 16) & 0xFF) / 255,
				green: CGFloat((hex >> 8) & 0xFF) / 255,
				blue: CGFloat(hex & 0xFF) / 255,
				alpha: 1
			)
		})
	}

	/// A colour from a stored "#RRGGBB" string, or nil when the string is not
	/// one. Self-contained because the hex helpers this app uses live in binary
	/// packages this file must not depend on.
	init?(bsHexString: String) {
		var raw = bsHexString.trimmingCharacters(in: .whitespacesAndNewlines)
		if raw.hasPrefix("#") { raw.removeFirst() }
		guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
		self.init(
			.sRGB,
			red: Double((value >> 16) & 0xFF) / 255,
			green: Double((value >> 8) & 0xFF) / 255,
			blue: Double(value & 0xFF) / 255,
			opacity: 1
		)
	}
}

// MARK: - The transparency slider, as five presets

/// iOS 27's Liquid Glass transparency slider (Settings → Appearance → Liquid
/// Glass), stepped. The slider itself is a system control no app can read;
/// these presets are its five published positions, and every surface in the
/// app scales its fill and blur from the one chosen here.
enum BSGlassLevel: Double, CaseIterable, Identifiable {
	/// Opaque chrome — the closest thing to pre-Liquid-Glass.
	case fullyTinted = 0
	case tinted = 0.25
	/// The system default. Already more diffused than iOS 26's.
	case standard = 0.5
	case clear = 0.75
	/// Maximum transparency. Verify foreground contrast per surface.
	case ultraClear = 1

	var id: Double { rawValue }

	var label: String {
		switch self {
		case .fullyTinted: return .localized("Fully Tinted")
		case .tinted: return .localized("Tinted")
		case .standard: return .localized("Default")
		case .clear: return .localized("Clear")
		case .ultraClear: return .localized("Ultra Clear")
		}
	}

	var detail: String {
		switch self {
		case .fullyTinted:
			return .localized("Opaque chrome. The old flat look, in glass's shape.")
		case .tinted:
			return .localized("Mostly opaque, a hint of what is underneath.")
		case .standard:
			return .localized("The system default for Liquid Glass.")
		case .clear:
			return .localized("Nearly transparent, for colourful screens.")
		case .ultraClear:
			return .localized("Maximum transparency.")
		}
	}

	/// 1.6 − 1.1t — how opaque the glass fill is, relative to the material.
	var opacityScale: Double { 1.6 - 1.1 * rawValue }

	/// 0.5 + 0.8t — how much diffusion the blur provides.
	var blurScale: Double { 0.5 + 0.8 * rawValue }
}

// MARK: - The surface system

enum BSSurface {
	static let levelKey = "BatSign.liquidGlassLevel"

	/// The chosen transparency, read when a surface draws itself. Stored
	/// plainly so every screen picks the change up on its next render without
	/// any plumbing between screens.
	static var level: BSGlassLevel {
		get {
			let raw = UserDefaults.standard.object(forKey: levelKey) as? Double ?? BSGlassLevel.standard.rawValue
			return BSGlassLevel(rawValue: raw) ?? .standard
		}
		set {
			UserDefaults.standard.set(newValue.rawValue, forKey: levelKey)
		}
	}

	// The measured values, from materials.json's backgroundMaterials:

	/// Regular glass: white 0.6 in light, black 0.41 in dark, scaled by the
	/// chosen level and clamped to what a hairline's worth of contrast allows.
	static var glassFill: Color {
		glassFill(at: level)
	}

	/// The same fill for a specific level, so a preview can draw what a level
	/// looks like before it is chosen.
	static func glassFill(at level: BSGlassLevel) -> Color {
		let lightA = min(0.9, 0.6 * level.opacityScale)
		let darkA = min(0.8, 0.41 * level.opacityScale)
		return Color(uiColor: UIColor { trait in
			let base: UInt32 = trait.userInterfaceStyle == .dark ? 0x000000 : 0xFFFFFF
			let a = trait.userInterfaceStyle == .dark ? darkA : lightA
			return UIColor(
				red: CGFloat((base >> 16) & 0xFF) / 255,
				green: CGFloat((base >> 8) & 0xFF) / 255,
				blue: CGFloat(base & 0xFF) / 255,
				alpha: a
			)
		})
	}

	/// The material under the fill: the blur end of the slider. Thin at the
	/// clear end, thick at the tinted end.
	static var glassMaterial: Material {
		switch level {
		case .ultraClear: return .ultraThinMaterial
		case .clear: return .thinMaterial
		case .standard: return .regularMaterial
		case .tinted, .fullyTinted: return .thickMaterial
		}
	}

	/// The measured rim: #dbdbdb light, #a6a6a6 dark — the outline that
	/// separates glass from the content beneath it.
	static var rim: Color {
		Color(bsLight: 0xDBDBDB, bsDark: 0xA6A6A6).opacity(0.55)
	}

	/// The lit edge: a brighter stroke along the top of a glass surface, the
	/// part that reads as light falling on the rim.
	static var specular: Color {
		Color(uiColor: UIColor { trait in
			trait.userInterfaceStyle == .dark
				? UIColor.white.withAlphaComponent(0.14)
				: UIColor.white.withAlphaComponent(0.34)
		})
	}

	/// The inner shadow that gives a panel its depth: dark at the top and
	/// bottom, per the kit's innerShadow measurement (±40 Y, blur 10).
	static var innerShadow: Color {
		Color(bsLight: 0x282828, bsDark: 0x1A1A1A).opacity(0.28)
	}

	// Radii, from the kit:

	/// Large and medium glass measured identical: 34 pt.
	static let radiusGlass: CGFloat = 34
	/// Small glass — pills and the floating bar's capsules.
	static let radiusPill: CGFloat = 100
	/// Cards and grouped cells.
	static let radiusCard: CGFloat = 20
	/// Controls.
	static let radiusControl: CGFloat = 16
	/// Small controls and chips.
	static let radiusSmall: CGFloat = 12
}

// MARK: - Glass surfaces

extension View {
	/// The iOS 27 glass panel: material + level fill + rim + lit top edge.
	///
	/// On iOS 26 and later the system's own `.glassEffect` is the real surface
	/// and gets the shape to draw in; the level still steers it — `.clear` for
	/// the transparent end, `.regular` otherwise — and a level-scaled fill
	/// sits behind it for the tinted end. Below 26 the same recipe is built by
	/// hand from a material, the measured fill and the measured rim.
	@ViewBuilder
	func bsGlassPanel(cornerRadius: CGFloat = BSSurface.radiusGlass, interactive: Bool = false) -> some View {
		if #available(iOS 26.0, *) {
			self
				.glassEffect(
					(interactive
						? (BSSurface.level == .ultraClear || BSSurface.level == .clear
							? Glass.clear.interactive() : Glass.regular.interactive())
						: (BSSurface.level == .ultraClear || BSSurface.level == .clear
							? Glass.clear : Glass.regular)),
					in: .rect(cornerRadius: cornerRadius)
				)
		} else {
			self
				.background(BSSurface.glassMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
				.background(
					RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
						.fill(BSSurface.glassFill)
				)
				.overlay(
					RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
						.strokeBorder(BSSurface.rim, lineWidth: 0.6)
				)
				.overlay(
					// The lit rim: a highlight that fades out as it falls, so the
					// panel reads as glass rather than as a flat tile.
					LinearGradient(
						colors: [BSSurface.specular, .clear],
						startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)
					)
					.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
				)
		}
	}

	/// The same glass, cut as a pill — buttons, chips, the bar's capsules.
	@ViewBuilder
	func bsGlassPill(interactive: Bool = false) -> some View {
		if #available(iOS 26.0, *) {
			self
				.glassEffect(
					interactive
						? .regular.interactive()
						: .regular,
					in: .capsule
				)
		} else {
			self
				.background(BSSurface.glassMaterial, in: Capsule())
				.background(Capsule().fill(BSSurface.glassFill))
				.overlay(Capsule().strokeBorder(BSSurface.rim, lineWidth: 0.6))
		}
	}
}

// MARK: - Button styles

/// The glass button: a pill on Liquid Glass with the pressed state the system
/// gives its own — it yields rather than dims.
struct BSGlassButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.system(.body, design: .rounded).weight(.semibold))
			.foregroundStyle(Color.primary)
			.padding(.horizontal, 18)
			.padding(.vertical, 11)
			.bsGlassPill(interactive: true)
			.opacity(configuration.isPressed ? 0.6 : 1)
			.scaleEffect(configuration.isPressed ? 0.96 : 1)
			.animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
	}
}

// MARK: - The bar

/// A tab bar appearance built from the same recipe, for the systems below
/// iOS 26 that draw the bar with UIKit appearances. On 26+ the system's
/// floating glass bar is already the real surface and is left alone — an
/// appearance object there would replace the glass with flat colours.
enum BSSurfaceTabBar {
	static func apply() {
		guard #unavailable(iOS 26.0) else { return }

		let appearance = UITabBarAppearance()
		appearance.configureWithTransparentBackground()
		appearance.backgroundEffect = UIBlurEffect(style: .systemMaterial)
		appearance.backgroundColor = UIColor(BSSurface.glassFill)

		appearance.stackedLayoutAppearance.normal.iconColor = .secondaryLabel
		appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.secondaryLabel]
		appearance.stackedLayoutAppearance.selected.iconColor = .label
		appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.label]

		UITabBar.appearance().standardAppearance = appearance
		UITabBar.appearance().scrollEdgeAppearance = appearance
	}
}
