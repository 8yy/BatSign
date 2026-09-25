//
//  TabEnum.swift
//  feather
//
//  BatSign's bar: Today, Sources, Apps and Library, with Updates behind them and
//  the system's own separated search lens on the trailing edge. Settings is no
//  longer a tab — it opens from the gear in Today's top-right corner.
//

import SwiftUI
import NimbleViews

enum TabEnum: String, CaseIterable, Hashable {
	case today
	case sources
	case apps
	case library
	case updates
	case search

	var title: String {
		switch self {
		case .today: 	return .localized("Today")
		case .sources: 	return .localized("Sources")
		case .apps: 	return .localized("Apps")
		case .library: 	return .localized("Library")
		case .updates: 	return .localized("Updates")
		case .search: 	return .localized("Search")
		}
	}

	var icon: String {
		switch self {
		case .today: 	return "doc.text.image"
		case .sources: 	return "cart.fill"
		case .apps: 	return "square.grid.2x2.fill"
		case .library: 	return "square.stack.3d.up.fill"
		case .updates: 	return "arrow.triangle.2.circlepath"
		case .search: 	return "magnifyingglass"
		}
	}

	@ViewBuilder
	static func view(for tab: TabEnum) -> some View {
		switch tab {
		case .today: DiscoverView()
		case .sources: BSSourcesView()
		case .apps: BSAppsView()
		case .library: LibraryView()
		case .updates: UpdatesView()
		case .search: BSAppsView(title: "Search")
		}
	}

	/// Four destinations and the search lens, the way BatSign's bar is laid out.
	/// Updates is not on the bar: it opens from Today's own top-right corner, so
	/// the system keeps drawing the separate search lens instead of collapsing a
	/// fifth tab into a “More”.
	static var defaultTabs: [TabEnum] {
		return [
			.today,
			.sources,
			.apps,
			.library
		]
	}

	static var customizableTabs: [TabEnum] {
		return []
	}
}
