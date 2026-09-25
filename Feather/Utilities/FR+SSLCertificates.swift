//
//  FR+SSLCertificates.swift
//  Feather
//
//  The SSL certificate system, ported from the publisher's Ksign certificate
//  fixes: a multi-provider download with TLS validation, Apple trust and
//  revocation assessment, Cert Spotter cross-checking, atomic three-file
//  installation under a lock, and a revocation block the server refuses to
//  start behind. Adapted to BatSign only in its identity labels; the logic is
//  the ported logic.
//

import Foundation
import CryptoKit
import Security
import OSLog
import NimbleJSON

extension FR {

	private static let _sslCertificateInstallQueue = DispatchQueue(
		label: "app.batsign.ssl-certificate-install"
	)
	private static let _sslRevokedFingerprintsDefaultsKey =
		"Feather.ssl.revoked-fingerprints"

	private enum SSLCertificateProvider {
		case pack(label: String, url: String)
		case pemPair(
			label: String,
			certificateURL: String,
			privateKeyURL: String,
			hostname: String
		)

		var label: String {
			switch self {
			case .pack(let label, _), .pemPair(let label, _, _, _):
				return label
			}
		}

		var identity: String {
			switch self {
			case .pack(_, let url):
				return "pack:\(url)"
			case .pemPair(_, let certificateURL, let privateKeyURL, _):
				return "pem:\(certificateURL)|\(privateKeyURL)"
			}
		}
	}

	private struct SSLIdentityCandidate {
		let certificateChain: String
		let privateKey: String
		let commonName: String
		let sourceLabel: String
	}

	private enum SSLAppleTrustResult {
		case trusted
		case revoked(String)
		case revocationUnknown(String)
		case rejected(String)
	}

	private enum SSLCertSpotterResult {
		case good
		case revoked(String)
		case unknown(String)
	}

	private struct CertSpotterIssuance: Decodable {
		let id: String
		let certSHA256: String
		let revoked: Bool?
		let revocation: Revocation?

		private enum CodingKeys: String, CodingKey {
			case id
			case certSHA256 = "cert_sha256"
			case revoked
			case revocation
		}

		struct Revocation: Decodable {
			let time: String?
			let reason: Int?
			let checkedAt: String?

			private enum CodingKeys: String, CodingKey {
				case time, reason
				case checkedAt = "checked_at"
			}
		}
	}

	private enum SSLCertificateUpdateError: LocalizedError {
		case allDownloadsFailed([String])
		case invalidPack(String)
		case revokedCertificate(String)
		case trustFailed(String)
		case revocationUnknown(String)
		case fileUpdateFailed(Error)

		var errorDescription: String? {
			switch self {
			case .allDownloadsFailed(let failures):
				return "Could not find a usable SSL certificate. "
					+ failures.joined(separator: " | ")
			case .invalidPack(let reason):
				return "The downloaded SSL certificate is invalid: \(reason)"
			case .revokedCertificate(let reason):
				return "The SSL certificate is revoked: \(reason)"
			case .trustFailed(let reason):
				return "iOS rejected the SSL certificate: \(reason)"
			case .revocationUnknown(let reason):
				return "The SSL certificate revocation status could not be confirmed: \(reason)"
			case .fileUpdateFailed(let error):
				return "The SSL certificate files could not be updated: \(error.localizedDescription)"
			}
		}
	}

