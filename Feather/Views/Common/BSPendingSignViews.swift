//
//  BSPendingSignViews.swift
//  Feather
//
//  The two surfaces the collect system needs: the tray as a person sees it, and
//  the one question the whole mode exists to ask.
//
//  Both read from `BSPendingSign`, the way the run's strip reads from the run —
//  so the prompt, the tray and the run can never describe three different
//  states of the same thing.
//

import SwiftUI

// MARK: - What is waiting

/// The apps that have arrived and not been signed.
///
/// Shown wherever the apps live, and only while there are any. A run in
/// progress is already saying what it is doing, so this says nothing then: two
/// cards describing one job is one card too many.
struct BSPendingSignStrip: View {
	@ObservedObject private var _pending = BSPendingSign.shared
	@ObservedObject private var _bulk = BSBulkSign.shared

	var body: some View {
		if _pending.count > 0, _bulk.run == nil {
			_card
		}
	}

	private var _card: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				ZStack {
					Circle()
						.fill(BS.accent.opacity(0.14))
					Image(systemName: "tray.and.arrow.down.fill")
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(BS.accent)
				}
				.frame(width: 26, height: 26)

				VStack(alignment: .leading, spacing: 2) {
					Text(_headline)
						.font(.subheadline.weight(.semibold))
						.lineLimit(1)

					Text(_pending.names)
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}

				Spacer(minLength: 8)

				Button {
					BSHaptics.tap()
					_pending.signAll()
				} label: {
					Text("Sign All")
						.font(.caption.weight(.semibold))
						.padding(.horizontal, 14)
						.padding(.vertical, 7)
						.bsGlassCapsule(interactive: true)
				}
				.buttonStyle(.plain)
			}

			HStack(spacing: 10) {
				Text("Nothing is signed until you say so.")
					.font(.caption2)
					.foregroundStyle(.secondary)

				Spacer(minLength: 8)

				Button {
					BSHaptics.tap()
					_pending.clear()
				} label: {
					Text("Clear")
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.bsCard(cornerRadius: BS.radiusCard)
		.animation(.snappy(duration: 0.25), value: _pending.items)
	}

	private var _headline: String {
		_pending.count == 1 ? "1 app waiting" : "\(_pending.count) apps waiting"
	}
}

// MARK: - The question

/// The confirmation, attached once to the root view.
///
/// Attached at the root and not to a screen, because an arrival can happen
/// while the person is anywhere — the answer has to be able to find them. It is
/// an alert and not a sheet on purpose: it is one question with two honest
/// answers, and the answer that starts work has to be a deliberate tap.
private struct BSPendingSignPrompt: ViewModifier {
	@ObservedObject private var _pending = BSPendingSign.shared

	func body(content: Content) -> some View {
		content.alert(
			_pending.count == 1 ? "Sign this app?" : "Sign \(_pending.count) apps?",
			isPresented: Binding(
				get: { _pending.isAsking && _pending.count > 0 },
				set: { _pending.isAsking = $0 }
			)
		) {
			Button("Sign All") {
				BSHaptics.tap()
				_pending.signAll()
			}
			Button("Not Yet", role: .cancel) {
				_pending.isAsking = false
			}
		} message: {
			Text(
				_pending.count == 1
					? "\(_pending.names) is ready. Signing starts when you say so."
					: "\(_pending.names) are ready. They sign together, one after another, when you say so."
			)
		}
	}
}

extension View {
	/// Ask before signing anything that has arrived.
	func bsPendingSignPrompt() -> some View {
		modifier(BSPendingSignPrompt())
	}
}
