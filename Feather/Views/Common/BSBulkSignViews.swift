//
//  BSBulkSignViews.swift
//  Feather
//
//  The two surfaces multi-sign needs and nothing else does: the run's own card
//  inside the app, and the bar that appears under a list while several apps are
//  picked.
//
//  Both are shared rather than written per screen. Library and a source's
//  catalogue are two different lists that answer the same question — "which
//  apps?" — and a person who has used one of them has used the other.
//

import SwiftUI

// MARK: - The run, in the app

/// What a multi-sign run is doing, in the app that started it.
///
/// The island says it outside the app and this says it inside; they are two
/// halves of one job, so this reads from the same run the queue reports to
/// rather than keeping a second opinion of its own.
struct BSBulkSignStrip: View {
	@ObservedObject private var _bulk = BSBulkSign.shared

	var body: some View {
		if let run = _bulk.run {
			_card(run)
		}
	}

	private func _card(_ run: BSBulkSign.Run) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				_ring(run)

				VStack(alignment: .leading, spacing: 2) {
					Text(_headline(run))
						.font(.subheadline.weight(.semibold))
						.lineLimit(1)

					Text(_subtitle(run))
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}

				Spacer(minLength: 8)

				Button {
					BSHaptics.tap()
					if run.isOver {
						_bulk.dismiss()
					} else {
						_bulk.cancel()
					}
				} label: {
					Text(run.isOver ? "Done" : "Stop")
						.font(.caption.weight(.semibold))
						.padding(.horizontal, 14)
						.padding(.vertical, 7)
						.bsGlassCapsule(interactive: true)
				}
				.buttonStyle(.plain)
			}

			ProgressView(value: run.progress)
				.tint(run.failed > 0 ? BS.warning : BS.accent)

			// The names, and only when they are needed: a run where everything
			// landed has already said so everywhere it matters, and a list of
			// what failed is the one thing the cards cannot tell you at once.
			if run.failed > 0 {
				Text(_failures(run))
					.font(.caption2)
					.foregroundStyle(BS.warning)
					.lineLimit(2)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.bsCard(cornerRadius: BS.radiusCard)
		.animation(.snappy(duration: 0.25), value: run.items)
		.animation(.snappy(duration: 0.25), value: run.isOver)
	}

	private func _ring(_ run: BSBulkSign.Run) -> some View {
		ZStack {
			Circle()
				.stroke(Color.primary.opacity(0.12), lineWidth: 3)

			Circle()
				.trim(from: 0, to: max(run.progress, 0.03))
				.stroke(
					run.failed > 0 ? BS.warning : BS.accent,
					style: StrokeStyle(lineWidth: 3, lineCap: .round)
				)
				.rotationEffect(.degrees(-90))

			if run.isOver {
				Image(systemName: run.failed == 0 ? "checkmark" : "exclamationmark")
					.font(.system(size: 11, weight: .bold))
					.foregroundStyle(run.failed == 0 ? BS.success : BS.warning)
			}
		}
		.frame(width: 26, height: 26)
	}

	private func _headline(_ run: BSBulkSign.Run) -> String {
		guard run.isOver else { return run.title }
		if run.isCancelled { return "Run stopped" }
		if run.failed == 0 { return "All \(run.total) signed" }
		return "\(run.signed) of \(run.total) signed"
	}

	private func _subtitle(_ run: BSBulkSign.Run) -> String {
		guard let current = run.current else {
			return run.failed == 0 ? "Nothing left to do" : "See what went wrong below"
		}
		return "\(current.name) — \(current.note) · \(run.position)"
	}

	private func _failures(_ run: BSBulkSign.Run) -> String {
		let names = run.items
			.filter { $0.stage == .failed }
			.map { "\($0.name) (\($0.note.lowercased()))" }
		return names.joined(separator: " · ")
	}
}

// MARK: - Choosing several

/// The bar under a list while apps are being picked for one run.
///
/// It is the whole of the mode: how many are picked, one button that starts the
/// work, one that picks the lot, and a way out. Everything else about the screen
/// is unchanged, so a person who wanted one app never has to look at it.
struct BSBulkActionBar: View {
	let count: Int
	/// The primary button's own words — "Sign 3 Apps", "Download & Sign 3".
	let title: String
	let action: () -> Void
	let selectAll: () -> Void
	let cancel: () -> Void

	var body: some View {
		VStack(spacing: 10) {
			HStack(spacing: 12) {
				VStack(alignment: .leading, spacing: 1) {
					Text(count == 1 ? "1 app selected" : "\(count) apps selected")
						.font(.subheadline.weight(.semibold))
						.monospacedDigit()
					Text(count == 0 ? "Tap apps to add them" : "Signed one after another")
						.font(.caption)
						.foregroundStyle(.secondary)
				}

				Spacer(minLength: 8)

				Button {
					BSHaptics.tap()
					selectAll()
				} label: {
					Text("All")
						.font(.subheadline.weight(.semibold))
						.padding(.horizontal, 14)
						.padding(.vertical, 8)
						.bsGlassCapsule(interactive: true)
				}
				.buttonStyle(.plain)

				Button {
					BSHaptics.tap()
					cancel()
				} label: {
					Text("Cancel")
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(.primary)
						.padding(.horizontal, 14)
						.padding(.vertical, 8)
						.bsGlassCapsule(interactive: true)
				}
				.buttonStyle(.plain)
			}

			Button {
				BSHaptics.tap()
				action()
			} label: {
				Text(title)
			}
			.buttonStyle(BSPrimaryButtonStyle())
			.disabled(count == 0)
			.opacity(count == 0 ? 0.45 : 1)
		}
		.padding(.horizontal, 16)
		.padding(.top, 12)
		.padding(.bottom, 10)
		.background(.bar)
		.overlay(alignment: .top) {
			Rectangle()
				.fill(BS.strokeSoft.opacity(0.4))
				.frame(height: 0.5)
		}
		.transition(.move(edge: .bottom))
	}
}
