//
//  AppearanceView.swift
//  Feather
//
//  Created by samara on 7.05.2025.
//

import SwiftUI
import NimbleViews
import UIKit

// MARK: - View
// dear god help me
struct AppearanceView: View {
	@AppStorage("Feather.userInterfaceStyle")
	private var _userIntefacerStyle: Int = UIUserInterfaceStyle.unspecified.rawValue

	@AppStorage("Feather.userTintColor")
	private var _selectedColorHex: String = "#848ef9"

	private var _tintColorBinding: Binding<Color> {
		Binding(
			get: { Color(hex: _selectedColorHex) },
			set: { _selectedColorHex = $0.toHex() }
		)
	}
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Appearance")) {
			Section {
				Picker(.localized("Appearance"), selection: _styleBinding) {
					ForEach(UIUserInterfaceStyle.allCases.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { style in
						Text(style.label).tag(style.rawValue)
					}
				}
				.pickerStyle(.segmented)
			}

			NBSection(.localized("Liquid Glass")) {
				// iOS 27's transparency slider, as its five published positions.
				// Each row previews the real surface over colour, so what the
				// picker promises is what the tab bar and every panel will look
				// like — the same tokens, drawn by the same code.
				ForEach(BSGlassLevel.allCases) { level in
					BSGlassLevelRow(level: level, selected: _levelBinding)
				}
				.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
				.listRowBackground(EmptyView())
			}

			NBSection(.localized("Accent Color")) {
				ColorPicker(
					.localized("Accent Color"),
					selection: _tintColorBinding,
					supportsOpacity: false
				)
			}
		}
		.onChange(of: _userIntefacerStyle) { value in
			// Both halves of the appearance have to be told, and they have to be
			// told the same thing. The app's own screens follow the
			// `preferredColorScheme` that `FeatherApp` derives from this same
			// stored value, so they have already changed by the time this runs;
			// what still needs saying is the window's override, because UIKit
			// surfaces — alerts, context menus, the share sheet — are not SwiftUI
			// views and follow their window instead.
			//
			// `.unspecified` is the point of "Default": it hands the decision back
			// to the iPhone rather than picking one.
			let style = UIUserInterfaceStyle(rawValue: value) ?? .unspecified
			let window = UIApplication.topViewController()?.view.window
				?? UIApplication.shared.connectedScenes
					.compactMap { ($0 as? UIWindowScene)?.keyWindow }
					.first
			window?.overrideUserInterfaceStyle = style
		}
	}

	/// The appearance picker's own binding, so the fade begins on the tap.
	///
	/// The snapshot a cross-fade is made of has to be of the appearance being
	/// left behind, and by the time `onChange` runs the new one is already the
	/// trait the window reports. The write is therefore wrapped: snapshot, then
	/// write, and the window's own override is still applied underneath by the
	/// `onChange` below, which every path that changes this value goes through.
	private var _styleBinding: Binding<Int> {
		Binding(
			get: { _userIntefacerStyle },
			set: { newValue in
				guard newValue != _userIntefacerStyle else { return }
				BSAppearanceStyle.stored = newValue
			}
		)
	}

	/// The chosen glass level, as a binding the rows share.
	private var _levelBinding: Binding<BSGlassLevel> {
		Binding(
			get: { BSSurface.level },
			set: { BSSurface.level = $0 }
		)
	}
}

// MARK: - The Liquid Glass picker row

/// One position of the transparency slider, with the surface itself as the
/// preview: the row's glass is drawn by the same `bsGlassPanel` the whole app
/// uses, over a small patch of colour so the transparency is actually visible
/// rather than asserted.
private struct BSGlassLevelRow: View {
	let level: BSGlassLevel
	@Binding var selected: BSGlassLevel

	private var isSelected: Bool { selected == level }

	var body: some View {
		Button {
			BSHaptics.tap()
			selected = level
		} label: {
			HStack(spacing: 12) {
				_preview
				VStack(alignment: .leading, spacing: 2) {
					Text(level.label)
						.font(.body.weight(.semibold))
						.foregroundStyle(Color.primary)
					Text(level.detail)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(2)
						.multilineTextAlignment(.leading)
				}
				Spacer(minLength: 8)
				if isSelected {
					Image(systemName: "checkmark")
						.font(.system(size: 15, weight: .semibold))
						.foregroundStyle(BS.accent)
				}
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
			.bsCard(cornerRadius: 18)
		}
		.buttonStyle(.plain)
	}

	/// A capsule of glass over a gradient, drawn at this row's level — the
	/// transparency reads immediately because colour is behind it.
	private var _preview: some View {
		ZStack {
			LinearGradient(
				colors: [Color(bsLight: 0x0088FF, bsDark: 0x0091FF),
						 Color(bsLight: 0xCB30E0, bsDark: 0xDB34F2),
						 Color(bsLight: 0xFF8D28, bsDark: 0xFF9230)],
				startPoint: .topLeading, endPoint: .bottomTrailing
			)
			Rectangle().fill(.clear).frame(width: 44, height: 26)
				.background(
					RoundedRectangle(cornerRadius: 13, style: .continuous)
						.fill(BSSurface.glassFill(at: level))
				)
				.overlay(
					RoundedRectangle(cornerRadius: 13, style: .continuous)
						.strokeBorder(BSSurface.rim, lineWidth: 0.6)
				)
		}
		.frame(width: 44, height: 26)
		.clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
	}
}
