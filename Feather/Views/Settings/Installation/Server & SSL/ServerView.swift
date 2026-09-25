//
//  ServerView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import NimbleViews

struct ServerView: View {
	@AppStorage("Feather.ipFix") private var _ipFix: Bool = false
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	@AppStorage("Feather.batchGroupSize") private var _batchGroupSize: Int = 5
	@State private var _isUpdatingCertificates = false

	private let _serverMethods: [String] = [
		.localized("Fully Local"),
		.localized("Semi Local")
	]

	private let _serverPackUrl = "https://backloop.dev/pack.json"

	var body: some View {
		Group {
			Section {
				Picker(.localized("Installation Type"), systemImage: "server.rack", selection: $_serverMethod) {
					ForEach(_serverMethods.indices, id: \.self) { index in
						Text(_serverMethods[index]).tag(index)
					}
				}
				Toggle(.localized("Only use localhost address"), systemImage: "lifepreserver", isOn: $_ipFix)
					.disabled(_serverMethod != 1)
			}

			Section {
				Stepper(value: $_batchGroupSize, in: 1...100) {
					HStack {
						Image(systemName: "square.stack.3d.up")
						Text(.localized("Apps per prompt"))
						Spacer()
						Text("\(_batchGroupSize)")
							.foregroundStyle(.secondary)
					}
				}
				.disabled(_serverMethod != 0)
			} footer: {
				Text("Fully Local installs can share one confirmation across several apps. This sets how many apps go into each prompt. 1 gives a separate prompt per app.")
			}

			Section {
				Button(.localized("Update SSL Certificates"), systemImage: "arrow.down.doc") {
					guard !_isUpdatingCertificates else { return }
					_isUpdatingCertificates = true

					FR.downloadSSLCertificates(from: _serverPackUrl) { result in
						DispatchQueue.main.async {
							_isUpdatingCertificates = false

							switch result {
							case .success:
								UIAlertController.showAlertWithOk(
									title: .localized("SSL Certificates"),
									message: .localized("Certificates updated successfully.")
								)
							case .failure(let error):
								UIAlertController.showAlertWithOk(
									title: .localized("SSL Certificates"),
									message: "Certificate update failed.\n\n\(error.localizedDescription)"
								)
							}
						}
					}
				}
				.disabled(_isUpdatingCertificates)
			}
		}
		.onChange(of: _serverMethod) { _ in
			UIAlertController.showAlertWithRestart(
				title: .localized("Restart Required"),
				message: .localized("These changes require a restart of the app")
			)
		}
	}
}
