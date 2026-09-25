//
//  ZsignHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import Foundation
import ZsignSwift
import UIKit

final class ZsignHandler {
	var hadError: Error?
	
	private var _appUrl: URL
	private var _options: Options
	// A value copy of the certificate, taken on the main actor: this handler runs
	// off it, and the `CertificatePair` it comes from is a viewContext object.
	private var _certificate: SigningCertificate?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		certificate: SigningCertificate? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = certificate
	}
	
	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}
		
		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		if !Zsign.removeDylibs(appExecutable: execPath, using: _options.disInjectionFiles) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}
	
	func sign() async throws {
		guard let certificate = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}

		// The return value is read, not discarded.
		//
		// zsign reports in two places and one of them is silent: a failure while
		// signing the bundle calls the completion block with an error, but a bail
		// out *before* that — an unusable app path, a certificate or provisioning
		// profile that will not load — returns non-zero and never calls the block
		// at all. Reading only `hadError` therefore reads nil for those, and the
		// caller went on to move the bundle into `Signed/` and write a Library row
		// for an app that had never been signed. `Zsign.sign` collapses both into
		// its return value, which is why it is the one that decides.
		let signed = Zsign.sign(
			appPath: _appUrl.relativePath,
			provisionPath: certificate.provisionPath,
			p12Path: certificate.certificatePath,
			p12Password: certificate.password,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			removeProvision: !_options.removeProvisioning,
			completion: { _, error in
				self.hadError = error
			}
		)

		try _confirm(signed)
	}

	func adhocSign() async throws {
		let signed = Zsign.sign(
			appPath: _appUrl.relativePath,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			adhoc: true,
			removeProvision: !_options.removeProvisioning,
			completion: { _, error in
				self.hadError = error
			}
		)

		try _confirm(signed)
	}

	/// One error out of zsign's two ways of failing.
	///
	/// The block's error is the more specific one and is preferred when it is
	/// there; the return value is the one that is always there.
	private func _confirm(_ signed: Bool) throws {
		if let hadError { throw hadError }
		guard signed else { throw SigningFileHandlerError.signFailed }
	}
}
