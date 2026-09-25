//
//  Server+TLS.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import NIOSSL
import NIOTLS
import Vapor
import SystemConfiguration.CaptiveNetwork

// MARK: - Class extension: TLS/Setup
extension ServerInstaller {
	/// Coordinates readers with the three-file certificate replacement so a
	/// server can never load a new key with an old certificate (or vice
	/// versa). Ported with the certificate fixes.
	private static let tlsIdentityLock = NSLock()

	/// Runs an operation while the TLS identity on disk cannot be replaced.
	static func withTLSIdentityLock<T>(_ operation: () throws -> T) rethrows -> T {
		tlsIdentityLock.lock()
		defer { tlsIdentityLock.unlock() }
		return try operation()
	}

	/// Parses the complete PEM chain and private key and asks NIOSSL to build
	/// a server context. Building the context verifies that the staged
	/// identity is usable before it is allowed to replace the currently
	/// working files.
	static func validateTLSIdentity(
		certificateURL: URL,
		privateKeyURL: URL
	) throws {
		_ = try NIOSSLContext(
			configuration: makeTLSConfiguration(
				certificateURL: certificateURL,
				privateKeyURL: privateKeyURL
			)
		)
	}

	private static func makeTLSConfiguration(
		certificateURL: URL,
		privateKeyURL: URL
	) throws -> TLSConfiguration {
		try TLSConfiguration.makeServerConfiguration(
			certificateChain: NIOSSLCertificate.fromPEMFile(certificateURL.path).map {
				NIOSSLCertificateSource.certificate($0)
			},
			privateKey: .privateKey(
				try NIOSSLPrivateKey(file: privateKeyURL.path, format: .pem)
			)
		)
	}

	// MARK: Setup
	static let env: Environment = {
		var env = try! Environment.detect()
		try! LoggingSystem.bootstrap(from: &env)
		return env
	}()
	
	func setupApp(port: Int) throws -> Application {
		let app = Application(Self.env)
		app.threadPool = .init(numberOfThreads: 1)
		
		// TLS is only configured when there is a certificate *and* a name for it
		// to be valid for. `sni()` is what the install URL is built from, so a
		// server holding a certificate for some other host would hand the device
		// a URL whose handshake cannot succeed — better to serve plain HTTP on
		// the loopback address, which is the same socket and actually installs.
		//
		// `usesTLS` is recorded rather than guessed later, because the URLs have
		// to agree with what the server is really doing: the scheme they used to
		// be built with came from a settings value and ignored this entirely,
		// which meant an app with no certificate material handed iOS an `https`
		// URL for an HTTP server and the install failed with nothing on screen to
		// say why.
		if getServerMethod() != 1, Self.hasCertificateMaterial(), let tls = try tls() {
			app.http.server.configuration.tlsConfiguration = tls
			usesTLS = true
		}
		
		app.http.server.configuration.hostname = sni()
		app.http.server.configuration.tcpNoDelay = true
		app.http.server.configuration.address = .hostname("0.0.0.0", port: port)
		app.http.server.configuration.port = port
		app.routes.defaultMaxBodySize = "128mb"
		app.routes.caseInsensitive = false
		
		return app
	}
	
	// MARK: Files/IP
	func sni() -> String {
		let localhost = "127.0.0.1"
		
		if getServerMethod() == 1 {
			return !self.getIPFix()
				? (Self.getLocalAddress() ?? localhost)
				: localhost
		}
		
		// An empty file is not a host name. Both of these used to be returned as
		// they came, and an empty host is a URL that cannot be built.
		if let name = readCommonName(), !name.isEmpty {
			return name
		}
		
		return localhost
	}

	/// Whether a server certificate and its name are there to be used.
	static func hasCertificateMaterial() -> Bool {
		guard
			Self.getUrl("server", ext: "crt") != nil,
			Self.getUrl("server", ext: "pem") != nil,
			let name = Self.getUrl("commonName", ext: "txt"),
			let contents = try? String(contentsOf: name, encoding: .utf8)
		else {
			return false
		}
		
		return !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}
	
	func tls() throws -> TLSConfiguration? {
		// The revocation block, ported with the certificate fixes: an identity
		// that has ever been positively identified as revoked is never tried
		// again, and the server refuses to start behind it rather than serving
		// an install over a dead certificate.
		if FR.isActiveSSLCertificateBlocked() {
			throw NSError(
				domain: "app.batsign.ssl",
				code: -1,
				userInfo: [
					NSLocalizedDescriptionKey: "The active SSL certificate has been revoked and is blocked. Update SSL certificates before using Fully Local installation."
				]
			)
		}

		return try Self.withTLSIdentityLock {
			guard
				let crt = Self.getUrl("server", ext: "crt"),
				let pem = Self.getUrl("server", ext: "pem")
			else {
				return nil
			}

			return try Self.makeTLSConfiguration(
				certificateURL: crt,
				privateKeyURL: pem
			)
		}
	}

	func readCommonName() -> String? {
		Self.withTLSIdentityLock {
			guard let url = Self.getUrl("commonName", ext: "txt") else {
				return nil
			}

			guard let value = try? String(contentsOf: url, encoding: .utf8)
				.trimmingCharacters(in: .whitespacesAndNewlines),
				!value.isEmpty
			else {
				return nil
			}

			return value
		}
	}
}

extension ServerInstaller {
	static func getUrl(_ name: String, ext: String) -> URL? {
		let fileManager = FileManager.default

		// The directory the certificate fix installs into.
		let serverURL = URL.documentsDirectory.appendingPathComponent("App").appendingPathComponent("Server").appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: serverURL.path) {
			return serverURL
		}

		let documentsURL = URL.documentsDirectory.appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: documentsURL.path) {
			return documentsURL
		}

		let oldServerURL = URL.documentsDirectory.appendingPathComponent("Server").appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: oldServerURL.path) {
			return oldServerURL
		}

		return Bundle.main.url(forResource: name, withExtension: ext)
	}
	
	static func getLocalAddress() -> String? {
		var address: String?
		var ifaddr: UnsafeMutablePointer<ifaddrs>?
		
		if getifaddrs(&ifaddr) == 0 {
			var ptr = ifaddr
			while ptr != nil {
				let interface = ptr!.pointee
				let addrFamily = interface.ifa_addr.pointee.sa_family
				
				if addrFamily == UInt8(AF_INET) {
					
					let name = String(cString: interface.ifa_name)
					if name == "en0" || name == "pdp_ip0" {
						
						var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
						if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
						               &hostname, socklen_t(hostname.count),
						               nil, socklen_t(0), NI_NUMERICHOST) == 0 {
							address = String(cString: hostname)
						}
						
					}
				}
				ptr = ptr!.pointee.ifa_next
			}
			freeifaddrs(ifaddr)
		}
		
		return address
	}
}
