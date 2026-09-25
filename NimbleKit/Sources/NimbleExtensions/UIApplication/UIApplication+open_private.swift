//
//  UIApplication+open.swift
//  Feather
//
//  Created by samara on 21.04.2025.
//

import UIKit.UIApplication

extension UIApplication {
	/// Opens an app with an identifier
	/// - Parameter identifier: Application identifier
	nonisolated static public func openApp(with identifier: String) {
		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" 			// LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="     			// defaultWorkspace
		let openSelectorBase64 = "b3BlbkFwcGxpY2F0aW9uV2l0aEJ1bmRsZUlEOg==" // openApplicationWithBundleID:
		
		guard
			let classNameData = Data(base64Encoded: classNameBase64),
			let defaultSelectorData = Data(base64Encoded: defaultSelectorBase64),
			let openSelectorData = Data(base64Encoded: openSelectorBase64),
			let className = String(data: classNameData, encoding: .utf8),
			let defaultSelector = String(data: defaultSelectorData, encoding: .utf8),
			let openSelector = String(data: openSelectorData, encoding: .utf8)
		else {
			return
		}
		
		guard
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue()
		else {
			return
		}
		
		_ = workspace.perform(NSSelectorFromString(openSelector), with: identifier)
	}
	
	/// Where the installed app for a bundle identifier lives, or nil when the
	/// device has none, or will not say.
	///
	/// A path answers the same for whatever build happens to be sitting there,
	/// which is why it is no longer trusted on its own — see
	/// ``installedApplication(_:)``, which is where the build's own name is read
	/// and which is implemented by the runtime this app is measured against.
	/// This stays for runtimes that still answer it.
	nonisolated static public func installedBundlePath(_ identifier: String) -> String? {
		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" // LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="   // defaultWorkspace
		let urlSelectorBase64 = "VVJMRm9yQXBwbGljYXRpb25XaXRoQnVuZGxlSWRlbnRpZmllcjo=" // urlForApplicationWithBundleIdentifier:

		guard
			let className = String(data: Data(base64Encoded: classNameBase64)!, encoding: .utf8),
			let defaultSelector = String(data: Data(base64Encoded: defaultSelectorBase64)!, encoding: .utf8),
			let urlSelector = String(data: Data(base64Encoded: urlSelectorBase64)!, encoding: .utf8),
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue()
		else { return nil }

		guard let object = workspace as? NSObject else { return nil }

		let selector = NSSelectorFromString(urlSelector)
		guard object.responds(to: selector) else { return nil }

		// An object return, so `perform` is the right call here — unlike the
		// BOOL-returning probe next door, this one hands back a retained NSURL.
		guard let url = object.perform(selector, with: identifier)?.takeUnretainedValue() as? URL else {
			return nil
		}

		return url.path
	}

	/// What the system's own registry says about an app it has installed: the two
	/// numbers that name the build, and where that build lives.
	///
	/// This is the answer a reinstall needs, and the one every progress-shaped
	/// question gets wrong. "Is this bundle installed?" is true before, during and
	/// after an app already on the device is replaced, so a card that waits for it
	/// to stop being true waits forever; a *version* names a build, so "the version
	/// on the device is the one this job signed, and it was not before" can only be
	/// true of an install that has just happened.
	///
	/// Read from `LSApplicationProxy`, which is where LaunchServices keeps it.
	/// Measured on the runtime this app is built against: the workspace no longer
	/// implements `URLForApplicationWithBundleIdentifier:`, but it does implement
	/// `allInstalledApplications`, and each proxy in that list answers
	/// `bundleIdentifier`, `shortVersionString`, `bundleVersion` and `bundleURL`
	/// for the build that is actually on the device.
	///
	/// Two routes are tried, because neither is documented and the two are
	/// implemented on different versions: the proxy class's own
	/// `applicationProxyForIdentifier:`, and a scan of the installed list. A bundle
	/// the device does not have answers nil, which callers must read as *unknown*
	/// and never as *different*.
	public struct InstalledApplication {
		public let identifier: String
		/// `CFBundleShortVersionString` of the build on the device.
		public let version: String?
		/// `CFBundleVersion` of the build on the device.
		public let build: String?
		/// Where that build lives, when the system hands the path over.
		public let path: String?
		/// What the device calls the app on the Home Screen, when it says.
		public let name: String?

		public init(
			identifier: String,
			version: String?,
			build: String?,
			path: String?,
			name: String? = nil
		) {
			self.identifier = identifier
			self.version = version
			self.build = build
			self.path = path
			self.name = name
		}
	}

