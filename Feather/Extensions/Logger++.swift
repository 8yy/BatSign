//
//  Logger++.swift
//  Feather
//
//  Created by samara on 24.05.2025.
//

import OSLog

extension Logger {
	private static var subsystem = Bundle.main.bundleIdentifier!
	static let signing = Logger(subsystem: subsystem, category: "Signing")
	static let misc = Logger(subsystem: subsystem, category: "Misc")
	/// Store writes. A failed save is a Library that does not match what is on
	/// disk, which is worth being able to see after the fact.
	static let storage = Logger(subsystem: subsystem, category: "Storage")
	/// The install popups. Whether one was allowed to arrive, and whether it
	/// did, is otherwise invisible from inside the app.
	static let notify = Logger(subsystem: subsystem, category: "Notify")
}
