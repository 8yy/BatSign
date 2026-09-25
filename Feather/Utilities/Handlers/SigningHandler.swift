//
//  SigningHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import Foundation
import Zsign
import UIKit
import OSLog

final class SigningHandler: NSObject {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private var _movedAppPath: URL?
	// using uuid string is the best way to find the
	// app we want to sign, it does not matter what
	// type of app it is
	private let _target: SigningTarget
	private var _options: Options
	private let _uniqueWorkDir: URL
	// the options struct is not gonna decode these so
	// we're just going to do this. If appicon is not
	// specified, we're not going to modify the app
	// icon. If the cert pair is not there, fallback
	// to adhoc signing (if the option is on, otherwise
	// throw an error
	//
	// The certificate object is kept only for the Library write, which is made on
	// the main actor — everything the signing pipeline reads from it was copied
	// into `_target.certificate` before that pipeline started.
	private let _certificate: CertificatePair?
	var appIcon: UIImage?

	/// Where the work has got to, for the surfaces that report it.
	///
	/// Signing is minutes of in-process CPU work with nothing of its own to
	/// report — no bytes, no fraction — and the live card is the one place the
	/// user is watching it. Without this the card says one word for the whole of
	/// it, which is indistinguishable from a card that has stopped: "it parks on
	/// Signing". The three stages below are the three things the pipeline really
	/// does, in the order it does them, and they are told as they begin.
	///
	/// Called on whatever thread the pipeline is on.
	enum Stage: String {
		/// Reading the app out of the Library into a work directory.
		case preparing
		/// Rewriting the bundle: identity, icon, plugins, injection, slice fixups.
		case modifying
		/// Handing the rewritten bundle to the signer.
		case sealing
		/// Moving the signed bundle into `Signed/` and writing its Library row.
		case finishing

		/// What the live card says while this stage is running.
		var detail: String {
			switch self {
			case .preparing: return "Preparing the package"
			case .modifying: return "Modifying the app"
			case .sealing: return "Sealing the signature"
			case .finishing: return "Finishing up"
			}
		}
	}

	var onStage: (@Sendable (Stage) -> Void)?
	
	/// Main-actor bound, because `app` and `certificate` are `viewContext`
	/// objects: this is where every value the detached pipeline needs is read out
	/// of them. Nothing below ever touches either object again except
	/// `addToDatabase`, which does so on the main actor.
	@MainActor
	init(
		app: AppInfoPresentable,
		certificate: CertificatePair?,
		options: Options = OptionsManager.shared.options
	) {
		self._target = SigningTarget(app: app, certificate: certificate)
		self._certificate = certificate
		self._options = options
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("FeatherSigning_\(_uuid)", isDirectory: true)
		super.init()
	}
	
	func copy() async throws {
		guard let appUrl = _target.appDirectory else {
			throw SigningFileHandlerError.appNotFound
		}

		onStage?(.preparing)
		try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)
		
		let movedAppURL = _uniqueWorkDir.appendingPathComponent(appUrl.lastPathComponent)
		
