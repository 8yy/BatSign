//
//  Server+Compute.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import UIKit.UIGraphicsImageRenderer

extension ServerInstaller {
	/// The URL for one of this server's own routes.
	///
	/// Every one of these used to end in `components.url!`. That value is nil
	/// whenever the host will not parse — and the host is `sni()`, which is the
	/// device's own name as often as it is an address, and can come from a
	/// certificate's common name. A name with a space in it was therefore a crash
	/// on the install screen rather than a fallback.
	///
	/// iOS installd fetches this URL outside BatSign's process. The `Server`
	/// installer therefore requires the host named in a valid TLS identity; it
	/// must not fabricate an HTTP/loopback URL when that identity is unavailable.
	private func endpointURL(path: String, secure: Bool) -> URL {
		var comps = URLComponents()
		func build(host: String) -> URL? {
			comps.scheme = secure ? "https" : "http"
			comps.host = host
			comps.path = path
			comps.port = port
			return comps.url
		}

		return build(host: sni())
			?? build(host: "127.0.0.1")
			?? URL(fileURLWithPath: path)
	}

	/// Whether this server is serving TLS, which is what the install URLs have to
	/// agree with. See `setupApp`.
	private var isSecure: Bool {
		getServerMethod() != 1 && usesTLS
	}

	var plistEndpoint: URL {
		endpointURL(path: "/\(id).plist", secure: isSecure)
	}

	var payloadEndpoint: URL {
		endpointURL(path: "/\(id).ipa", secure: isSecure)
	}

	var pageEndpoint: URL {
		endpointURL(path: "/install", secure: isSecure)
	}

	/// Compatibility name retained for existing call sites. The manifest is now
	/// generated locally, removing api.palera.in as a critical install dependency.
	var externalServerLink: String { plistEndpoint.absoluteString }

	var iTunesLink: String {
		_iTunesLink(with: plistEndpoint.absoluteString)
	}

	var iTunesLinkExternal: String {
		_iTunesLink(with: externalServerLink)
	}

	private func _iTunesLink(with url: String) -> String {
		var components = URLComponents()
		components.scheme = "itms-services"
		components.host = ""
		components.queryItems = [
			URLQueryItem(name: "action", value: "download-manifest"),
			URLQueryItem(name: "url", value: url),
		]
		return components.string ?? "itms-services://?action=download-manifest"
	}

	var displayImageSmallEndpoint: URL {
		endpointURL(path: "/app57x57.png", secure: isSecure)
	}

	var displayImageLargeEndpoint: URL {
		endpointURL(path: "/app512x512.png", secure: isSecure)
	}

	var displayImageSmallData: Data {
		_createIcon(57)
	}

	var displayImageLargeData: Data {
		_createIcon(512)
	}
	
	private func _createIcon(_ r: CGFloat) -> Data {
		let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
		let image = renderer.image { ctx in
			UIColor.tintColor.setFill()
			ctx.fill(.init(x: 0, y: 0, width: r, height: r))
		}
		// A renderer always produces PNG data for a bitmap this simple; the
		// force unwrap here was inside the manifest the install reads, so an
		// empty icon is the safer failure of the two.
		return image.pngData() ?? Data()
	}

	var html: String {
		"""
		<html style="background-color: black;">
		<script type="text/javascript">window.location="\(iTunesLink)"</script>
		</html>
		"""
	}

	var installManifest: [String: Any] {[
		"items": [[
			"assets": [
				[
					"kind": "software-package",
					"url": payloadEndpoint.absoluteString,
				],
				[
					"kind": "display-image",
					"url": displayImageSmallEndpoint.absoluteString,
				],
				[
					"kind": "full-size-image",
					"url": displayImageLargeEndpoint.absoluteString,
				],
			],
			"metadata": [
				"bundle-identifier": app.identifier,
				"bundle-version": app.version,
				"kind": "software",
				"title": app.name,
			],
		],],
	]}

	var installManifestData: Data {
		(try? PropertyListSerialization.data(
			fromPropertyList: installManifest,
			format: .xml,
			options: .zero
		)) ?? .init()
	}
}
