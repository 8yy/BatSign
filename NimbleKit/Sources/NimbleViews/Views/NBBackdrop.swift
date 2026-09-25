//
//  NBBackdrop.swift
//  NimbleViews
//
//  The ground behind a list screen.
//
//  Lists here hide their own scroll background, so something has to sit behind
//  them or the page goes flat. It used to be a navy gradient — which meant that
//  every screen built on `NBList` was a different colour from every screen that
//  was not, and pushing from one to the other changed the page's colour under
//  the user's finger. That is the whole bug this file exists to stop repeating.
//
//  So it is the system's own background, adaptive to the appearance, which is
//  the same ground the rest of the app draws on. One app, one backdrop.
//

import SwiftUI

public struct NBBackdrop: View {
	public init() {}

	public var body: some View {
		Color(uiColor: .systemBackground)
			.ignoresSafeArea()
	}
}