		try _fileManager.copyItem(at: appUrl, to: movedAppURL)
		_movedAppPath = movedAppURL
		Logger.misc.info("[\(self._uuid)] Moved Payload to: \(movedAppURL.path)")
	}
	
	func modify() async throws {
		guard let movedAppPath = _movedAppPath else {
			throw SigningFileHandlerError.appNotFound
		}

		onStage?(.modifying)
		
		// `NSDictionary(contentsOf:)` is failable — it returns nil for a plist that
		// is missing, empty, binary or simply not a plist — and this used to be
		// force-unwrapped inside a `guard`, so the crash came before the guard
		// could throw. A malformed package in the Library is exactly what a
		// background re-sign is handed, which made that a crash with no user
		// action behind it.
		guard
			let storedInfo = NSDictionary(
				contentsOf: movedAppPath.appendingPathComponent("Info.plist")
			),
			let infoDictionary = storedInfo.mutableCopy() as? NSMutableDictionary
		else {
			throw SigningFileHandlerError.infoPlistNotFound
		}
		
		if
			let identifier = _options.appIdentifier,
			let oldIdentifier = infoDictionary["CFBundleIdentifier"] as? String
		{
			try await _modifyPluginIdentifiers(old: oldIdentifier, new: identifier, for: movedAppPath)
		}
		
		try await _modifyDict(using: infoDictionary, with: _options, to: movedAppPath)
		
		if let icon = appIcon {
			try await _modifyDict(using: infoDictionary, for: icon, to: movedAppPath)
		}
		
		if let name = _options.appName {
			try await _modifyLocalesForName(name, for: movedAppPath)
		}
		
		if !_options.removeFiles.isEmpty {
			try await _removeFiles(for: movedAppPath, from: _options.removeFiles)
		}
		
		try await _removePresetFiles(for: movedAppPath)
		try await _removeWatchIfNeeded(for: movedAppPath)
		
		if _options.experiment_supportLiquidGlass {
			try await _locateMachosAndChangeToSDK26(for: movedAppPath)
		}
		
		if _options.experiment_replaceSubstrateWithEllekit {
			try await _inject(for: movedAppPath, with: _options)
		} else {
			if !_options.injectionFiles.isEmpty {
				try await _inject(for: movedAppPath, with: _options)
			}
		}
		
		// iOS "26" (19) needs special treatment
		try await _locateMachosAndFixupArm64eSlice(for: movedAppPath)
		
		let handler = ZsignHandler(appUrl: movedAppPath, options: _options, certificate: _target.certificate)
		try await handler.disinject()

		// The signer itself, and the longest single step of the pipeline.
		onStage?(.sealing)
		
		if
			_options.signingOption == .default,
			_target.certificate != nil
		{
			try await handler.sign()
//		} else if _options.signingOption == .adhoc {
//			try await handler.adhocSign()
		} else if _options.signingOption == .onlyModify {
			//
		} else {
			throw SigningFileHandlerError.missingCertifcate
		}
		
		do {
			try await self.move()
			try await self.addToDatabase()
		} catch {
			// By the time either of these can fail the bundle has left the work
			// directory, so `clean()` — which sweeps that directory — has nothing
			// left to remove. Whatever is at the destination is a half-finished
			// signing that no Library row points at, and it goes with the error
			// rather than sitting in `Signed/` for ever.
			if let destination = try? await _directory() {
				try? _fileManager.removeFileIfNeeded(at: destination)
			}

			throw error
		}

		if let error = handler.hadError {
			throw error
		}
	}
	
	func move() async throws {
		guard let movedAppPath = _movedAppPath else {
			throw SigningFileHandlerError.appNotFound
		}
		
		var destinationURL = try await _directory()
		
		try _fileManager.createDirectoryIfNeeded(at: destinationURL)
		
		destinationURL = destinationURL.appendingPathComponent(movedAppPath.lastPathComponent)

		onStage?(.finishing)
		
		try _fileManager.moveItem(at: movedAppPath, to: destinationURL)
		Logger.misc.info("[\(self._uuid)] Moved App to: \(destinationURL.path)")
		
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}
	
	func addToDatabase() async throws {
		let app = try await _directory()

		// A signed bundle that cannot be found is a failure, not an early exit.
		//
		// Returning here reported success for an app that was never written to
		// the Library: the row never appeared, the completion was called with
		// nil, the island went green and the only trace of the app was a
		// directory sitting in `Signed/<uuid>` that nothing pointed at.
		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			throw SigningFileHandlerError.appNotFound
		}
		
		let bundle = Bundle(url: appUrl)
		let appName = bundle?.name
		let appIdentifier = bundle?.bundleIdentifier
		let appVersion = bundle?.version
		let appIcon = bundle?.iconFileName
		
		// The Library row is a main-queue write, and it is made from values copied
		// out before this detached task started — neither the app nor the
		// certificate object is read from here.
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			Task { @MainActor in
				Storage.shared.addSigned(
					uuid: self._uuid,
					source: self._target.source,
					certificate: self._options.signingOption != .default ? nil : self._certificate,
					appName: appName,
					appIdentifier: appIdentifier,
					appVersion: appVersion,
					appIcon: appIcon
				) { _ in
					Logger.signing.info("[\(self._uuid)] Added to database")
					continuation.resume()
				}
			}
		}
		
		Storage.shared.copySourceMetadata(
			from: _target.uuid,
			to: _uuid,
			kind: .signed
		)
	}
	
	private func _directory() async throws -> URL {
		// Documents/Feather/Signed/\(UUID)
		_fileManager.signed(_uuid)
	}
	
	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
	}
}

