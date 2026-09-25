//
//  FR.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import UIKit.UIImage
import Zsign
import NimbleJSON
import AltSourceKit
import IDeviceSwift

	enum FR {
		static func handlePackageFile(
			_ ipa: URL,
			download: Download? = nil,
			sourceProvenance: SourceAppProvenance? = nil,
			transferID: String? = nil,
			completion: @escaping (Error?) -> Void
		) {
			Task.detached(priority: .userInitiated) {
				let handler = AppFileHandler(
					file: ipa,
					download: download,
					sourceProvenance: sourceProvenance,
					transferID: transferID
				)
			
			do {
				try await handler.copy()
				try await handler.extract()
				try await handler.move()
				try await handler.addToDatabase()
				try? await handler.clean()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	/// Main-actor entry point, because `app` and `certificate` are `viewContext`
	/// objects: the handler copies every value it needs out of them here, and the
	/// detached task below never reads one of them itself.
	@MainActor
	static func signPackageFile(
		_ app: AppInfoPresentable,
		using options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		/// Told as the pipeline moves through its stages, for the surfaces that
		/// report what the app is doing. A caller that has nothing to report it to
		/// leaves it out.
		onStage: (@Sendable (SigningHandler.Stage) -> Void)? = nil,
		completion: @escaping (Error?) -> Void
	) {
		let handler = SigningHandler(app: app, certificate: certificate, options: options)
		handler.appIcon = icon
		handler.onStage = onStage
		
		Task.detached(priority: .userInitiated) {
			do {
				try await handler.copy()
				try await handler.modify()
				try? await handler.clean()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String = "",
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached(priority: .userInitiated) {
			let handler = CertificateFileHandler(
				key: p12URL,
				provision: provisionURL,
				password: p12Password,
				nickname: certificateName.isEmpty ? nil : certificateName,
				isDefault: isDefault
			)
			
			do {
				try await handler.copy()
				try await handler.addToDatabase()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func checkPasswordForCertificate(
		for key: URL,
		with password: String,
		using provision: URL
	) -> Bool {
		defer {
			password_check_fix_WHAT_THE_FUCK_free(provision.path)
		}
		
		password_check_fix_WHAT_THE_FUCK(provision.path)
		
		if (!p12_password_check(key.path, password)) {
			return false
		}
		
		return true
	}
	
	static func movePairing(_ url: URL) {
		let fileManager = FileManager.default
		let dest = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")
		
		try? fileManager.removeFileIfNeeded(at: dest)
		
		try? fileManager.copyItem(at: url, to: dest)
		
		HeartbeatManager.shared.start(true)
	}
	
	static func handleSource(
		_ urlString: String,
		silent: Bool = false,
		competion: @escaping () -> Void
	) {
		guard let url = URL(string: urlString) else { return }
		
		NBFetchService().fetch<ASRepository>(from: url) { (result: Result<ASRepository, Error>) in
			switch result {
			case .success(let data):
				let id = data.id ?? url.absoluteString
				
				// The fetch reports back on a URLSession queue and the store's
				// context is main-queue only, so the existence check and the insert
				// both happen on main. `ASRepository` is a decoded struct, so it is
				// safe to carry across the hop on its own.
				DispatchQueue.main.async {
					if !Storage.shared.sourceExists(id) {
						Storage.shared.addSource(url, repository: data, id: id) { _ in
							competion()
						}
					} else if !silent {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Repository already added."))
					}
				}
			case .failure(let error):
				if !silent {
					DispatchQueue.main.async {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					}
				}
			}
		}
	}
	
	static func exportCertificateAndOpenUrl(using template: String) {
		// Helper that performs the export for a given certificate
		func performExport(for certificate: CertificatePair) {
			guard
				let certificateKeyFile = Storage.shared.getFile(.certificate, from: certificate),
				let certificateKeyFileData = try? Data(contentsOf: certificateKeyFile)
			else {
				return
			}
			
			let base64encodedCert = certificateKeyFileData.base64EncodedString()
			
			var allowedQueryParamAndKey = NSCharacterSet.urlQueryAllowed
			allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")
			
			guard let encodedCert = base64encodedCert.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey) else {
				return
			}
			
			let urlStr = template
				.replacingOccurrences(of: "$(BASE64_CERT)", with: encodedCert)
				.replacingOccurrences(of: "$(PASSWORD)", with: certificate.password ?? "")
			
			guard let callbackUrl = URL(string: urlStr) else {
				return
			}
			
			UIApplication.shared.open(callbackUrl)
		}
		
		let certificates = Storage.shared.getAllCertificates()
		guard !certificates.isEmpty else { return }
		
		DispatchQueue.main.async {
			var selectionActions: [UIAlertAction] = []
			
			for cert in certificates {
				var title: String
				let decoded = Storage.shared.getProvisionFileDecoded(for: cert)
				
				title = cert.nickname ?? decoded?.Name ?? .localized("Unknown")
				
				if let getTaskAllow = decoded?.Entitlements?["get-task-allow"]?.value as? Bool, getTaskAllow == true {
					title = "\(title) (Debug)"
				}
				
				let selectAction = UIAlertAction(title: title, style: .default) { _ in
					performExport(for: cert)
				}
				selectionActions.append(selectAction)
			}
			
			UIAlertController.showAlertWithCancel(
				title: .localized("Export Certificate"),
				message: .localized("Do you want to export your certificate to an external app? That app will be able to sign apps using your certificate."),
				style: .alert,
				actions: selectionActions
			)
		}
	}
}
