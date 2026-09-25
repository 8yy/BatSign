//
//  BSWorkspaceProbe.swift
//  Feather
//
//  Answers one question, on the machine it is asked on: *which* parts of
//  LSApplicationWorkspace will talk to this process, and what do they say?
//
//  The install watcher wants two things from the system — the version of the
//  build that is on the device, and the path that build lives at — because those
//  are the only answers that change when an existing app is replaced, and a
//  reinstall is the case every progress-shaped question gets wrong. The first
//  implementation asked for the path through
//  `URLForApplicationWithBundleIdentifier:` and got nothing back, on every
//  bundle, including the app asking.
//
//  Measured on an iOS 27 simulator, the answer to why is in the first three
//  lines this file prints: `URLForApplicationWithBundleIdentifier:` — and the
//  lowercased variant, and `applicationProxyForIdentifier:` — are **not
//  implemented** by the workspace any more. `applicationIsInstalled:` is, and so
//  is `allInstalledApplications`, which hands back one `LSApplicationProxy` per
//  installed app. The proxies are where the version strings live.
//
//  So this asks the whole surface at once — what the workspace implements, what
//  the proxy implements, and what each proxy says about a bundle — rather than
//  asking one selector and reading a nil as an answer. It is compiled into debug
//  builds only, and it is reached with `-lsprobe <bundle id>[,<bundle id>…]`.
//

#if DEBUG
import Foundation
import UIKit
import os

enum BSWorkspaceProbe {
	private static let log = Logger(subsystem: "app.batsign.ios", category: "lsprobe")

	/// What an installed app says about itself. The two numbers that name a build
	/// are the point; the rest is here so the log says whether the object is even
	/// the thing it is assumed to be.
	private static let proxyFields = [
		"bundleIdentifier",
		"shortVersionString",
		"bundleVersion",
		"bundleModTime",
		"bundleURL",
		"applicationType",
		"localizedName",
		"installProgress",
		"isInstalled"
	]

	static func run(_ identifiers: [String]) {
		guard let workspaceClass = NSClassFromString(
			String(data: Data(base64Encoded: "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==")!, encoding: .utf8)!
		) as? NSObject.Type else {
			log.notice("lsprobe: no LSApplicationWorkspace in this process")
			return
		}

		guard let workspace = workspaceClass.perform(
			NSSelectorFromString(
				String(data: Data(base64Encoded: "ZGVmYXVsdFdvcmtzcGFjZQ==")!, encoding: .utf8)!
			)
		)?.takeUnretainedValue() as? NSObject else {
			log.notice("lsprobe: no default workspace")
			return
		}

		log.notice("lsprobe: workspace is \(String(describing: type(of: workspace)), privacy: .public)")

		logMethods(of: workspaceClass, label: "LSApplicationWorkspace", matching: ["url", "bundle", "install", "application"])

		if let proxyClass = NSClassFromString("LSApplicationProxy") {
			logMethods(of: object_getClass(proxyClass)!, label: "LSApplicationProxy (class methods)", matching: ["identifier", "proxy"])
		logMethods(of: proxyClass, label: "LSApplicationProxy", matching: ["version", "bundle", "url", "install", "name", "type"])
		// The class object, not `object_getClass` of it. The metaclass object is
		// an instance of the *root* metaclass, so it is the wrong receiver for a
		// class method: the runtime throws `doesNotRecognizeSelector:` rather than
		// answering, which is how this line took the app down the first time it ran.
		logProxy(proxyClass, selector: "applicationProxyForIdentifier:", identifier: identifiers.first)
		} else {
			log.notice("lsprobe: no LSApplicationProxy class")
		}

		guard let all = workspace.perform(NSSelectorFromString("allInstalledApplications"))?
			.takeUnretainedValue() as? [NSObject] else {
			log.notice("lsprobe: allInstalledApplications answered nothing")
			return
		}

		log.notice("lsprobe: allInstalledApplications → \(all.count, privacy: .public) proxies")

		for identifier in identifiers {
			guard let proxy = all.first(where: { proxy in
				(proxy.perform(NSSelectorFromString("bundleIdentifier"))?.takeUnretainedValue() as? String) == identifier
			}) else {
				log.notice("lsprobe: —— \(identifier, privacy: .public): no proxy in the list")
				continue
			}

			log.notice("lsprobe: —— \(identifier, privacy: .public) ——")
			for field in proxyFields {
				log.notice("lsprobe:   \(field, privacy: .public): \(reading(field, of: proxy), privacy: .public)")
			}
		}

		log.notice("lsprobe: done")
	}

