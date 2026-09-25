//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	let port = Int.random(in: 4000...8000)
	private var _needsShutdown = false
	
	var packageUrl: URL?
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?

	/// Why the local server is not answering, if it is not.
	///
	/// The initialiser used to `throw`, and the one place that built one did it
	/// inside a `try!` in a view's initialiser: a port that was still held by the
	/// previous install took the whole app down as the sheet opened. Binding now
	/// fails into this, and the sheet can say what happened instead.
	private(set) var startupError: Error?

	/// Whether the server came up with TLS. The install URLs are built to match,
	/// so this is not cosmetic: see `setupApp`, which is where it is set.
	var usesTLS = false

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.app = app
		self.viewModel = viewModel
		_setup()
		_configureRoutes()

		do {
			try _server?.server.start()
			_needsShutdown = _server != nil
		} catch {
			self.startupError = error
			_server = nil
		}
	}

	/// Whether the local install server came up. The other two install routes
	/// (`idevice` and the external manifest service) do not need it.
	var isAvailable: Bool { _server != nil }
	
	deinit {
		_shutdownServer()
	}
	
	private func _setup() {
		do {
			self._server = try setupApp(port: port)
		} catch {
			// A TLS identity that is revoked or unusable is refused by
			// `setupApp` — recorded here so the install screen can say why
			// instead of sitting on a server that never came up.
			self.startupError = error
			self._server = nil
		}
	}
		
	private func _configureRoutes() {
		_server?.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			switch req.url.path {
			case plistEndpoint.path:
				self._updateStatus(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: installManifestData))
			case displayImageSmallEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path:
				guard let packageUrl = packageUrl else {
					return Response(status: .notFound)
				}
				
				self._updateStatus(.sendingPayload)
				
				return req.fileio.streamFile(
					at: packageUrl.path
				) { result in
					switch result {
					case .success:
						self._updateStatus(.installing)
					case .failure(let error):
						self._updateStatus(.broken(error))
					}

				}
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			default:
				return Response(status: .notFound)
			}
		}
	}
	
	private func _shutdownServer() {
		guard _needsShutdown else { return }
		
		_needsShutdown = false
		_server?.server.shutdown()
		_server?.shutdown()
	}
	
	private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
		}
	}
		
	func getServerMethod() -> Int {
		UserDefaults.standard.integer(forKey: "Feather.serverMethod")
	}
	
	func getIPFix() -> Bool {
		UserDefaults.standard.bool(forKey: "Feather.ipFix")
	}
}
