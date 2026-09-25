//
//  ArchiveView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import Zip
import NimbleViews

// MARK: - View
struct ArchiveView: View {
	@AppStorage(CompressionMode.storageKey) private var _mode: Int = CompressionMode.stored.rawValue
	@AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = false

	private var _selected: CompressionMode {
		CompressionMode(rawValue: _mode) ?? .turbo
	}

	// MARK: Body
	var body: some View {
		NBList(.localized("Archive & Compression")) {
			Section {
				Picker(.localized("Compression"), systemImage: "archivebox", selection: $_mode) {
					ForEach(CompressionMode.pickerOrder) { mode in
						Text(mode.label).tag(mode.rawValue)
					}
				}
			} footer: {
				Text(_selected.detail)
			}

			Section {
				Toggle(.localized("Show Sheet when Exporting"), systemImage: "square.and.arrow.up", isOn: $_useShareSheet)
			} footer: {
				Text(.localized("Toggling show sheet will present a share sheet after exporting to your files."))
			}
		}
	}
}
