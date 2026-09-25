//
//  TabbarView.swift
//  feather
//
//  Created by samara on 23.03.2025.
//

import SwiftUI

struct TabbarView: View {
	@State private var selectedTab: TabEnum = TabEnum(rawValue: UserDefaults.standard.string(forKey: "BatSign.defaultTab") ?? "") ?? .today

	init() {
		// Below iOS 26 the bar is drawn by UIKit appearances, so the iOS 27
		// glass recipe — the level's material and fill — is handed to it here.
		// On 26+ the system's floating glass bar is already the real surface,
		// and an appearance object would replace the glass with flat colours,
		// so it is deliberately not touched there.
		BSSurfaceTabBar.apply()
	}

	var body: some View {
		TabView(selection: $selectedTab) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				TabEnum.view(for: tab)
					.tabItem {
						Label(tab.title, systemImage: tab.icon)
					}
					.tag(tab)
			}
		}
		// The bar's selection is type, not colour: everything else on the app's
		// ground is neutral, and one blue label under the bar read as the only
		// coloured thing on the screen. The storefront's GET is not affected:
		// it paints its own blue, which is the one place blue means something.
		.tint(BS.tabTint)
	}
}
