//
//  InstallPreview.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import OSLog

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss

	@AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	@State private var _isWebviewPresenting = false
	@State private var progressTask: Task<Void, Never>?
	/// The packaging pass for this sheet, kept so its working copy can be thrown
	/// away once the install has read it.
	@State private var archive: ArchiveHandler?
	
	var app: AppInfoPresentable
	@StateObject var viewModel: InstallerStatusViewModel
	@StateObject var installer: ServerInstaller
	
	@State var isSharing: Bool
	
	init(app: AppInfoPresentable, isSharing: Bool = false) {
		self.app = app
		self.isSharing = isSharing
		let viewModel = InstallerStatusViewModel(isIdevice: UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1)
		self._viewModel = StateObject(wrappedValue: viewModel)
		// This used to be `try! ServerInstaller(...)` inside a view's
		// initialiser: the port can still be held by the install that just
		// finished, and the app was taken down as the sheet opened. The
		// initialiser no longer throws; a failure is a message on the sheet.
		self._installer = StateObject(wrappedValue: ServerInstaller(app: app, viewModel: viewModel))
	}
	
	// MARK: Body
	var body: some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		ZStack {
			InstallProgressView(app: app, viewModel: viewModel)
			_status()
			_button()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(cornerRadius)
		.padding()
		.sheet(isPresented: $_isWebviewPresenting) {
			SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
		}
		.onReceive(viewModel.$status) { newStatus in
			if _installationMethod == 0 {
				if case .ready = newStatus {
					if _serverMethod == 0 {
						// A link the system will not accept is not something to
						// force unwrap: it is said, and the sheet stays open.
						if let link = URL(string: installer.iTunesLink) {
							UIApplication.shared.open(link)
						} else {
							_showInstallError(
								.localized("The install link could not be opened. Please try again.")
							)
						}
					} else if _serverMethod == 1 {
						_isWebviewPresenting = true
					}
				}
				
				if case .sendingPayload = newStatus, _serverMethod == 1 {
					_isWebviewPresenting = false
				}
				
				if case .installing = newStatus {
					if progressTask == nil, let identifier = app.identifier, !identifier.isEmpty {
						progressTask = startInstallProgressPolling(
							bundleID: identifier,
							viewModel: viewModel
						)
					}

					// `.installing` is set once the server has streamed the whole
					// package to installd, so the working copy is finished with and
					// the disk it was using can go now rather than when the system
					// decides to purge the temporary directory.
					if _installationMethod == 0 {
						archive?.clean()
					}
				}
				
				switch newStatus {
				case .completed, .broken(_):
					progressTask?.cancel()
					progressTask = nil
					BSJobKeepAlive.shared.end(BSJobKeepAlive.Reason.manualInstall)
				default:
					break
				}
			}
		}
		.onAppear(perform: _install)
		
		.onAppear {
			// A manual install is the same hand-off as an automatic one and needs
			// the same hold: the screen can be dismissed while installd is still
			// fetching, and the app must not be suspended mid-fetch.
			BSJobKeepAlive.shared.begin(BSJobKeepAlive.Reason.manualInstall)
		}
		
		.onDisappear {
			progressTask?.cancel()
			progressTask = nil
			BSJobKeepAlive.shared.end(BSJobKeepAlive.Reason.manualInstall)
		}
	}
	
	@ViewBuilder
	private func _status() -> some View {
		Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
			.padding()
			.labelStyle(.titleAndIcon)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
			.animation(.smooth, value: viewModel.statusImage)
	}
	
	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if viewModel.isCompleted {
				Button {
					UIApplication.openApp(with: app.identifier ?? "")
				} label: {
					NBButton("Open", systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
	}
	
	private func _install() {
		let ownBundleID = Bundle.main.bundleIdentifier ?? ""

		guard isSharing || (app.identifier ?? "") != ownBundleID || _installationMethod == 1 else {
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			)
			return
		}

		// The local server is the route this method installs through; if it never
		// came up, saying so is the whole difference between a sheet that sits at
		// 0% for ever and one the user can act on.
		if _installationMethod == 0, !installer.isAvailable, let startupError = installer.startupError {
			_showInstallError(
				.localized("The local install server could not start: %@", arguments: startupError.localizedDescription)
			)
			return
		}
				
		Task.detached(priority: .userInitiated) {
			do {
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				await MainActor.run { archive = handler }
				try await handler.move()
				
				let packageUrl = try await handler.archive()
				
				if await !isSharing {
					if await _installationMethod == 0 {
						await MainActor.run {
							installer.packageUrl = packageUrl
							viewModel.status = .ready
						}
						
						if case .installing = await viewModel.status,
						   let identifier = await app.identifier, !identifier.isEmpty {
							let task = await startInstallProgressPolling(
								bundleID: identifier,
								viewModel: viewModel
							)

							await MainActor.run {
								progressTask = task
							}
						}
					} else if await _installationMethod == 1 {
						let handler = await InstallationProxy(viewModel: viewModel)
						try await handler.install(at: packageUrl, suspend: app.identifier == Bundle.main.bundleIdentifier)
						// The tunnel install is synchronous, so the working copy is
						// finished with the moment it returns — the same moment the
						// server path frees it in `.installing`.
						await MainActor.run { archive?.clean() }
					}
				} else {
					let package = try await handler.moveToArchive(packageUrl, shouldOpen: !_useShareSheet)
					// The package has been moved out to the Archives; what is left
					// in the working copy is a full duplicate app payload nobody
					// will read again.
					await MainActor.run { archive?.clean() }
					
					if await !_useShareSheet {
						await MainActor.run {
							dismiss()
						}
					} else {
						if let package {
							await MainActor.run {
								dismiss()
								UIActivityViewController.show(activityItems: [package])
							}
						}
					}
				}
			} catch {
				await progressTask?.cancel()

				// A failed install is also an install that will not stream the
				// package, so the working copy it built goes now.
				await MainActor.run { archive?.clean() }

				await MainActor.run {
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: String(describing: error),
						action: {
							HeartbeatManager.shared.start(true)
							dismiss()
						}
					)
				}
			}
		}
	}

	/// Say what went wrong on the sheet itself, rather than only in the console.
	private func _showInstallError(_ message: String) {
		UIAlertController.showAlertWithOk(
			title: .localized("Install"),
			message: message,
			action: {
				HeartbeatManager.shared.start(true)
				dismiss()
			}
		)
	}
	
	private func startInstallProgressPolling(
		bundleID: String,
		viewModel: InstallerStatusViewModel
	) -> Task<Void, Never> {

		Task.detached(priority: .background) {
			var hasStarted = false

			// Once every 400 ms, which is the cadence the rest of the app reads
			// this same value at. This used to be 1 ms — a thousand wake-ups a
			// second for the length of an install, competing with the install
			// itself for the main thread it was trying to install from.
			let interval: UInt64 = 400_000_000
			var lastLogged = -1.0

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
				}

				let progress = await hasStarted
					? _normalizeInstallProgress(rawProgress)
					: 0.0

				// Only when it moves. The console is how an install is followed
				// on a device, and a line every 400 ms about a number that is not
				// changing is noise rather than evidence.
				if progress != lastLogged {
					lastLogged = progress
					Logger.misc.info("Install progress for \(bundleID, privacy: .public): \(progress)")
				}

				await MainActor.run {
					viewModel.installProgress = progress
				}

				if hasStarted && rawProgress == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}

				try? await Task.sleep(nanoseconds: interval)

				if Task.isCancelled { break }
			}
		}
	}

	private func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
	}
}
