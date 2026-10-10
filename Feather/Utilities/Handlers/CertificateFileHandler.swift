//
//  CertificateFileHandler.swift
//  Feather
//
//  Created by samara on 15.04.2025.
//

import Foundation
import OSLog

final class CertificateFileHandler: NSObject {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	
	private let _key: URL
	private let _provision: URL
	private let _keyPassword: String?
	private let _certNickname: String?
	private let _isDefault: Bool
	
	private var _certPair: Certificate?
	
	init(
		key: URL,
		provision: URL,
		password: String? = nil,
		nickname: String? = nil,
		isDefault: Bool = false
	) {
		self._key = key
		self._provision = provision
		self._keyPassword = password
		self._certNickname = nickname
		self._isDefault = isDefault
		
		_certPair = CertificateReader(provision).decoded
		
		super.init()
	}
	
	func copy() async throws {
		guard
			(_certPair != nil)
		else {
			throw CertificateFileHandlerError.certNotValid
		}
		
		let destinationURL = try await _directory()
		try _fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
		do {
			try _fileManager.copyItem(at: _key, to: destinationURL.appendingPathComponent(_key.lastPathComponent))
			try _fileManager.copyItem(at: _provision, to: destinationURL.appendingPathComponent(_provision.lastPathComponent))
		} catch {
			try? _fileManager.removeItem(at: destinationURL)
			throw error
		}
	}
	
	func addToDatabase() async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			Task { @MainActor in
				Storage.shared.addCertificate(
					uuid: _uuid,
					password: _keyPassword,
					nickname: _certNickname,
					ppq: _certPair?.PPQCheck ?? false,
					expiration: _certPair?.ExpirationDate ?? Date(),
					isDefault: _isDefault
				) { error in
					if let error {
						try? self._fileManager.removeItem(at: self._fileManager.certificates(self._uuid))
						continuation.resume(throwing: error)
					} else {
						Logger.misc.info("[\(self._uuid)] Added to database")
						continuation.resume()
					}
				}
			}
		}
	}
	
	private func _directory() async throws -> URL {
		// Documents/Feather/Certificates/\(UUID)
		_fileManager.certificates(_uuid)
	}
}

private enum CertificateFileHandlerError: Error {
	case certNotValid
}