	static func downloadSSLCertificates(
		from urlString: String,
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		let providers = _sslCertificateProviders(requestedPackURL: urlString)

		func tryProvider(at index: Int, failures: [String]) {
			guard index < providers.count else {
				completion(.failure(SSLCertificateUpdateError.allDownloadsFailed(failures)))
				return
			}

			let provider = providers[index]
			_fetchSSLCandidate(from: provider) { fetchResult in
				switch fetchResult {
				case .failure(let error):
					let failure = "\(provider.label): \(error.localizedDescription)"
					Logger.misc.warning(
						"SSL certificate provider failed: \(failure, privacy: .public)"
					)
					tryProvider(at: index + 1, failures: failures + [failure])

				case .success(let candidate):
					_sslCertificateInstallQueue.async {
						do {
							try _validateCandidateTLS(candidate)
						} catch {
							let failure = "\(provider.label): \(error.localizedDescription)"
							Logger.misc.warning(
								"SSL certificate provider was unusable: \(failure, privacy: .public)"
							)
							tryProvider(at: index + 1, failures: failures + [failure])
							return
						}

						_assessSSLCandidate(candidate) { assessment in
							switch assessment {
							case .failure(let error):
								let failure = "\(provider.label): \(error.localizedDescription)"
								Logger.misc.warning(
									"SSL certificate provider was rejected: \(failure, privacy: .public)"
								)
								tryProvider(at: index + 1, failures: failures + [failure])

							case .success:
								_sslCertificateInstallQueue.async {
									do {
										try _installSSLCertificateIdentity(candidate)
										Logger.misc.info(
											"SSL certificate identity is usable and active from \(provider.label, privacy: .public)"
										)
										DispatchQueue.main.async {
											UINotificationFeedbackGenerator().notificationOccurred(.success)
										}
										completion(.success(()))
									} catch {
										let wrapped = SSLCertificateUpdateError.fileUpdateFailed(error)
										Logger.misc.error(
											"SSL certificate update failed: \(wrapped.localizedDescription, privacy: .public)"
										)
										completion(.failure(wrapped))
									}
								}
							}
						}
					}
			}
		}
		}

		// Re-check the identity already on disk before contacting providers. If
		// its CA has revoked it since the last launch, persist the fingerprint so
		// ServerInstaller will refuse to use the dead identity immediately.
		_sslCertificateInstallQueue.async {
			_refreshInstalledRevocationBlock()
			tryProvider(at: 0, failures: [])
		}
	}

	/// Called by ServerInstaller before TLS startup. A fingerprint that has ever
	/// been positively identified as revoked is never tried again, even if the
	/// same certificate remains on disk or a provider republishes it.
	static func isActiveSSLCertificateBlocked() -> Bool {
		guard let installed = _installedSSLCandidate(),
			let fingerprint = try? _leafFingerprint(from: installed.certificateChain)
		else {
			return false
		}
		return _isRevokedFingerprint(fingerprint)
	}

	private static func _sslCertificateProviders(
		requestedPackURL: String
	) -> [SSLCertificateProvider] {
		var providers: [SSLCertificateProvider] = [
			.pemPair(
				label: "127-0-0-1.dev",
				certificateURL: "https://raw.githubusercontent.com/appcove/127-0-0-1.dev/main/cert.pem",
				privateKeyURL: "https://raw.githubusercontent.com/appcove/127-0-0-1.dev/main/key.pem",
				hostname: "127-0-0-1.dev"
			),
		]

		let requested = requestedPackURL.trimmingCharacters(in: .whitespacesAndNewlines)
		if !requested.isEmpty {
			providers.append(.pack(label: "Backloop primary", url: requested))
		}
		providers.append(
			.pack(
				label: "Backloop GitHub fallback",
				url: "https://raw.githubusercontent.com/perki/backloop.dev/gh-pages/pack.json"
			)
		)

		var seen = Set<String>()
		return providers.filter { seen.insert($0.identity).inserted }
	}

	private static func _fetchSSLCandidate(
		from provider: SSLCertificateProvider,
		completion: @escaping (Result<SSLIdentityCandidate, Error>) -> Void
	) {
		switch provider {
		case .pack(let label, let url):
			NBFetchService().fetch(from: url) { (result: Result<ServerPackModel, Error>) in
				switch result {
				case .success(let pack):
					do {
						completion(.success(try _candidate(from: pack, sourceLabel: label)))
					} catch {
						completion(.failure(error))
					}
				case .failure(let error):
					completion(.failure(error))
				}
			}

		case .pemPair(let label, let certificateURL, let privateKeyURL, let hostname):
			_fetchText(from: certificateURL) { certificateResult in
				switch certificateResult {
				case .failure(let error):
					completion(.failure(error))
				case .success(let certificateChain):
					_fetchText(from: privateKeyURL) { keyResult in
						switch keyResult {
						case .failure(let error):
							completion(.failure(error))
						case .success(let privateKey):
							do {
								let candidate = SSLIdentityCandidate(
									certificateChain: certificateChain.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
									privateKey: privateKey.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
									commonName: hostname,
									sourceLabel: label
								)
								try _validateIdentityShape(candidate)
								completion(.success(candidate))
							} catch {
								completion(.failure(error))
							}
						}
					}
				}
			}
		}
	}