extension SigningHandler {
	private func _modifyDict(using infoDictionary: NSMutableDictionary, with options: Options, to app: URL) async throws {
		if options.fileSharing { infoDictionary.setObject(true, forKey: "UISupportsDocumentBrowser" as NSCopying) }
		if options.itunesFileSharing { infoDictionary.setObject(true, forKey: "UIFileSharingEnabled" as NSCopying) }
		if options.proMotion { infoDictionary.setObject(true, forKey: "CADisableMinimumFrameDurationOnPhone" as NSCopying) }
		if options.gameMode { infoDictionary.setObject(true, forKey: "GCSupportsGameMode" as NSCopying)}
		if options.ipadFullscreen { infoDictionary.setObject(true, forKey: "UIRequiresFullScreen" as NSCopying) }
		if options.removeURLScheme { infoDictionary.removeObject(forKey: "CFBundleURLTypes") }
		
		if options.appAppearance != .default {
			infoDictionary.setObject(options.appAppearance.rawValue, forKey: "UIUserInterfaceStyle" as NSCopying)
		}
		if options.minimumAppRequirement != .default {
			infoDictionary.setObject(options.minimumAppRequirement.rawValue, forKey: "MinimumOSVersion" as NSCopying)
		}
		
		if options.experiment_disableLiquidGlass { infoDictionary.setObject(true, forKey: "UIDesignRequiresCompatibility" as NSCopying) }
		if options.experiment_supportLiquidGlass { infoDictionary.setObject(false, forKey: "UIDesignRequiresCompatibility" as NSCopying) }
		
		// useless crap
		if infoDictionary["UISupportedDevices"] != nil {
			infoDictionary.removeObject(forKey: "UISupportedDevices")
		}
		
		// MARK: Prominant values
		
		if let customIdentifier = options.appIdentifier {
			infoDictionary.setObject(customIdentifier, forKey: "CFBundleIdentifier" as NSCopying)
		}
		if let customName = options.appName {
			infoDictionary.setObject(customName, forKey: "CFBundleDisplayName" as NSCopying)
			infoDictionary.setObject(customName, forKey: "CFBundleName" as NSCopying)
		}
		if let customVersion = options.appVersion {
			infoDictionary.setObject(customVersion, forKey: "CFBundleShortVersionString" as NSCopying)
			infoDictionary.setObject(customVersion, forKey: "CFBundleVersion" as NSCopying)
		}
		
		try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
	}
	
	private func _modifyDict(using infoDictionary: NSMutableDictionary, for image: UIImage, to app: URL) async throws {
		let imageSizes = [
			(width: 120, height: 120, name: "FRIcon60x60@2x.png"),
			(width: 152, height: 152, name: "FRIcon76x76@2x~ipad.png")
		]
		
		for imageSize in imageSizes {
			let resizedImage = image.resize(imageSize.width, imageSize.height)
			let imageData = resizedImage.pngData()
			let fileURL = app.appendingPathComponent(imageSize.name)
			
			try imageData?.write(to: fileURL)
		}
		
		let cfBundleIcons: [String: Any] = [
			"CFBundlePrimaryIcon": [
				"CFBundleIconFiles": ["FRIcon60x60"],
				"CFBundleIconName": "FRIcon"
			]
		]
		
		let cfBundleIconsIpad: [String: Any] = [
			"CFBundlePrimaryIcon": [
				"CFBundleIconFiles": ["FRIcon60x60", "FRIcon76x76"],
				"CFBundleIconName": "FRIcon"
			]
		]
		
		infoDictionary["CFBundleIcons"] = cfBundleIcons
		infoDictionary["CFBundleIcons~ipad"] = cfBundleIconsIpad
		
		try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
	}
	
