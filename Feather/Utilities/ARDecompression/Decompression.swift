//
//  Decompression.swift
//  feather
//
//  Created by samara on 21.08.2024.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import Foundation
import SWCompression
import Compression

func extractFile(at fileURL: inout URL) throws {
	let fileExtension = fileURL.pathExtension.lowercased()
	let fileManager = FileManager.default
	
	let decompressors: [String: (Data) throws -> Data] = [
		"xz": XZArchive.unarchive,
		"lzma": LZMA.decompress,
		"bz2": BZip2.decompress,
		"gz": GzipArchive.unarchive
	]
	
	if let decompressor = decompressors[fileExtension] {
		let outputURL = fileURL.deletingPathExtension()
		try decompressor(Data(contentsOf: fileURL)).write(to: outputURL)
		fileURL = outputURL
		return
	}
	
	if fileExtension == "tar" {
		let tarData = try Data(contentsOf: fileURL)
		let tarContainer = try TarContainer.open(container: tarData)
		
		let extractionDirectory = fileURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
		try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
		
		for entry in tarContainer {
			// a tar entry names its own path, and one that climbs out of the
			// directory we just made would be written somewhere else entirely
			guard !isUnsafeArchiveMember(entry.info.name, base: extractionDirectory) else {
				throw TweakHandlerError.unsafeArchiveMember(entry.info.name)
			}
			
			let entryPath = extractionDirectory.appendingPathComponent(entry.info.name)
			
			if entry.info.type == .directory {
				try fileManager.createDirectory(at: entryPath, withIntermediateDirectories: true)
			} else if entry.info.type == .regular, let entryData = entry.data {
				// an archive is not obliged to carry a record for every directory
				// its files live in, and a file written into one that was never
				// made fails — so the path is laid down before the file is
				try fileManager.createDirectory(
					at: entryPath.deletingLastPathComponent(),
					withIntermediateDirectories: true
				)
				try entryData.write(to: entryPath)
			}
		}
		
		fileURL = extractionDirectory
		return
	}
	
	throw TweakHandlerError.unsupportedFileExtension(fileExtension)
}
