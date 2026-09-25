//
//  TweakVaultView.swift
//  Feather
//
//  Persistent library of your favorite tweaks, ready to inject
//  into any signing session.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct TweakVaultView: View {
	/// A vault file with its size already resolved, so a row formats a number
	/// instead of stating the file every time it is drawn.
	struct VaultFile {
		let url: URL
		let size: Int64?
	}

	@State private var _files: [VaultFile] = []
	@State private var _isImporting = false
	/// The vault is read off the main thread; the token keeps a read that was
	/// already on its way back from landing over a newer one.
	@State private var _filesToken = UUID()
	@State private var _filesTask: Task<Void, Never>?

	nonisolated static var vaultDirectory: URL {
		URL.documentsDirectory.appendingPathComponent("TweakVault", isDirectory: true)
	}

	nonisolated static func vaultFiles() -> [URL] {
		let directory = vaultDirectory
		try? FileManager.default.createDirectoryIfNeeded(at: directory)
		return (try? FileManager.default.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: [.fileSizeKey],
			options: .skipsHiddenFiles
		))?
		.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending } ?? []
	}

	var body: some View {
		NBNavigationView(.localized("Tweak Vault")) {
			Group {
				if _files.isEmpty {
					emptyState
				} else {
					list
				}
			}
			.toolbar {
				NBToolbarButton(
					systemImage: "plus",
					style: .icon,
					placement: .topBarTrailing
				) {
					_isImporting = true
				}
			}
			.sheet(isPresented: $_isImporting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.dylib, .deb],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }
						for url in urls {
							_store(url)
						}
						_loadFiles()
					}
				)
				.ignoresSafeArea()
			}
			.onAppear { _loadFiles() }
			.onDisappear { _filesTask?.cancel() }
		}
		.navigationTitle(.localized("Tweak Vault"))
	}
}

// MARK: - Sections
extension TweakVaultView {
	private var list: some View {
		List {
			NBSection(.localized("Your Tweaks"), secondary: _files.count.description) {
				ForEach(_files, id: \.url.absoluteString) { file in
					HStack(spacing: 14) {
						Image(systemName: "puzzlepiece.extension.fill")
							.font(.body)
							.foregroundStyle(.tint)
							.frame(width: 30)

						VStack(alignment: .leading, spacing: 3) {
							Text(file.url.lastPathComponent)
								.font(.subheadline.weight(.semibold))
								.lineLimit(2)
							Text(verbatim: file.size.map { $0.formattedByteCount } ?? "")
								.font(.caption2)
								.foregroundStyle(.tertiary)
						}

						Spacer()

						ShareLink(item: file.url) {
							Image(systemName: "square.and.arrow.up")
								.foregroundStyle(.secondary)
						}
						.buttonStyle(.plain)
					}
					.padding(.vertical, 2)
					.contextMenu {
						Button(role: .destructive) {
							try? FileManager.default.removeItem(at: file.url)
							_loadFiles()
						} label: {
							Label(.localized("Delete"), systemImage: "trash")
						}
					}
					.swipeActions(edge: .trailing, allowsFullSwipe: true) {
						Button(role: .destructive) {
							try? FileManager.default.removeItem(at: file.url)
							_loadFiles()
						} label: {
							Label(.localized("Delete"), systemImage: "trash")
						}
					}
				}
			} footer: {
				Text(.localized("Vault tweaks stay here permanently. When signing an app, add them in one tap from Signing → Tweaks."))
			}
		}
	}

	private var emptyState: some View {
		VStack(spacing: 10) {
			Image(systemName: "puzzlepiece.extension")
				.font(.system(size: 40))
				.foregroundStyle(.tint)
			Text("No Tweaks Saved")
				.font(.headline)
			Text("Import the .deb and .dylib tweaks you use most — they'll be one tap away every time you sign.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 32)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

// MARK: - Actions
extension TweakVaultView {
	/// Reads the vault — and stats every file in it — on one background task,
	/// so both listing the folder and sizing its contents stay off the main
	/// thread. A read in flight is superseded rather than left to race: the
	/// older task is cancelled, and the token keeps its result from landing
	/// over a newer one.
	private func _loadFiles() {
		let token = UUID()
		_filesToken = token

		_filesTask?.cancel()
		_filesTask = Task.detached(priority: .utility) {
			let entries = TweakVaultView.vaultFiles().map { url in
				VaultFile(
					url: url,
					size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
				)
			}

			guard !Task.isCancelled else { return }
			await MainActor.run {
				guard _filesToken == token else { return }
				_files = entries
			}
		}
	}

	private func _store(_ url: URL) {
		let secured = url.startAccessingSecurityScopedResource()
		defer { if secured { url.stopAccessingSecurityScopedResource() } }

		let directory = Self.vaultDirectory
		try? FileManager.default.createDirectoryIfNeeded(at: directory)

		var destination = directory.appendingPathComponent(url.lastPathComponent)
		var counter = 1
		while FileManager.default.fileExists(atPath: destination.path) {
			let base = (url.lastPathComponent as NSString).deletingPathExtension
			let ext = (url.lastPathComponent as NSString).pathExtension
			destination = directory.appendingPathComponent("\(base) (\(counter)).\(ext)")
			counter += 1
		}

		try? FileManager.default.copyItem(at: url, to: destination)
	}
}