	private func _modifyLocalesForName(_ name: String, for app: URL) async throws {
		let localizationBundles = try _fileManager
			.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "lproj" }
		
		localizationBundles.forEach { bundleURL in
			let plistURL = bundleURL.appendingPathComponent("InfoPlist.strings")
			
			guard
				_fileManager.fileExists(atPath: plistURL.path),
				let dictionary = NSMutableDictionary(contentsOf: plistURL)
			else {
				return
			}
			
			dictionary["CFBundleDisplayName"] = name
			dictionary.write(toFile: plistURL.path, atomically: true)
		}
	}
	
	private func _modifyPluginIdentifiers(
		old oldIdentifier: String,
		new newIdentifier: String,
		for app: URL
	) async throws {
		let pluginBundles = _enumerateFiles(at: app) {
			$0.hasSuffix(".app") || $0.hasSuffix(".appex")
		}
		
		for bundleURL in pluginBundles {
			let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
			
			guard let infoDict = NSDictionary(contentsOf: infoPlistURL)?.mutableCopy() as? NSMutableDictionary else {
				continue
			}
			
			var didChange = false
			
			// CFBundleIdentifier
			if let oldValue = infoDict["CFBundleIdentifier"] as? String {
				let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
				if oldValue != newValue {
					infoDict["CFBundleIdentifier"] = newValue
					didChange = true
				}
			}
			
			// WKCompanionAppBundleIdentifier
			if let oldValue = infoDict["WKCompanionAppBundleIdentifier"] as? String {
				let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
				if oldValue != newValue {
					infoDict["WKCompanionAppBundleIdentifier"] = newValue
					didChange = true
				}
			}
			if let extensionDict = (infoDict["NSExtension"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary {
				// NSExtension → NSExtensionAttributes → WKAppBundleIdentifier
				if
					let attributes = extensionDict["NSExtensionAttributes"] as? NSMutableDictionary,
					let oldValue = attributes["WKAppBundleIdentifier"] as? String
				{
					let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
					if oldValue != newValue {
						attributes["WKAppBundleIdentifier"] = newValue
						didChange = true
					}
				}
                
				// NSExtension → NSExtensionFileProviderDocumentGroup
				if
					let oldValue = extensionDict["NSExtensionFileProviderDocumentGroup"] as? String
				{
					let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
					if oldValue != newValue {
						extensionDict["NSExtensionFileProviderDocumentGroup"] = newValue
						didChange = true
					}
				}
                
				infoDict["NSExtension"] = extensionDict
			}
			
			if didChange {
				infoDict.write(to: infoPlistURL, atomically: true)
			}
		}
	}
	
	private func _removePresetFiles(for app: URL) async throws {
		var files = [
			"_CodeSignature", // Fallbaccck for some reason the locate doesnt work
			"embedded.mobileprovision", // Remove this because zsign doesn't replace it
			"com.apple.WatchPlaceholder", // Useless
			"SignedByEsign" // Useless
		].map {
			app.appendingPathComponent($0)
		}
		
		await files += try _locateCodeSignatureDirectories(for: app)
		
		for file in files {
			try _fileManager.removeFileIfNeeded(at: file)
		}
	}
	
	// horrible edge-case
	private func _removeWatchIfNeeded(for app: URL) async throws {
		let watchDir = app.appendingPathComponent("Watch")
		guard _fileManager.fileExists(atPath: watchDir.path) else { return }
		
		let contents = try _fileManager.contentsOfDirectory(at: watchDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
		
		for app in contents where app.pathExtension == "app" {
			let infoPlist = app.appendingPathComponent("Info.plist")
			if !_fileManager.fileExists(atPath: infoPlist.path) {
				try? _fileManager.removeItem(at: app)
			}
		}
	}
	
	private func _removeFiles(for app: URL, from appendingComponent: [String]) async throws {
		let filesToRemove = appendingComponent.map {
			app.appendingPathComponent($0)
		}
		
		for url in filesToRemove {
			try _fileManager.removeFileIfNeeded(at: url)
		}
	}
	
	private func _inject(for app: URL, with options: Options) async throws {
		let handler = TweakHandler(app: app, options: options)
		try await handler.getInputFiles()
	}
	
	private func _locateMachosAndChangeToSDK26(for app: URL) async throws {
		if let url = Bundle(url: app)?.executableURL {
			LCPatchMachOForSDK26(app.appendingPathComponent(url.relativePath).relativePath)
		}
	}
	
	private func _locateCodeSignatureDirectories(for app: URL) async throws -> [URL] {
		_enumerateFiles(at: app) { $0.hasSuffix("_CodeSignature") }
	}
	
	private func _locateMachosAndFixupArm64eSlice(for app: URL) async throws {
		let machoFiles = _enumerateFiles(at: app) {
			$0.hasSuffix(".dylib") || $0.hasSuffix(".framework")
		}
		
		for fileURL in machoFiles {
			switch fileURL.pathExtension {
			case "dylib":
				LCPatchMachOFixupARM64eSlice(fileURL.path)
			case "framework":
				if
					let bundle = Bundle(url: fileURL),
					let execURL = bundle.executableURL
				{
					LCPatchMachOFixupARM64eSlice(execURL.path)
				}
			default:
				continue
			}
		}
	}
	
	private func _enumerateFiles(at base: URL, where predicate: (String) -> Bool) -> [URL] {
		guard let fileEnum = _fileManager.enumerator(atPath: base.path) else {
			return []
		}
		
		var results: [URL] = []
		
		while let file = fileEnum.nextObject() as? String {
			if predicate(file) {
				results.append(base.appendingPathComponent(file))
			}
		}
		
		return results
	}
}

// MARK: - Target

/// Everything the signing pipeline reads out of its `viewContext` inputs.
///
/// `AppInfoPresentable` and `CertificatePair` are managed objects owned by the
/// main queue, and the pipeline itself runs in a detached task — so every value
/// it needs is copied out on the main actor and only these values cross into
/// the task. Name, identifier and version are not here on purpose: the Library
/// row reads those from the signed bundle that was just built, not from the app
/// that was signed.
struct SigningTarget {
	let appDirectory: URL?
	let source: URL?
	let uuid: String?
	let certificate: SigningCertificate?
	
	@MainActor
	init(app: AppInfoPresentable, certificate: CertificatePair?) {
		self.appDirectory = Storage.shared.getAppDirectory(for: app)
		self.source = app.source
		self.uuid = app.uuid
		
		if let certificate {
			self.certificate = SigningCertificate(certificate: certificate)
		} else {
			self.certificate = nil
		}
	}
}

/// The certificate as zsign needs it: two paths and a password.
struct SigningCertificate {
	let provisionPath: String
	let certificatePath: String
	let password: String
	
	@MainActor
	init(certificate: CertificatePair) {
		self.provisionPath = Storage.shared.getFile(.provision, from: certificate)?.path ?? ""
		self.certificatePath = Storage.shared.getFile(.certificate, from: certificate)?.path ?? ""
		self.password = certificate.password ?? ""
	}
}

enum SigningFileHandlerError: Error, LocalizedError {
	case appNotFound
	case infoPlistNotFound
	case missingCertifcate
	case disinjectFailed
	case signFailed
	
	var errorDescription: String? {
		switch self {
		case .appNotFound: "Unable to locate bundle path."
		case .infoPlistNotFound: "Unable to locate info.plist path."
		case .missingCertifcate: "No certificate was specified."
		case .disinjectFailed: "Removing mach-O load paths failed."
	case .signFailed: "Signing failed."
		}
	}
}