	private static func _fetchText(
		from urlString: String,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		guard let url = URL(string: urlString) else {
			completion(.failure(SSLCertificateUpdateError.invalidPack("invalid provider URL")))
			return
		}

		var request = URLRequest(url: url)
		request.timeoutInterval = 20
		request.setValue("BatSign/SSL-Certificate-Manager", forHTTPHeaderField: "User-Agent")

		URLSession.shared.dataTask(with: request) { data, response, error in
			if let error {
				completion(.failure(error))
				return
			}
			if let http = response as? HTTPURLResponse,
				!(200...299).contains(http.statusCode) {
				completion(.failure(NSError(
					domain: NSURLErrorDomain,
					code: http.statusCode,
					userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
				)))
				return
			}
			guard let data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
				completion(.failure(SSLCertificateUpdateError.invalidPack("provider returned empty data")))
				return
			}
			completion(.success(value))
		}.resume()
	}

	private static func _candidate(
		from pack: ServerPackModel,
		sourceLabel: String
	) throws -> SSLIdentityCandidate {
		let certificate = pack.cert.trimmingCharacters(in: .whitespacesAndNewlines)
		let certificateAuthorities = pack.ca.trimmingCharacters(in: .whitespacesAndNewlines)
		let privateKey = pack.key.trimmingCharacters(in: .whitespacesAndNewlines)
		let commonName = pack.info.domains.commonName
			.trimmingCharacters(in: .whitespacesAndNewlines)

		let candidate = SSLIdentityCandidate(
			certificateChain: certificate + "\n\n" + certificateAuthorities + "\n",
			privateKey: privateKey + "\n",
			commonName: commonName,
			sourceLabel: sourceLabel
		)
		try _validateIdentityShape(candidate)
		return candidate
	}

	private static func _validateIdentityShape(_ candidate: SSLIdentityCandidate) throws {
		let certificateCount = candidate.certificateChain
			.components(separatedBy: "-----BEGIN CERTIFICATE-----")
			.count - 1
		guard certificateCount >= 2 else {
			throw SSLCertificateUpdateError.invalidPack(
				"the leaf certificate plus intermediate chain were not supplied"
			)
		}
		guard candidate.certificateChain.contains("-----END CERTIFICATE-----") else {
			throw SSLCertificateUpdateError.invalidPack("the certificate PEM is malformed")
		}
		let hasSupportedKeyHeader =
			candidate.privateKey.contains("-----BEGIN PRIVATE KEY-----")
			|| candidate.privateKey.contains("-----BEGIN RSA PRIVATE KEY-----")
			|| candidate.privateKey.contains("-----BEGIN EC PRIVATE KEY-----")
		let hasSupportedKeyFooter =
			candidate.privateKey.contains("-----END PRIVATE KEY-----")
			|| candidate.privateKey.contains("-----END RSA PRIVATE KEY-----")
			|| candidate.privateKey.contains("-----END EC PRIVATE KEY-----")
		guard hasSupportedKeyHeader, hasSupportedKeyFooter else {
			throw SSLCertificateUpdateError.invalidPack("the private key PEM is malformed")
		}
		guard !candidate.commonName.isEmpty else {
			throw SSLCertificateUpdateError.invalidPack("the common name is empty")
		}
	}

	private static func _validateCandidateTLS(_ candidate: SSLIdentityCandidate) throws {
		let fileManager = FileManager.default
		let directory = fileManager.temporaryDirectory.appendingPathComponent(
			"ksign-ssl-check-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? fileManager.removeItem(at: directory) }

		try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		let crt = directory.appendingPathComponent("server.crt")
		let key = directory.appendingPathComponent("server.pem")
		try candidate.certificateChain.write(to: crt, atomically: true, encoding: .utf8)
		try candidate.privateKey.write(to: key, atomically: true, encoding: .utf8)
		try ServerInstaller.validateTLSIdentity(certificateURL: crt, privateKeyURL: key)
	}

	private static func _assessSSLCandidate(
		_ candidate: SSLIdentityCandidate,
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		do {
			let fingerprint = try _leafFingerprint(from: candidate.certificateChain)
			if _isRevokedFingerprint(fingerprint) {
				completion(.failure(SSLCertificateUpdateError.revokedCertificate(
					"fingerprint \(fingerprint) was previously confirmed revoked"
				)))
				return
			}

			switch try _evaluateAppleTrust(candidate) {
			case .trusted:
				completion(.success(()))

			case .revoked(let reason):
				_blockRevokedFingerprint(fingerprint, reason: reason)
				completion(.failure(SSLCertificateUpdateError.revokedCertificate(reason)))

			case .revocationUnknown(let reason):
				_checkCertSpotter(
					fingerprint: fingerprint,
					domain: _baseDomain(for: candidate.commonName)
				) { result in
					switch result {
					case .good:
						Logger.misc.info(
							"Apple revocation response was incomplete; Cert Spotter reports certificate \(fingerprint, privacy: .public) not revoked"
						)
						completion(.success(()))
					case .revoked(let certSpotterReason):
						_blockRevokedFingerprint(fingerprint, reason: certSpotterReason)
						completion(.failure(SSLCertificateUpdateError.revokedCertificate(certSpotterReason)))
					case .unknown(let certSpotterReason):
						completion(.failure(SSLCertificateUpdateError.revocationUnknown(
							"\(reason); Cert Spotter: \(certSpotterReason)"
						)))
					}
				}

			case .rejected(let reason):
				// A generic trust failure is not permanently blacklisted. Ask Cert
				// Spotter only to determine whether revocation was the underlying
				// cause, then reject this candidate for the current update either way.
				_checkCertSpotter(
					fingerprint: fingerprint,
					domain: _baseDomain(for: candidate.commonName)
				) { result in
					if case .revoked(let certSpotterReason) = result {
						_blockRevokedFingerprint(fingerprint, reason: certSpotterReason)
						completion(.failure(SSLCertificateUpdateError.revokedCertificate(certSpotterReason)))
					} else {
						completion(.failure(SSLCertificateUpdateError.trustFailed(reason)))
					}
				}
			}
		} catch {
			completion(.failure(error))
		}
	}

	private static func _evaluateAppleTrust(
		_ candidate: SSLIdentityCandidate
	) throws -> SSLAppleTrustResult {
		let certificateData = try _certificateDERs(from: candidate.certificateChain)
		let certificates = certificateData.compactMap {
			SecCertificateCreateWithData(nil, $0 as CFData)
		}
		guard certificates.count == certificateData.count, !certificates.isEmpty else {
			throw SSLCertificateUpdateError.invalidPack("Security.framework could not parse the certificate chain")
		}

		let hostname = _validationHostname(for: candidate.commonName)
		let sslPolicy = SecPolicyCreateSSL(true, hostname as CFString)
		let revocationFlags = kSecRevocationUseAnyAvailableMethod
			| kSecRevocationRequirePositiveResponse
		guard let revocationPolicy = SecPolicyCreateRevocation(revocationFlags) else {
			throw SSLCertificateUpdateError.revocationUnknown("could not create the iOS revocation policy")
		}

		let policies: [SecPolicy] = [sslPolicy, revocationPolicy]
		var trust: SecTrust?
		let createStatus = SecTrustCreateWithCertificates(
			certificates as CFArray,
			policies as CFArray,
			&trust
		)
		guard createStatus == errSecSuccess, let trust else {
			throw SSLCertificateUpdateError.trustFailed(
				"SecTrustCreateWithCertificates failed with OSStatus \(createStatus)"
			)
		}

		_ = SecTrustSetNetworkFetchAllowed(trust, true)
		var trustError: CFError?
		if SecTrustEvaluateWithError(trust, &trustError) {
			return .trusted
		}

		let message = trustError.map { CFErrorCopyDescription($0) as String }
			?? "unknown trust evaluation failure"
		let code = trustError.map { OSStatus(CFErrorGetCode($0)) }

		if code == errSecCertificateRevoked {
			return .revoked(message)
		}
		if code == errSecIncompleteCertRevocationCheck {
			return .revocationUnknown(message)
		}
		return .rejected(message)
	}

	private static func _refreshInstalledRevocationBlock() {
		guard let installed = _installedSSLCandidate(),
			let fingerprint = try? _leafFingerprint(from: installed.certificateChain),
			!_isRevokedFingerprint(fingerprint)
		else {
			return
		}

		do {
			if case .revoked(let reason) = try _evaluateAppleTrust(installed) {
				_blockRevokedFingerprint(fingerprint, reason: reason)
				Logger.misc.error(
					"Installed SSL certificate \(fingerprint, privacy: .public) is revoked and has been blocked"
				)
			}
		} catch {
			Logger.misc.warning(
				"Could not re-check installed SSL certificate revocation: \(error.localizedDescription, privacy: .public)"
			)
		}
	}

	private static func _installedSSLCandidate() -> SSLIdentityCandidate? {
		ServerInstaller.withTLSIdentityLock {
			guard
				let crtURL = ServerInstaller.getUrl("server", ext: "crt"),
				let keyURL = ServerInstaller.getUrl("server", ext: "pem"),
				let commonNameURL = ServerInstaller.getUrl("commonName", ext: "txt"),
				let certificateChain = try? String(contentsOf: crtURL, encoding: .utf8),
				let privateKey = try? String(contentsOf: keyURL, encoding: .utf8),
				let commonName = try? String(contentsOf: commonNameURL, encoding: .utf8)
					.trimmingCharacters(in: .whitespacesAndNewlines),
				!commonName.isEmpty
			else {
				return nil
			}

			return SSLIdentityCandidate(
				certificateChain: certificateChain,
				privateKey: privateKey,
				commonName: commonName,
				sourceLabel: "installed identity"
			)
		}
	}

	private static func _certificateDERs(from pem: String) throws -> [Data] {
		let begin = "-----BEGIN CERTIFICATE-----"
		let end = "-----END CERTIFICATE-----"
		var certificates: [Data] = []
		var remainder = pem[...]

		while let beginRange = remainder.range(of: begin) {
			remainder = remainder[beginRange.upperBound...]
			guard let endRange = remainder.range(of: end) else {
				throw SSLCertificateUpdateError.invalidPack("unterminated certificate PEM block")
			}
			let body = remainder[..<endRange.lowerBound]
			let base64 = body.filter { !$0.isWhitespace }
			guard let data = Data(base64Encoded: String(base64)) else {
				throw SSLCertificateUpdateError.invalidPack("certificate PEM contains invalid base64")
			}
			certificates.append(data)
			remainder = remainder[endRange.upperBound...]
		}

		guard !certificates.isEmpty else {
			throw SSLCertificateUpdateError.invalidPack("no certificates were found")
		}
		return certificates
	}

	private static func _leafFingerprint(from pem: String) throws -> String {
		guard let leaf = try _certificateDERs(from: pem).first else {
			throw SSLCertificateUpdateError.invalidPack("the leaf certificate is missing")
		}
		return SHA256.hash(data: leaf)
			.map { String(format: "%02x", $0) }
			.joined()
	}

	private static func _validationHostname(for commonName: String) -> String {
		let value = commonName.trimmingCharacters(in: .whitespacesAndNewlines)
		if value.hasPrefix("*.") {
			return "ksign." + String(value.dropFirst(2))
		}
		return value
	}

	private static func _baseDomain(for commonName: String) -> String {
		let value = commonName.trimmingCharacters(in: .whitespacesAndNewlines)
		return value.hasPrefix("*.") ? String(value.dropFirst(2)) : value
	}

	private static func _revokedFingerprints() -> Set<String> {
		Set(UserDefaults.standard.stringArray(forKey: _sslRevokedFingerprintsDefaultsKey) ?? [])
	}

	private static func _isRevokedFingerprint(_ fingerprint: String) -> Bool {
		_revokedFingerprints().contains(fingerprint.lowercased())
	}

	private static func _blockRevokedFingerprint(_ fingerprint: String, reason: String) {
		let normalized = fingerprint.lowercased()
		var blocked = _revokedFingerprints()
		guard blocked.insert(normalized).inserted else { return }
		UserDefaults.standard.set(Array(blocked).sorted(), forKey: _sslRevokedFingerprintsDefaultsKey)
		Logger.misc.error(
			"Blocked revoked SSL certificate fingerprint \(normalized, privacy: .public): \(reason, privacy: .public)"
		)
	}

	private static func _checkCertSpotter(
		fingerprint: String,
		domain: String,
		completion: @escaping (SSLCertSpotterResult) -> Void
	) {
		func fetchPage(after: String?, page: Int) {
			guard page < 8 else {
				completion(.unknown("matching issuance was not found within the pagination limit"))
				return
			}

			var components = URLComponents(string: "https://api.certspotter.com/v1/issuances")!
			var items = [
				URLQueryItem(name: "domain", value: domain),
				URLQueryItem(name: "include_subdomains", value: "true"),
				URLQueryItem(name: "match_wildcards", value: "true"),
				URLQueryItem(name: "expand", value: "revocation"),
			]
			if let after { items.append(URLQueryItem(name: "after", value: after)) }
			components.queryItems = items

			guard let url = components.url else {
				completion(.unknown("could not construct Cert Spotter URL"))
				return
			}
			var request = URLRequest(url: url)
			request.timeoutInterval = 12
			request.setValue("BatSign/SSL-Certificate-Manager", forHTTPHeaderField: "User-Agent")

			URLSession.shared.dataTask(with: request) { data, response, error in
				if let error {
					completion(.unknown(error.localizedDescription))
					return
				}
				if let http = response as? HTTPURLResponse,
					!(200...299).contains(http.statusCode) {
					completion(.unknown("HTTP \(http.statusCode)"))
					return
				}
				guard let data else {
					completion(.unknown("empty response"))
					return
				}

				do {
					let issuances = try JSONDecoder().decode([CertSpotterIssuance].self, from: data)
					if let issuance = issuances.first(where: {
						$0.certSHA256.caseInsensitiveCompare(fingerprint) == .orderedSame
					}) {
						switch issuance.revoked {
						case .some(true):
							let time = issuance.revocation?.time ?? "unknown time"
							let reason = issuance.revocation?.reason.map(String.init) ?? "unknown"
							completion(.revoked("Cert Spotter reports revocation at \(time), reason code \(reason)"))
						case .some(false):
							guard
								let checkedAt = issuance.revocation?.checkedAt,
								let checkedDate = ISO8601DateFormatter().date(from: checkedAt)
							else {
								completion(.unknown("Cert Spotter did not provide a revocation-check timestamp"))
								return
							}
							let age = Date().timeIntervalSince(checkedDate)
							guard age >= -600, age <= 24 * 60 * 60 else {
								completion(.unknown("Cert Spotter's non-revoked status is stale (checked \(checkedAt))"))
								return
							}
							completion(.good)
						case .none:
							completion(.unknown("Cert Spotter has no revocation status for the matching issuance"))
						}
						return
					}

					guard let lastID = issuances.last?.id, !issuances.isEmpty else {
						completion(.unknown("certificate is not present in Cert Spotter results"))
						return
					}
					fetchPage(after: lastID, page: page + 1)
				} catch {
					completion(.unknown("invalid Cert Spotter response: \(error.localizedDescription)"))
				}
			}.resume()
		}

		fetchPage(after: nil, page: 0)
	}

	private static func _installSSLCertificateIdentity(_ candidate: SSLIdentityCandidate) throws {
		try _validateIdentityShape(candidate)

		let fileManager = FileManager.default
		let serverDir = URL.documentsDirectory
			.appendingPathComponent("App")
			.appendingPathComponent("Server")
		let stagingDir = serverDir.appendingPathComponent(
			".ssl-update-\(UUID().uuidString)"
		)
		let backupDir = serverDir.appendingPathComponent(
			".ssl-backup-\(UUID().uuidString)"
		)

		defer {
			try? fileManager.removeItem(at: stagingDir)
			try? fileManager.removeItem(at: backupDir)
		}

		do {
			try fileManager.createDirectoryIfNeeded(at: serverDir)
			try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: false)
			try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: false)

			let stagedPEM = stagingDir.appendingPathComponent("server.pem")
			let stagedCRT = stagingDir.appendingPathComponent("server.crt")
			let stagedCommonName = stagingDir.appendingPathComponent("commonName.txt")

			try candidate.privateKey.write(to: stagedPEM, atomically: true, encoding: .utf8)
			try candidate.certificateChain.write(to: stagedCRT, atomically: true, encoding: .utf8)
			try (candidate.commonName + "\n").write(
				to: stagedCommonName,
				atomically: true,
				encoding: .utf8
			)

			try ServerInstaller.validateTLSIdentity(
				certificateURL: stagedCRT,
				privateKeyURL: stagedPEM
			)

			let fingerprint = try _leafFingerprint(from: candidate.certificateChain)
			guard !_isRevokedFingerprint(fingerprint) else {
				throw SSLCertificateUpdateError.revokedCertificate(
					"fingerprint \(fingerprint) is blocked"
				)
			}

			let replacements: [(staged: URL, destination: URL)] = [
				(stagedPEM, serverDir.appendingPathComponent("server.pem")),
				(stagedCRT, serverDir.appendingPathComponent("server.crt")),
				(stagedCommonName, serverDir.appendingPathComponent("commonName.txt")),
			]

			try ServerInstaller.withTLSIdentityLock {
				for replacement in replacements
				where fileManager.fileExists(atPath: replacement.destination.path) {
					try fileManager.copyItem(
						at: replacement.destination,
						to: backupDir.appendingPathComponent(replacement.destination.lastPathComponent)
					)
				}

				do {
					for replacement in replacements {
						if fileManager.fileExists(atPath: replacement.destination.path) {
							_ = try fileManager.replaceItemAt(
								replacement.destination,
								withItemAt: replacement.staged,
								backupItemName: nil,
								options: .usingNewMetadataOnly
							)
						} else {
							try fileManager.moveItem(at: replacement.staged, to: replacement.destination)
						}
					}
				} catch {
					for replacement in replacements {
						try? fileManager.removeItem(at: replacement.destination)
						let backup = backupDir.appendingPathComponent(replacement.destination.lastPathComponent)
						if fileManager.fileExists(atPath: backup.path) {
							try? fileManager.moveItem(at: backup, to: replacement.destination)
						}
					}
					throw error
				}
			}
		} catch let error as SSLCertificateUpdateError {
			throw error
		} catch {
			throw SSLCertificateUpdateError.fileUpdateFailed(error)
		}
	}
	

	/// Password validation straight from memory — the same check as the
	/// file-based one, for callers that already hold the bytes and have no
	/// file to read. Ported with the certificate fixes.
	static func checkPasswordForCertificateData(
		p12Data: Data,
		provisionData: Data,
		password: String
	) -> Bool {
		let tempDir = FileManager.default.temporaryDirectory
		let tempP12 = tempDir.appendingPathComponent("temp_cert.p12")
		let tempProvision = tempDir.appendingPathComponent("temp_provision.mobileprovision")

		defer {
			try? FileManager.default.removeItem(at: tempP12)
			try? FileManager.default.removeItem(at: tempProvision)
		}

		do {
			try p12Data.write(to: tempP12)
			try provisionData.write(to: tempProvision)

			return checkPasswordForCertificate(for: tempP12, with: password, using: tempProvision)
		} catch {
			return false
		}
	}
}
