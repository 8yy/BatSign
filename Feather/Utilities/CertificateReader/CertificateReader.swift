//
//  CertificateReader.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import UIKit
import OSLog

class CertificateReader: NSObject {
	let file: URL?
	var decoded: Certificate?
	
	init(_ file: URL?) {
		self.file = file
		super.init()
		self.decoded = self._readAndDecode()
	}
	
	/// Decode a certificate straight from memory — the same decoding the
	/// file-based init performs, for callers that already hold the bytes and
	/// have no file to read.
	static func parseData(_ data: Data) -> Certificate? {
		guard let xmlRange = data.range(of: Data("<?xml".utf8)) else {
			Logger.misc.error("XML start not found")
			return nil
		}

		let xmlData = data.subdata(in: xmlRange.lowerBound..<data.endIndex)

		do {
			let decoder = PropertyListDecoder()
			return try decoder.decode(Certificate.self, from: xmlData)
		} catch {
			Logger.misc.error("Error extracting certificate: \(error.localizedDescription)")
			return nil
		}
	}

	private func _readAndDecode() -> Certificate? {
		guard let file = file, let fileData = try? Data(contentsOf: file) else { return nil }
		return Self.parseData(fileData)
	}
}
