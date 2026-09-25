//
//  ScreenshotPreviewView.swift
//  Feather
//
//  Created by Nagata Asami on 2/8/25.
//

import SwiftUI
import Nuke
import NukeUI

struct ScreenshotPreviewView: View {
	@Environment(\.dismiss) var dismiss
	@State private var currentIndex: Int
    
	let screenshotURLs: [URL]
    
	init(
		screenshotURLs: [URL],
		initialIndex: Int = 0
	) {
		self.screenshotURLs = screenshotURLs
		self._currentIndex = State(initialValue: initialIndex)
	}
    
	var body: some View {
		NavigationStack {
			_imageScrollView()
				.toolbar {
					ToolbarItem(placement: .topBarLeading) {
						if #available(iOS 26.0, *) {
							Button(role: .close) { dismiss() }
						} else {
							Button(.localized("Close"), role: .cancel) { dismiss() }
						}
					}
					ToolbarItem(placement: .topBarTrailing) {
						if #available(iOS 26.0, *) {
							Text(verbatim: "\(currentIndex + 1) / \(screenshotURLs.count)")
								.font(.subheadline)
								.padding(.horizontal, 12)
								.padding(.vertical, 6)
						} else {
							Text(verbatim: "\(currentIndex + 1) / \(screenshotURLs.count)")
								.font(.subheadline)
								.padding(.horizontal, 12)
								.padding(.vertical, 6)
								.background(
									Capsule()
										.fill(.ultraThinMaterial)
								)
						}
					}
				}
		}
	}
}

extension ScreenshotPreviewView {
	/// The render width the gallery asks the store for — the width the store's
	/// own full-screen gallery requests. The screen can show about twice this
	/// in points at most, and the store's render upscales cleanly.
	private static let renderWidth = 1290

	@ViewBuilder
	private func _imageScrollView() -> some View {
		TabView(selection: $currentIndex) {
			ForEach(screenshotURLs.indices, id: \.self) { index in
				LazyImage(request: ImageRequest(
					url: AppStoreLookup.renderURL(screenshotURLs[index], width: Self.renderWidth),
					processors: [ImageProcessors.Resize(width: CGFloat(Self.renderWidth), unit: .pixels)]
				)) { state in
					if let image = state.image {
						image
							.resizable()
							.aspectRatio(contentMode: .fit)
							.clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
							.overlay {
								RoundedRectangle(cornerRadius: 32, style: .continuous)
									.strokeBorder(.gray.opacity(0.3), lineWidth: 1)
							}
					} else {
						// The card-sized render is almost certainly in the cache
						// from the page this opened from — the blur-up that keeps
						// the gallery from opening on nothing.
						LazyImage(url: AppStoreLookup.probeURL(screenshotURLs[index])) { probe in
							if let image = probe.image {
								image
									.resizable()
									.aspectRatio(contentMode: .fit)
									.blur(radius: 2)
									.clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
							}
						}
					}
				}
				.tag(index)
				.padding(.horizontal)
			}
		}
		.tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
