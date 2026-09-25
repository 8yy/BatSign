//
//  SwiftAR.swift
//  SwiftAR
//
//  Created by nekohaxx on 8/18/24.
//

import Foundation

class AR: NSObject {
	private var _data: Data
	
	init(with url: URL) throws {
		self._data = try Data(contentsOf: url)
		super.init()
	}
	
	func extract() async throws -> [ARFileModel] {
		// the magic is 8 bytes wide, a file shorter than that is no archive
		guard _data.count >= 8 else {
			throw ARError.badArchive("Invalid magic")
		}
		
		if [UInt8](_data.subdata(in: Range(0...7))) != [0x21, 0x3c, 0x61, 0x72, 0x63, 0x68, 0x3e, 0x0a] {
			throw ARError.badArchive("Invalid magic")
		}
		
		let data = _data.subdata(in: 8..<_data.endIndex)
		
		var offset = 0
		var files: [ARFileModel] = []
		while offset < data.count {
			let fileInfo = try _getFileInfo(data, offset)
			files.append(fileInfo)
			offset += fileInfo.size + 60
			offset += offset % 2
		}
		return files
	}
	
	private func _getFileInfo(_ data: Data, _ offset: Int) throws -> ARFileModel {
		// every field sits at a fixed spot inside the 60 byte header, so the
		// header has to be there in full before any of them can be read
		guard offset >= 0, offset <= data.count, data.count - offset >= 60 else {
			throw ARError.badArchive("Invalid header offset")
		}
		
		guard let size = _int(_field(data, at: offset + 48, length: 10)) else {
			throw ARError.badArchive("Invalid size")
		}
		if size < 1 {
			throw ARError.badArchive("Invalid size")
		}
		
		let name = _removePadding(_field(data, at: offset, length: 16))
		guard name != "" else {
			throw ARError.badArchive("Invalid name")
		}
		
		guard
			let modificationDate = _double(_field(data, at: offset + 16, length: 12)),
			let ownerId = _int(_field(data, at: offset + 28, length: 6)),
			let groupId = _int(_field(data, at: offset + 34, length: 6)),
			let mode = _int(_field(data, at: offset + 40, length: 8))
		else {
			throw ARError.badArchive("Invalid header field")
		}
		
		// the size comes out of the archive, so the content has to be proven to
		// fit before it can be sliced out (size is at least 1 here, and the
		// subtraction stays in bounds because of the header guard above)
		guard size <= data.count - offset - 60 else {
			throw ARError.badArchive("Truncated content")
		}
		
		return ARFileModel(
			name: name,
			modificationDate: NSDate(timeIntervalSince1970: modificationDate) as Date,
			ownerId: ownerId,
			groupId: groupId,
			mode: mode,
			size: size,
			content: data.subdata(in: offset+60..<offset+60+size)
		)
	}
	
	// an ar field is ascii text, anything that does not decode is no value
	private func _field(_ data: Data, at offset: Int, length: Int) -> String {
		guard offset >= 0, length >= 0, offset + length <= data.count else {
			return ""
		}
		
		return String(data: data.subdata(in: offset..<offset+length), encoding: .ascii) ?? ""
	}
	
	private func _int(_ text: String) -> Int? {
		Int(_removePadding(text))
	}
	
	private func _double(_ text: String) -> Double? {
		guard let value = Double(_removePadding(text)), value.isFinite else {
			return nil
		}
		
		return value
	}
	
	// the fields are padded with spaces, which are not part of the value
	private func _removePadding(_ paddedString: String) -> String {
		guard let data = paddedString.data(using: .utf8) else {
			return paddedString
		}
		
		guard let firstNonSpaceIndex = data.firstIndex(of: UInt8(ascii: " ")) else {
			return paddedString
		}
		
		let actualData = data[..<firstNonSpaceIndex]
		return String(data: actualData, encoding: .utf8) ?? ""
	}
}

enum ARError: Error, LocalizedError {
	case badArchive(String)

	/// The associated string is this file's own diagnosis ("Invalid magic",
	/// "Truncated content") and is kept out of the sentence the user reads: what
	/// matters to them is that the file is not usable, not which field of its
	/// header was wrong.
	var errorDescription: String? {
		"The .deb is not a readable archive — the file may be damaged or truncated."
	}
}
