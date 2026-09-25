//
//  TabbarController.swift
//  feather
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import SwiftUI

@available(iOS 18, *)
struct ExtendedTabbarView: View {
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@AppStorage("Feather.tabCustomization") var customization = TabViewCustomization()
	@AppStorage("BatSign.defaultTab") private var _defaultTabRaw: String = TabEnum.today.rawValue
	@State private var _selection: TabEnum

	init() {
		let stored = UserDefaults.standard.string(forKey: "BatSign.defaultTab") ?? TabEnum.today.rawValue
		__selection = State(initialValue: TabEnum(rawValue: stored) ?? .today)
	}

	var body: some View {
		// The search-role tab is declared after the destinations, which is where
		// the system lifts it out of the bar and draws it as the separate lens —
		// BatSign's bar on iOS 26, owned by the platform rather than hand-drawn.
		TabView(selection: $_selection) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				Tab(tab.title, systemImage: tab.icon, value: tab) {
					TabEnum.view(for: tab)
						// The bar's tint is set below, on the `TabView` itself, because
						// that is the only place it reaches the bar. A tint set there is
						// in the environment every screen behind the bar inherits too,
						// so each destination restores the app's own accent for its own
						// subtree — toggles, pickers, progress rings, the sheets those
						// screens present, all of it stays exactly as it was, and only
						// the bar changes.
						.tint(.accentColor)
				}
			}

			Tab(TabEnum.search.title, systemImage: TabEnum.search.icon, value: TabEnum.search, role: .search) {
				TabEnum.view(for: .search)
					.tint(.accentColor)
			}
		}
		.tabViewStyle(.sidebarAdaptable)
		.tabViewCustomization($customization)
		// The bar's selection is type, not colour: everything else on the app's
		// dark ground is neutral, and one blue label under the bar read as the
		// only coloured thing on the screen. Tint is the only lever that reaches
		// this bar — `UITabBar.appearance()` (both the full appearance and the
		// two tint properties alone) was tried and ignored by it, and the full
		// appearance is the wrong tool anyway: it replaces the bar's background
		// and material, which throws away the system's glass.
		//
		// The storefront's GET is untouched: it paints `BSStore.blue` itself,
		// which is the store's own colour, the one place blue means something.
		.tint(BS.tabTint)
	}
}
