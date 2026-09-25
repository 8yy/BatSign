//
//  CompressionMode.swift
//  Feather
//
//  How an app is packaged before it is handed to iOS.
//
//  Three things were wrong with the old preference and they all pointed the
//  same way: the picker tagged its rows with `ZipCompression` while its
//  selection was an `Int`, so a choice never had a matching tag and never
//  stuck; the archiver then indexed a fixed array with that number and clamped
//  it to at most 1, so even a choice that did stick was rewritten to "Speed";
//  and "Best" was consequently unreachable. This type is the single place the
//  decision lives, typed end to end — picker, storage and archiver all speak
//  the same values.
//

import Foundation
import Zip

/// A packaging preset. The raw value is the stored preference.
enum CompressionMode: Int, CaseIterable, Identifiable {
	/// Maximum deflate (zlib level 9). Smallest package, slowest to build.
	case turbo = 9
	/// zlib's own default (-1 = 6). The balanced middle.
	case balanced = -1
	/// Minimum deflate (level 1). Quickest to build, largest package.
	case speed = 1
	/// Store, no deflate at all.
	case none = 0

	var id: Int { rawValue }

	var label: String {
		switch self {
		case .turbo: 	return .localized("Turbo")
		case .balanced: return .localized("Balanced")
		case .speed: 	return .localized("Speed")
		case .none: 	return .localized("None")
		}
	}

	/// One line per mode, used under the picker so the trade-off is explicit.
	var detail: String {
		switch self {
		case .turbo:
			return .localized("Maximum compression. The smallest package there is, so the least to transfer and the quickest install — packaging takes the longest.")
		case .balanced:
			return .localized("zlib's default. A sensible package size without a long wait.")
		case .speed:
			return .localized("Lightest compression. Packaged almost instantly, noticeably larger.")
		case .none:
			return .localized("No compression at all. Only useful for already-compressed payloads.")
		}
	}

	/// What the archiver asks the zip library for.
	var zip: ZipCompression {
		switch self {
		case .turbo: 	return .BestCompression
		case .balanced: return .DefaultCompression
		case .speed: 	return .BestSpeed
		case .none: 	return .NoCompression
		}
	}

	/// The order the picker shows: best package first, because that is the one
	/// worth reaching for.
	static var pickerOrder: [CompressionMode] {
		[.turbo, .balanced, .speed, .none]
	}

	// MARK: - Storage

	static let storageKey = "Feather.compressionMode"
	private static let legacyLevelKey = "Feather.compressionLevel"

	/// The chosen mode, migrating the old index-based preference if that is all
	/// there is. Turbo is the default: a signed IPA is what gets transferred and
	/// installed, so making it as small as possible is the setting that pays.
	static var stored: CompressionMode {
		get {
			let defaults = UserDefaults.standard

			if let raw = defaults.object(forKey: storageKey) as? Int,
			   let mode = CompressionMode(rawValue: raw) {
				return mode
			}

			if defaults.object(forKey: legacyLevelKey) != nil {
				let migrated: CompressionMode
				switch defaults.integer(forKey: legacyLevelKey) {
				case 0: migrated = .none
				case 1: migrated = .speed
				case 2: migrated = .balanced
				default: migrated = .turbo
				}
				defaults.set(migrated.rawValue, forKey: storageKey)
				return migrated
			}

			return .turbo
		}
		set {
			UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
		}
	}
}