	nonisolated static public func installedApplication(_ identifier: String) -> InstalledApplication? {
		guard let proxy = _applicationProxy(for: identifier) else { return nil }

		return InstalledApplication(
			identifier: _string(proxy, _bundleIdentifierSelector) ?? identifier,
			version: _string(proxy, _shortVersionSelector),
			build: _string(proxy, _bundleVersionSelector),
			path: (proxy.perform(NSSelectorFromString(_bundleURLSelector))?.takeUnretainedValue() as? URL)?.path,
			name: _string(proxy, _localizedNameSelector)
		)
	}

	/// Every app the system will name, in one pass, or nil when it will not
	/// answer at all.
	///
	/// The difference between nil and an empty list is the whole reason this
	/// returns an optional. A device that will not hand over its registry is not
	/// a device with no apps, and a caller that reads the two the same way would
	/// report every app as missing. Measured on the runtime this app is built
	/// against: the workspace implements `allInstalledApplications` and hands
	/// back one proxy per installed app, so one call answers for the whole phone
	/// — which is what a status scan needs, and what asking bundle by bundle
	/// costs a cross-process round trip each.
	nonisolated static public func installedApplications() -> [InstalledApplication]? {
		guard let proxies = _installedApplications() else { return nil }

		return proxies.compactMap { proxy in
			guard let identifier = _string(proxy, _bundleIdentifierSelector), !identifier.isEmpty else {
				return nil
			}
			return InstalledApplication(
				identifier: identifier,
				version: _string(proxy, _shortVersionSelector),
				build: _string(proxy, _bundleVersionSelector),
				path: (proxy.perform(NSSelectorFromString(_bundleURLSelector))?.takeUnretainedValue() as? URL)?.path,
				name: _string(proxy, _localizedNameSelector)
			)
		}
	}

	/// Whether this process can be told, authoritatively, that a bundle is not
	/// installed.
	///
	/// `applicationIsInstalled:` answers `NO` both for "the device does not have
	/// it" and for "this process may not ask", and the two are not the same
	/// answer: one is a fact about the phone, the other is a fact about the
	/// workspace. Everything that concludes anything from an app being *absent*
	/// has to know which it was given.
	nonisolated static public func canReportInstallation() -> Bool {
		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" // LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="   // defaultWorkspace
		let installedSelectorBase64 = "YXBwbGljYXRpb25Jc0luc3RhbGxlZDo=" // applicationIsInstalled:

		guard
			let className = String(data: Data(base64Encoded: classNameBase64)!, encoding: .utf8),
			let defaultSelector = String(data: Data(base64Encoded: defaultSelectorBase64)!, encoding: .utf8),
			let installedSelector = String(data: Data(base64Encoded: installedSelectorBase64)!, encoding: .utf8),
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue() as? NSObject
		else { return false }

		return workspace.responds(to: NSSelectorFromString(installedSelector))
	}

	// MARK: - Reading the registry

	private static let _proxyClassName = "LSApplicationProxy"
	private static let _proxySelector = "applicationProxyForIdentifier:"
	private static let _bundleIdentifierSelector = "bundleIdentifier"
	private static let _shortVersionSelector = "shortVersionString"
	private static let _bundleVersionSelector = "bundleVersion"
	private static let _bundleURLSelector = "bundleURL"
	private static let _localizedNameSelector = "localizedName"

	/// The proxy for a bundle, by the runtime's own lookup and then by hand.
	///
	/// The lookup is a class method, so the message goes to the class object —
	/// which is an instance of the metaclass and finds the method there. Messaging
	/// the metaclass object instead looks up the wrong list, finds nothing, and
	/// reports a method the runtime plainly implements as missing.
	nonisolated private static func _applicationProxy(for identifier: String) -> NSObject? {
		if
			let proxyClass = NSClassFromString(_proxyClassName) as? NSObject.Type,
			class_getClassMethod(proxyClass, NSSelectorFromString(_proxySelector)) != nil,
			let proxy = proxyClass
				.perform(NSSelectorFromString(_proxySelector), with: identifier)?
				.takeUnretainedValue() as? NSObject
		{
			return proxy
		}

		return _installedApplications()?.first {
			_string($0, _bundleIdentifierSelector) == identifier
		}
	}

