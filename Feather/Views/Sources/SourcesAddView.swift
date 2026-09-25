//
//  SourcesAddView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import NimbleViews
import AltSourceKit
import NimbleJSON
import OSLog
import UIKit.UIImpactFeedbackGenerator

// MARK: - View
struct SourcesAddView: View {
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	@Environment(\.dismiss) var dismiss

	private let _dataService = NBFetchService()
	
	@State private var _filteredRecommendedSourcesData: [(url: URL, data: ASRepository)] = []
	private func _refreshFilteredRecommendedSourcesData() {
		let filtered = recommendedSourcesData
			.filter { (url, data) in
				let id = data.id ?? url.absoluteString
				return !Storage.shared.sourceExists(id)
			}
			.sorted { lhs, rhs in
				let lhsName = lhs.data.name ?? ""
				let rhsName = rhs.data.name ?? ""
				return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
			}
		_filteredRecommendedSourcesData = filtered
	}
	
	@State var recommendedSourcesData: [(url: URL, data: ASRepository)] = []
	/// Featured sources the Add sheet recommends. BatSign ships none: the
	/// app has no built-in catalogue and recommends nothing — the sheet is
	/// purely for sources the user brings.
	let recommendedSources: [URL] = []
	
	@State private var _isImporting = false
	@State private var _sourceURL = ""
	
	// MARK: Body
		var body: some View {
			NBNavigationView(.localized("Add Source"), displayMode: .inline) {
				Form {
					if !_filteredRecommendedSourcesData.isEmpty {
						NBSection(.localized("Featured")) {
							ForEach(Array(_filteredRecommendedSourcesData.enumerated()), id: \.offset) { _, entry in
								_featuredCard(entry)
									.listRowInsets(EdgeInsets())
									.listRowBackground(EmptyView())
							}
						}
					}

					NBSection(.localized("Source URL")) {
						TextField(.localized("Enter Source URL"), text: $_sourceURL)
							.keyboardType(.URL)
							.textInputAutocapitalization(.never)
					} footer: {
						Text(.localized("The only supported repositories are AltStore repositories."))
						Text(verbatim: "[\(String.localized("Learn more about how to setup a repository..."))](https://faq.altstore.io/developers/make-a-source)")
					}
				
				Section {
					Button(.localized("Import"), systemImage: "square.and.arrow.down") {
						_isImporting = true
						_fetchImportedRepositories(UIPasteboard.general.string) {
							dismiss()
						}
					}
					
					Button(.localized("Export"), systemImage: "doc.on.doc") {
						let sources = Storage.shared.getSources()
						guard !sources.isEmpty else {
							UIAlertController.showAlertWithOk(
								title: .localized("Error"),
								message: .localized("No sources to export")
							)
							return
						}
						UIPasteboard.general.string = sources.map {
							$0.sourceURL!.absoluteString
						}.joined(separator: "\n")
						UIAlertController.showAlertWithOk(
							title: .localized("Success"),
							message: .localized("Sources copied to clipboard")
						) {
							dismiss()
						}
					}
				}
				
			}
			.toolbar {
				NBToolbarButton(role: .cancel)
				
				if !_isImporting {
					NBToolbarButton(
						.localized("Save"),
						style: .text,
						placement: .confirmationAction,
						isDisabled: _sourceURL.isEmpty
					) {
						FR.handleSource(_sourceURL) {
							dismiss()
						}
					}
				} else {
					ToolbarItem(placement: .confirmationAction) {
						ProgressView()
					}
				}
			}
			.animation(.smooth, value: _filteredRecommendedSourcesData.map { $0.data.id ?? "" })
			.task {
				await _fetchRecommendedRepositories()
			}
		}
	}
	
	private func _fetchRecommendedRepositories() async {
		let fetched = await _concurrentFetchRepositories(from: recommendedSources)
		await MainActor.run {
			recommendedSourcesData = fetched
			_refreshFilteredRecommendedSourcesData()
		}
	}

	/// The featured source's card: icon, name, how many apps it carries, and
	/// the one tap that adds it. Once added it leaves the list — the filter
	/// above drops what the storage already holds.
	private func _featuredCard(_ entry: (url: URL, data: ASRepository)) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				WSAppIcon(url: entry.data.currentIconURL, size: 52, cornerRadius: 12)

				VStack(alignment: .leading, spacing: 3) {
					Text(entry.data.name ?? "Source")
						.font(.system(size: 17, weight: .semibold))
						.foregroundStyle(.primary)
						.lineLimit(1)
					Text(verbatim: _appsText(entry.data))
						.font(.system(size: 13))
						.foregroundStyle(.secondary)
				}

				Spacer(minLength: 8)

				Button {
					BSHaptics.tap()
					Storage.shared.addSource(entry.url, repository: entry.data) { _ in
						_refreshFilteredRecommendedSourcesData()
					}
				} label: {
					Text("Add")
						.font(.system(size: 14, weight: .semibold))
						.foregroundStyle(.white)
						.padding(.horizontal, 18)
						.frame(height: 32)
						.background(BSStore.blue, in: Capsule())
				}
				.buttonStyle(.plain)
			}

			Text(verbatim: entry.url.absoluteString)
				.font(.system(size: 12, design: .monospaced))
				.foregroundStyle(.tertiary)
				.lineLimit(1)
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.bsCard(cornerRadius: 18)
		.padding(.vertical, 4)
	}

	private func _appsText(_ repo: ASRepository) -> String {
		let count = repo.apps.count
		return count == 1 ? "1 app" : "\(count) apps"
	}
	
	private func _fetchImportedRepositories(
		_ code: String?,
		competion: @escaping () -> Void
	) {
		guard let code else { return }
		
		let handler = ASDeobfuscator(with: code)
		let repoUrls = handler.decode().compactMap { URL(string: $0) }
		guard !repoUrls.isEmpty else { return }
		
		Task {
			let fetched = await _concurrentFetchRepositories(from: repoUrls)
			
			let dict = Dictionary(fetched, uniquingKeysWith: { first, _ in first })

			await MainActor.run {
				Storage.shared.addSources(repos: dict) { _ in
					competion()
				}
			}
		}
	}
	
	private func _concurrentFetchRepositories(
		from urls: [URL]
	) async -> [(url: URL, data: ASRepository)] {
		var results: [(url: URL, data: ASRepository)] = []
		
		let dataService = _dataService
		
		await withTaskGroup(of: Void.self) { group in
			for url in urls {
				group.addTask {
					await withCheckedContinuation { continuation in
						dataService.fetch<ASRepository>(from: url) { (result: RepositoryDataHandler) in
							switch result {
							case .success(let repo):
								Task { @MainActor in
									results.append((url: url, data: repo))
								}
							case .failure(let error):
								Logger.misc.error("Failed to fetch \(url): \(error.localizedDescription)")
							}
							continuation.resume()
						}
					}
				}
			}
			await group.waitForAll()
		}
		
		return results
	}

}
