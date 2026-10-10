//
//  InstallationView.swift
//  Feather
//
//  Created by samara on 3.06.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct InstallationView: View {
	@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0

	private let _installationMethods: [String] = [
		.localized("Batline")
	]
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Installation")) {
			Section {
				Picker(.localized("Installation Type"), systemImage: "arrow.down.app", selection: $_installationMethod) {
					ForEach(_installationMethods.indices, id: \.description) { index in
						Text(_installationMethods[index]).tag(index)
					}
				}
			}
			
			if _installationMethod == 0 {
				ServerView()
			}
		}
		.onAppear {
			// Older installs may have persisted the removed idevice option.
			// Normalize them to the only supported choice so the settings do not
			// open with an unmatched Picker selection or an empty content area.
			if _installationMethod != 0 {
				_installationMethod = 0
			}
		}
		.animation(.smooth, value: _installationMethod)
	}
}