	/// The class's own methods, filtered by what they are about — for finding the
	/// call that does a job when the one that used to is gone.
	private static func logMethods(of cls: AnyClass, label: String, matching needles: [String]) {
		var count: UInt32 = 0
		guard let methods = class_copyMethodList(cls, &count) else {
			log.notice("lsprobe: \(label, privacy: .public): no methods")
			return
		}
		defer { free(methods) }

		var names: [String] = []
		for index in 0..<Int(count) {
			let name = NSStringFromSelector(method_getName(methods[index]))
			let lowered = name.lowercased()
			if needles.contains(where: { lowered.contains($0) }) {
				names.append(name)
			}
		}

		log.notice("lsprobe: \(label, privacy: .public) has \(count, privacy: .public) own methods, \(names.count, privacy: .public) of interest")
		for name in names.sorted() {
			log.notice("lsprobe:   · \(name, privacy: .public)")
		}
	}

	/// A class method, asked the way the runtime actually resolves one: the
	/// message goes to the *class object*, which is an instance of the metaclass
	/// and finds the method there.
	private static func logProxy(_ cls: AnyClass, selector: String, identifier: String?) {
		guard let identifier else { return }
		let name = NSSelectorFromString(selector)
		guard class_getClassMethod(cls, name) != nil else {
			log.notice("lsprobe: +[\(NSStringFromClass(cls), privacy: .public) \(selector, privacy: .public)]: not implemented")
			return
		}
		let value = (cls as! NSObject.Type).perform(name, with: identifier)?.takeUnretainedValue()
		log.notice("lsprobe: +[LSApplicationProxy \(selector, privacy: .public)] → \(describe(value), privacy: .public)")

		guard let proxy = value as? NSObject else { return }
		for field in proxyFields {
			log.notice("lsprobe:   [proxy] \(field, privacy: .public): \(reading(field, of: proxy), privacy: .public)")
		}
	}

	/// What one field of a proxy says, and what the runtime says the field
	/// *returns*.
	///
	/// The encoding is read before the value is, because the two are not
	/// independent: a method whose return type is not an object hands its answer
	/// back in a register that `perform` will hand to ARC as a pointer, and
	/// retaining that takes the process down. Reading the encoding first is what
	/// keeps a diagnostic from killing the app it is diagnosing — and the fields
	/// that turn out not to be objects are exactly the ones worth knowing about.
	private static func reading(_ field: String, of proxy: NSObject) -> String {
		let selector = NSSelectorFromString(field)
		guard let method = class_getInstanceMethod(type(of: proxy), selector) else {
			return "no method"
		}
		let encoding = String(cString: method_getTypeEncoding(method)!)
		let returnsObject = encoding.hasPrefix("@")
		guard proxy.responds(to: selector) else { return "encoding \(encoding), does not respond" }
		guard returnsObject else { return "encoding \(encoding) (not an object — not called)" }
		return "encoding \(encoding) → \(describe(proxy.perform(selector)?.takeUnretainedValue()))"
	}

	/// What came back, in a form worth putting in a log line: a URL as its path,
	/// an array as its count and first element, anything else as itself.
	///
	/// Deliberately never `String(describing:)` on the object itself — a proxy
	/// prints as its address, which tells the reader nothing, and the point of
	/// this whole file is to find out what these objects will say.
	private static func describe(_ value: Any?) -> String {
		guard let value else { return "nil" }
		if let url = value as? URL { return "URL \(url.path)" }
		if let string = value as? String { return "String \(string)" }
		if let number = value as? NSNumber { return "Number \(number)" }
		if let date = value as? Date { return "Date \(date.timeIntervalSince1970)" }
		if let array = value as? [Any] {
			let first = array.first.map { String(describing: type(of: $0)) } ?? "—"
			return "Array(\(array.count)) first=\(first)"
		}
		return String(describing: type(of: value))
	}
}
#endif
