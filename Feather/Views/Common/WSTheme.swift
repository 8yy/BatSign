//
//  WSTheme.swift
//  Feather
//
//  Centralized design tokens. Every visual decision routes through
//  this file so the entire product stays coherent as it grows.
//

import SwiftUI

// MARK: - Spacing

enum WSSpacing {
	static let xs: CGFloat = 4
	static let sm: CGFloat = 8
	static let md: CGFloat = 12
	static let lg: CGFloat = 16
	static let xl: CGFloat = 20
	static let xxl: CGFloat = 28
	static let sectionGap: CGFloat = 30
	static let cardPadding: CGFloat = 14
	static let screenPadding: CGFloat = 16
}

// MARK: - Corner Radii

enum WSRadius {
	static let sm: CGFloat = 10
	static let md: CGFloat = 14
	static let lg: CGFloat = 20
	static let xl: CGFloat = 24
	static let capsule: CGFloat = 999

	static func continuous(_ r: CGFloat) -> RoundedRectangle {
		RoundedRectangle(cornerRadius: r, style: .continuous)
	}
}

// MARK: - Typography

enum WSType {
	static let heroTitle = Font.system(size: 34, weight: .bold)
	static let sectionTitle = Font.title2.weight(.bold)
	static let cardTitle = Font.headline
	static let cardSubtitle = Font.caption
	static let body = Font.subheadline
	static let micro = Font.caption2
	static let eyebrow = Font.footnote.weight(.bold)
}

// MARK: - Surfaces

enum WSSurface {
	static let background = BS.screen
	static let card = BS.cardFill
	static let cardFaded = BS.cardFill.opacity(0.6)
	static let input = BS.chipFill
}

// MARK: - Semantic Colors

enum WSSemantic {
	static let success = Color.green
	static let warning = Color.orange
	static let error = Color.red
	static let info = Color.blue
}

// MARK: - Empty State (unified across the app)

struct WSEmptyState: View {
	let icon: String
	let title: String
	let message: String

	var body: some View {
		// Editorial, the way the Sources and Today empty states are: the icon
		// and the words sit straight on the screen's own ground, with no card
		// or pane behind them.
		VStack(spacing: 12) {
			Image(systemName: icon)
				.font(.system(size: 34, weight: .regular))
				.foregroundStyle(BSStore.tertiary)
				.accessibilityHidden(true)

			Text(title)
				.font(.system(size: 20, weight: .bold, design: .rounded))

			Text(message)
				.font(.system(size: 14))
				.foregroundStyle(BSStore.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 24)
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 48)
	}
}

// MARK: - Section Header