	/// Every proxy the system will hand over, or nil when it will not.
	nonisolated private static func _installedApplications() -> [NSObject]? {
		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" // LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="   // defaultWorkspace
		let allSelectorBase64 = "YWxsSW5zdGFsbGVkQXBwbGljYXRpb25z" // allInstalledApplications

		guard
			let className = String(data: Data(base64Encoded: classNameBase64)!, encoding: .utf8),
			let defaultSelector = String(data: Data(base64Encoded: defaultSelectorBase64)!, encoding: .utf8),
			let allSelector = String(data: Data(base64Encoded: allSelectorBase64)!, encoding: .utf8),
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue() as? NSObject,
			workspace.responds(to: NSSelectorFromString(allSelector))
		else { return nil }

		return workspace.perform(NSSelectorFromString(allSelector))?.takeUnretainedValue() as? [NSObject]
	}

	/// One string field, checked before it is asked for, and never returned empty.
	///
	/// Both halves matter. Asking a proxy for a selector it does not implement
	/// raises rather than answering nil, and an empty string is what this registry
	/// hands back for a field it has no value for — which, read as a value, would
	/// say a build's version had changed to nothing.
	nonisolated private static func _string(_ proxy: NSObject, _ name: String) -> String? {
		let selector = NSSelectorFromString(name)
		guard
			proxy.responds(to: selector),
			let value = proxy.perform(selector)?.takeUnretainedValue() as? String,
			!value.isEmpty
		else { return nil }

		return value
	}

	/// Returns install progress for a bundle identifier (0.0 – 1.0)
	/// - Parameters:
	///   - identifier: Bundle identifier
	///   - synchronous: Whether the call should block
	/// - Returns: Progress value if available
	nonisolated static public func installProgress(
		for identifier: String,
		makeSynchronous synchronous: Bool = true
	) -> Double? {

		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" // LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="   // defaultWorkspace
		let progressSelectorBase64 = "aW5zdGFsbFByb2dyZXNzRm9yQnVuZGxlSUQ6bWFrZVN5bmNocm9ub3VzOg==" // installProgressForBundleID:makeSynchronous:

		guard
			let className = String(data: Data(base64Encoded: classNameBase64)!, encoding: .utf8),
			let defaultSelector = String(data: Data(base64Encoded: defaultSelectorBase64)!, encoding: .utf8),
			let progressSelector = String(data: Data(base64Encoded: progressSelectorBase64)!, encoding: .utf8),
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue()
		else { return nil }

		let result = workspace.perform(
			NSSelectorFromString(progressSelector),
			with: identifier,
			with: synchronous
		)?.takeUnretainedValue()

		if let number = result as? Progress {
			return number.fractionCompleted
		}

		return nil
	}

	/// Whether this device already has an app with the given bundle identifier.
	///
	/// The system's own answer, asked of the same workspace that installs the
	/// package. Nothing else can answer it: a progress object that stopped
	/// reporting is ambiguous — it might have finished, it might never have
	/// started — so a surface that offers "Open" has to be told, not guess.
	///
	/// The selector is checked before it is used, because asking an object for
	/// a selector it does not implement raises rather than returning nil.
	nonisolated static public func isInstalled(_ identifier: String) -> Bool {
		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ=="  // LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="    // defaultWorkspace
		let installedSelectorBase64 = "YXBwbGljYXRpb25Jc0luc3RhbGxlZDo=" // applicationIsInstalled:

		guard
			let className = String(data: Data(base64Encoded: classNameBase64)!, encoding: .utf8),
			let defaultSelector = String(data: Data(base64Encoded: defaultSelectorBase64)!, encoding: .utf8),
			let installedSelector = String(data: Data(base64Encoded: installedSelectorBase64)!, encoding: .utf8),
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue()
		else { return false }

		guard let object = workspace as? NSObject else { return false }

		let selector = NSSelectorFromString(installedSelector)
		guard object.responds(to: selector) else { return false }

		// `perform` is not usable here. The selector returns a C `BOOL`, and the
		// runtime hands that back boxed as a raw pointer — taking the "object"
		// out of it retains the number one and takes the process down. The
		// implementation is called directly instead, with the signature it
		// actually has.
		//
		//      - (BOOL)applicationIsInstalled:(NSString *)bundleIdentifier;
		typealias IsInstalled = @convention(c) (NSObject, Selector, NSString) -> ObjCBool
		let implementation = object.method(for: selector)
		let isInstalled = unsafeBitCast(implementation, to: IsInstalled.self)
		return isInstalled(object, selector, identifier as NSString).boolValue
	}
}
