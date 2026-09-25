//
//  ArchiveHandler.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation
import UIKit.UIApplication
import Zip
import SwiftUI
import IDeviceSwift

final class ArchiveHandler: NSObject {
	@ObservedObject var viewModel: InstallerStatusViewModel
	
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private var _payloadUrl: URL?
	
	private var _app: AppInfoPresentable
	private let _uniqueWorkDir: URL
	
	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.viewModel = viewModel
		self._app = app
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("FeatherInstall_\(_uuid)", isDirectory: true)
		
		super.init()
	}
	
	func move() async throws {
		guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
			throw SigningFileHandlerError.appNotFound
		}
		
		let payloadUrl = _uniqueWorkDir.appendingPathComponent("Payload")
		let movedAppURL = payloadUrl.appendingPathComponent(appUrl.lastPathComponent)

		try _fileManager.createDirectoryIfNeeded(at: payloadUrl)
		
		try _fileManager.copyItem(at: appUrl, to: movedAppURL)
		_payloadUrl = payloadUrl
	}
	
	func archive() async throws -> URL {
		return try await Task.detached(priority: .userInitiated) { [self] in
			guard let payloadUrl = await self._payloadUrl else {
				throw SigningFileHandlerError.appNotFound
			}
			
			let zipUrl = self._uniqueWorkDir.appendingPathComponent("Archive.zip")
			let ipaUrl = self._uniqueWorkDir.appendingPathComponent("Archive.ipa")
			
			try await Zip.zipFiles(
				paths: [payloadUrl],
				zipFilePath: zipUrl,
				password: nil,
				compression: ArchiveHandler.compression(),
				progress: { progress in
					Task { @MainActor in
						self.viewModel.packageProgress = progress
					}
				})
			
			try FileManager.default.moveItem(at: zipUrl, to: ipaUrl)
			return ipaUrl
		}.value
	}
	
	func moveToArchive(_ package: URL, shouldOpen: Bool = false) async throws -> URL? {
		// A package with no `CFBundleShortVersionString` — which is legal, and
		// which a partially imported record always has — used to trap here on the
		// way out of the share sheet. The name is a file name; it does not need to
		// be perfect, it needs to be there.
		let name = _app.name ?? "App"
		let version = _app.version ?? "1.0"
		let appendingString = "\(name)_\(version)_\(Int(Date().timeIntervalSince1970)).ipa"
		let dest = _fileManager.archives.appendingPathComponent(appendingString)

		// `try? removeItem` followed by `try moveItem` is not the same as a
		// replace: if the removal fails the move throws, and the archive is left
		// half-written with the old one gone.
		if _fileManager.fileExists(atPath: dest.path) {
			_ = try _fileManager.replaceItemAt(dest, withItemAt: package)
		} else {
			try _fileManager.createDirectoryIfNeeded(at: _fileManager.archives)
			try _fileManager.moveItem(at: package, to: dest)
		}

		if shouldOpen, let shared = _fileManager.archives.toSharedDocumentsURL() {
			await MainActor.run {
				UIApplication.open(shared)
			}
		}

		return dest
	}

	/// Throw away the working copy.
	///
	/// The archive built here is what the install server streams from, so this is
	/// only ever called once that stream is over. Left behind, every install in a
	/// session leaves a full copy of the package in the temporary directory.
	func clean() {
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}

	/// Set while a background signing pass is running: the package is thrown away
	/// straight after the install, so it is built at the lightest setting instead
	/// of whatever the user chose for packages they keep.
	static var fastestCompressionOverride: Bool = false

	static func compression() -> ZipCompression {
		if fastestCompressionOverride { return CompressionMode.speed.zip }
		return CompressionMode.stored.zip
	}
}

