//
//  BSAppearanceTransition.swift
//  Feather
//
//  The one thing a light/dark switch cannot do by itself: move.
//
//  Every colour in this app is semantic — `Color(uiColor:)`, `systemBackground`,
//  the measured storefront palette — so the change of appearance is a change of
//  *trait*, not of a value SwiftUI can interpolate. Assigning the style
//  therefore swaps every surface in the same frame: correct, instant, and a hard
//  cut. There is no animation to speed up because none was ever possible.
//
//  What makes it read as smooth is a cross-fade, and the only honest way to
//  cross-fade two trait states is to hold the old one still while the new one
//  lands underneath it. That is what this does: one snapshot of the window,
//  taken before the new style is applied, laid over the window and faded out.
//
//  It is a snapshot of the *window* and not of a view, so it covers every
//  surface at once — the tab bar, the sheets, the navigation bar, the toolbar's
//  glass — and it is non-interactive, so a tap during the fade still reaches the
//  control it was aimed at.
//

import SwiftUI
import UIKit

/// The user's appearance choice, written the one way.
///
/// One key, one write, one place that knows a write is also a change of
/// appearance: the picker in Settings and anything else that ever sets this go
/// through here, so the fade cannot be left out of a path that forgot it.
///
/// The key is the one the app has always used, and the value is
/// `UIUserInterfaceStyle`'s own raw value — `unspecified` being "Default",
/// which means "follow the iPhone".
enum BSAppearanceStyle {
	static let key = "Feather.userInterfaceStyle"

	static var stored: Int {
		get {
			UserDefaults.standard.object(forKey: key) as? Int
				?? UIUserInterfaceStyle.unspecified.rawValue
		}
		set {
			BSAppearanceTransition.crossfade()
			UserDefaults.standard.set(newValue, forKey: key)
		}
	}

	/// The same choice in SwiftUI's vocabulary. Nil is the system's, which SwiftUI
	/// treats exactly as UIKit treats `.unspecified`.
	static var colorScheme: SwiftUI.ColorScheme? {
		switch UIUserInterfaceStyle(rawValue: stored) ?? .unspecified {
		case .light: return .light
		case .dark: return .dark
		default: return nil
		}
	}
}

enum BSAppearanceTransition {
	/// How long the old appearance takes to leave. Short enough to feel like a
	/// response to the tap rather than a scene change, long enough to read as a
	/// fade rather than as a flicker.
	static let duration: TimeInterval = 0.28

	/// Cross-fades the window over the appearance change the caller is about to
	/// make. Call it *before* the stored style is written; the snapshot has to be
	/// of the appearance being left behind.
	///
	/// Silently does nothing when there is no window to draw on, which is the
	/// only failure that matters and is indistinguishable from a switch that
	/// happened too fast to see.
	static func crossfade() {
		// Reduce Motion is a request for fewer transitions, not for a fancier
		// one: the switch stays instant, as it was.
		guard !UIAccessibility.isReduceMotionEnabled else { return }

		guard let window = _window(),
			  let snapshot = window.snapshotView(afterScreenUpdates: false)
		else { return }

		snapshot.frame = window.bounds
		snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		snapshot.isUserInteractionEnabled = false
		// Above everything the window is showing, including the navigation bar
		// and any sheet already presented in it.
		window.addSubview(snapshot)

		// The next pass of the run loop, because the caller has not applied the
		// new style yet when this returns: the state change and this fade are the
		// same turn of the main actor, and the fade has to start on a screen that
		// already shows the other half of it.
		DispatchQueue.main.async {
			UIView.animate(
				withDuration: duration,
				delay: 0,
				options: [.curveEaseInOut, .allowUserInteraction]
			) {
				snapshot.alpha = 0
			} completion: { _ in
				snapshot.removeFromSuperview()
			}
		}
	}

	/// The window the user is looking at.
	///
	/// Key first, because that is the one being drawn; the first connected
	/// scene's window after that, for the moment during a launch or a rotation
	/// when nothing has claimed the key yet.
	private static func _window() -> UIWindow? {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		for scene in scenes {
			if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
		}
		return scenes.flatMap(\.windows).first
	}
}
