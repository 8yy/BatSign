//
//  SourceAppsDetailView.swift
//  Feather
//
//  An app's page, in the App Store's own arrangement: the icon and the name
//  with its subtitle and action pill, the stats strip, What's New, the shots,
//  the description, and an Information list in the store's label/value shape.
//
//  The one thing that is not a static layout is the bar. At the top of the page
//  the bar carries nothing but its controls; as the header scrolls away the
//  app's own icon takes the bar's centre and the action pill takes its trailing
//  corner, which is how the store keeps the app and its button in reach. That
//  trades on the scroll offset reported below.
//
//  Nothing underneath changed — this is the same source, the same app record
//  and the same action pill the catalogue rows use, drawn the way the store
//  draws an app page.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import Nuke
import NukeUI

// MARK: - Scroll reporting

/// The app page's scroll offset, published out of the content so the bar can
/// trade its title for the app's own identity as the header leaves.
struct BSAppPageOffsetKey: PreferenceKey {
	static var defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = nextValue()
	}
}

/// The page's width, so the carousel knows the screen it is laying shots out on.
struct BSAppPageWidthKey: PreferenceKey {
	static var defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = nextValue()
	}
}

/// Reports how far a scroll view has travelled.
///
/// On iOS 18 and later this asks the scroll view directly, which is both exact
/// and free. The older path measures a probe inside the content against a named
/// coordinate space; it is kept only so the page still works on the versions
/// this app supports below 18.
private struct BSAppPageOffsetReader: ViewModifier {
	let coordinateSpace: String
	let onChange: (CGFloat) -> Void

	func body(content: Content) -> some View {
		if #available(iOS 18.0, *) {
			content.onScrollGeometryChange(for: CGFloat.self) { geometry in
				geometry.contentOffset.y + geometry.contentInsets.top
			} action: { _, newValue in
				onChange(newValue)
			}
		} else {
			content
				.coordinateSpace(name: coordinateSpace)
				.onPreferenceChange(BSAppPageOffsetKey.self) { onChange($0) }
		}
	}
}

struct SourceAppsDetailView: View {
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App

	@State private var _isScreenshotPreviewPresented = false
	@State private var _selectedScreenshotIndex = 0

	/// How far the content has scrolled. Drives the small icon and the action
	/// pill that take over the bar once the header itself has gone.
	@State private var _scrollOffset: CGFloat = 0

	/// The App Store's record for this bundle id, when the store has one. A
	/// repository is a thin catalogue — this is where a rating, an age rating
	/// and a real set of shots come from, and it is asked for once per page.
	@State private var _store: AppStoreLookup.Item?

	/// Width over height for each shot whose source did not declare a shape.
	///
	/// The store's own shots are the case that matters: its URLs carry the size
	/// it was *asked* for, not the size of the image, so the shape can only come
	/// from the image. Reading it through the same pipeline that draws the card
	/// means the shot is in the cache by the time the card appears, which is why
	/// nothing here jumps, letterboxes or crops.
	@State private var _shotShapes: [URL: CGFloat] = [:]

	/// True once the shape pass has finished, whether or not it learned
	/// anything. It is the difference between "not measured yet" and "could not
	/// be measured", and only the first of those is worth waiting on.
	@State private var _shapesResolved = false

	private let _coordinateSpace = "bsAppPage"

	/// The store's own height for a shot: tall enough that a page reads like
	/// the store's does, where the carousel is most of the screen. Fixed, so
	/// the row never reflows as the individual shots arrive.
	private let _shotHeight: CGFloat = 560

	/// The page's own width, so a wide shot can be capped to it rather than
	/// run off a screen it was never meant to cross.
	@State private var _pageWidth: CGFloat = 402

	private var _showsBarIdentity: Bool {
		#if DEBUG
		// `-apppagescrolled`: force the scrolled state so the bar's own control —
		// the one that replaces the header's pill up there — can be looked at
		// without a finger on the screen. A script cannot scroll a simulator, and
		// the alternative is to never see the state this control only exists in.
		if CommandLine.arguments.contains("-apppagescrolled") { return true }
		#endif
		// Far enough that the header's own icon is behind the bar.
		return _scrollOffset > 96
	}

	/// The shots the page shows: the source's own when it published any, and
	/// otherwise the store's. A repository that ships no screenshots is the
	/// common case, and the store's shots are the app's own either way.
	private var _shots: [ASRepository.App.Screenshots.Shot] {
		let published = app.allScreenshots
		return published.isEmpty ? (_store?.screenshots ?? []) : published
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 26) {
				_offsetProbe

				_header()
				_stats()

				_whatsNewSection
				_previewSection
				_descriptionSection
				_informationSection
				_permissionsSection
			}
			.padding(.horizontal, 16)
			.padding(.top, 8)
			.padding(.bottom, 40)
		}
		.background {
			// The scroll view spans the page, so this is the width the carousel
			// has to work with — the one number that cannot be guessed from the
			// shots themselves.
			GeometryReader { proxy in
				Color.clear.preference(key: BSAppPageWidthKey.self, value: proxy.size.width)
			}
		}
		.onPreferenceChange(BSAppPageWidthKey.self) { _pageWidth = $0 }
		.background { BSStoreGround() }
		.task(id: _shotKey) { await _resolveShotShapes() }
		.task(id: app.id) {
			// Whatever the source already published is known before the page is
			// drawn, so it starts downloading first. The App Store's own set, when
			// it arrives, replaces it — and is warmed the moment it does, so the
			// row the user is looking at fills in rather than re-fetching.
			//
			// The card-sized render is what is warmed, not the original: a store
			// shot is a full-size asset, and the card never needs more than the
			// sized variant — warming the original would fill the cache with
			// megabytes the cards will never read.
			BSShotCache.warm(_shots.map { AppStoreLookup.renderURL($0.url, width: BSAppShotCard.renderWidth) })
			BSShotCache.warm(app.iconURL)

			guard let identifier = app.id else { return }
			let item = await AppStoreLookup.item(bundleID: identifier)
			guard !Task.isCancelled else { return }
			BSShotCache.warm(item?.screenshots.map { AppStoreLookup.renderURL($0.url, width: BSAppShotCard.renderWidth) } ?? [])
			_store = item
		}
		.modifier(BSAppPageOffsetReader(coordinateSpace: _coordinateSpace) { _scrollOffset = $0 })
		// The bar carries no title: at the top of the page the header already
		// says what this is, and once it is gone the app's icon says it instead.
		.navigationTitle("")
		.navigationBarTitleDisplayMode(.inline)
		// Every tab that hides its own bar to draw a masthead would otherwise
		// hand its hidden bar down to this page, leaving it with no back button.
		.toolbar(.visible, for: .navigationBar)
		.toolbar {
			ToolbarItem(placement: .principal) {
				BSAppBarIcon(url: app.iconURL, shows: _showsBarIdentity)
			}
			ToolbarItem(placement: .topBarTrailing) {
				// The store's own trade: the share control while the header is
				// on screen, the action pill in its place once it is not.
				if _showsBarIdentity {
					BSGetPill(sourceURL: sourceURL, repository: source, app: app, compact: true, inBar: true)
				} else {
					Button {
						let shared = """
						\(app.currentName) - \(app.currentVersion ?? "0")
						\(app.currentDescription ?? .localized("An awesome application"))
						---
						\(source.website?.absoluteString ?? source.name ?? "")
						"""
						UIActivityViewController.show(activityItems: [shared])
					} label: {
						Image(systemName: "square.and.arrow.up")
					}
					.accessibilityLabel("Share")
				}
			}
		}
		.fullScreenCover(isPresented: $_isScreenshotPreviewPresented) {
			if !_shots.isEmpty {
				ScreenshotPreviewView(
					screenshotURLs: _shots.map(\.url),
					initialIndex: _selectedScreenshotIndex
				)
			}
		}
	}
}

// MARK: - Sections

extension SourceAppsDetailView {
	/// What's New: the build's own notes, its date, and the way into the full
	/// version list when the source publishes one.
	@ViewBuilder
	private var _whatsNewSection: some View {
		if let whatsNew = _whatsNew {
			_section("What's New") {
				VStack(alignment: .leading, spacing: 6) {
					HStack(alignment: .firstTextBaseline) {
						Text("Version \(whatsNew.version)")
							.font(.system(size: 15, weight: .semibold))
						Spacer(minLength: 8)
						if let date = whatsNew.date {
							Text(date.formatted(date: .abbreviated, time: .omitted))
								.font(.system(size: 13))
								.foregroundStyle(BSStore.secondary)
						}
					}
					Text(whatsNew.notes)
						.font(.system(size: 15))
						.foregroundStyle(BSStore.secondary)
						.fixedSize(horizontal: false, vertical: true)

					if let versions = app.versions, versions.count > 1 {
						NavigationLink {
							VersionHistoryView(
								sourceURL: sourceURL,
								source: source,
								app: app,
								versions: versions
							)
							.navigationTitle("Version History")
							.navigationBarTitleDisplayMode(.large)
						} label: {
							Text("Version History")
								.font(.system(size: 15, weight: .semibold))
								.foregroundStyle(BSStore.blue)
						}
						.buttonStyle(.plain)
						.padding(.top, 4)
					}
				}
			}
		}
	}

	/// The shots, when there are any. A repository that publishes none and a
	/// store that knows nothing about the bundle id leaves the section out
	/// entirely rather than showing an empty carousel.
	@ViewBuilder
	private var _previewSection: some View {
		if !_shots.isEmpty {
			_section("Preview") {
				_screenshots(_shots)
			}
		}
	}

	/// The description, from whichever source has one.
	@ViewBuilder
	private var _descriptionSection: some View {
		if let description = _description {
			_section("Description") {
				ExpandableText(text: description, lineLimit: 4)
					.font(.system(size: 15))
					.foregroundStyle(BSStore.secondary)
			}
		}
	}

	/// The entitlements and usage descriptions the package declares, when it
	/// declares any.
	@ViewBuilder
	private var _permissionsSection: some View {
		if let permissions = _permissions {
			_section("Permissions") {
				VStack(alignment: .leading, spacing: 12) {
					ForEach(Array(permissions.enumerated()), id: \.offset) { _, item in
						VStack(alignment: .leading, spacing: 2) {
							Text(item.title)
								.font(.system(size: 15, weight: .semibold))
							if let subtitle = item.subtitle, !subtitle.isEmpty {
								Text(subtitle)
									.font(.system(size: 13))
									.foregroundStyle(BSStore.secondary)
							}
						}
					}
				}
			}
		}
	}

	/// The store's Information list: label on the leading edge, value on the
	/// trailing, hairlines between.
	private var _informationSection: some View {
		_section("Information") {
			VStack(spacing: 0) {
				let rows = _information
				ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
					HStack(alignment: .top) {
						Text(row.label)
							.font(.system(size: 15))
							.foregroundStyle(BSStore.secondary)
						Spacer(minLength: 16)
						Text(row.value)
							.font(.system(size: 15))
							.foregroundStyle(Color.primary)
							.multilineTextAlignment(.trailing)
					}
					.padding(.vertical, 11)

					if index < rows.count - 1 {
						BSHairline()
					}
				}
			}
		}
	}
}
// MARK: - Pieces

extension SourceAppsDetailView {
	/// A zero-height marker inside the content. On iOS 16 and 17 this is the
	/// only way to learn the offset; on 18 and later it is inert.
	@ViewBuilder
	private var _offsetProbe: some View {
		if #unavailable(iOS 18.0) {
			GeometryReader { geometry in
				Color.clear.preference(
					key: BSAppPageOffsetKey.self,
					value: -geometry.frame(in: .named(_coordinateSpace)).minY
				)
			}
			.frame(height: 0)
		}
	}

	/// Icon, name, subtitle and the action pill — the App Store's own header.
	/// The pill sits under the subtitle in the text column, not out beside the
	/// icon, which is how the store keeps the button on the reading line.
	private func _header() -> some View {
		HStack(alignment: .top, spacing: 16) {
			WSAppIcon(url: app.iconURL, size: 104, cornerRadius: 24)

			VStack(alignment: .leading, spacing: 4) {
				Text(app.currentName)
					.font(.system(size: 22, weight: .bold, design: .rounded))
					.lineLimit(2)
					.minimumScaleFactor(0.75)

				// The store's own one-line subtitle sits directly under the
				// name, the way it does on every app page.
				Text(app.subtitle ?? app.developer ?? source.name ?? "App")
					.font(.system(size: 15))
					.foregroundStyle(BSStore.secondary)
					.lineLimit(2)
					.fixedSize(horizontal: false, vertical: true)

				BSGetPill(sourceURL: sourceURL, repository: source, app: app)
					.padding(.top, 10)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	/// The store's stats strip: a hairline above, label over value, vertical
	/// rules between. It bleeds off the trailing edge the way the store's own
	/// strip does.
	///
	/// Only the leading rule is drawn here. Whatever follows — and on a real page
	/// that is always the next section — opens with one of its own, and two rules
	/// a spacing apart read as a double line rather than as a boundary.
	private func _stats() -> some View {
		VStack(spacing: 0) {
			BSHairline()
			HStack(spacing: 0) {
				let columns = _statsColumns
				ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
					if index > 0 { _statDivider }
					_stat(column.eyebrow, column.value, star: column.star)
				}
			}
			.padding(.vertical, 12)
		}
		.padding(.trailing, -16)
	}

	/// The store's strip is its four columns in its own order — version,
	/// rating, age, size. A repository publishes the first and the last of
	/// those; the middle two are the App Store's and appear only when the store
	/// answered for this bundle id. Without them the strip falls back to the
	/// date, which is what a source-only catalogue can honestly fill it with.
	private var _statsColumns: [(eyebrow: String, value: String, star: Bool)] {
		var columns: [(String, String, Bool)] = []

		columns.append(("VERSION", app.currentVersion ?? _store?.version ?? "—", false))

		if let rating = _store?.rating {
			columns.append(("RATING", rating.formatted(.number.precision(.fractionLength(1))), true))
		}
		if let age = _store?.age {
			columns.append(("AGE", age, false))
		}
		if let size = app.size ?? _store?.bytes {
			columns.append(("SIZE", size.formattedByteCount, false))
		}
		if _store?.rating == nil, _store?.age == nil, let date = app.currentDate?.date {
			columns.append(("UPDATED", date.formatted(date: .abbreviated, time: .omitted), false))
		}
		return columns
	}

	private func _stat(_ eyebrow: String, _ value: String, star: Bool = false) -> some View {
		VStack(spacing: 3) {
			Text(eyebrow)
				.font(.system(size: 11, weight: .semibold))
				.tracking(0.4)
				.foregroundStyle(BSStore.secondary)
				.lineLimit(1)
				.minimumScaleFactor(0.7)
			HStack(spacing: 4) {
				Text(value)
					.font(.system(size: 20, weight: .bold, design: .rounded))
					.lineLimit(1)
					.minimumScaleFactor(0.6)
				if star {
					Image(systemName: "star.fill")
						.font(.system(size: 14))
				}
			}
			.foregroundStyle(BSStore.secondary)
		}
		.frame(maxWidth: .infinity)
		.padding(.horizontal, 4)
	}

	private var _statDivider: some View {
		Rectangle()
			.fill(BSStore.separator)
			.frame(width: 0.7, height: 32)
	}

	private func _section<Content: View>(
		_ title: String,
		@ViewBuilder content: () -> Content
	) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			BSHairline()
			BSStoreSectionHeader(title: title)
			content()
		}
	}

	/// The store's shots: fixed height, the source's own shape where it
	/// published one, starting at the page's margin and running off the screen's
	/// trailing edge so the next shot always shows.
	private func _screenshots(_ shots: [ASRepository.App.Screenshots.Shot]) -> some View {
		let size = _cardSize
		// Held back only until the row's shape is known — the whole row is one
		// size, so one measured shot is enough for all of them, and the pass runs
		// in parallel. Once it has finished, they draw regardless: a shot that
		// could not be measured is still a shot, and hiding it for ever is how a
		// Preview goes missing without saying why.
		let ready = _showsShots
		return ScrollView(.horizontal, showsIndicators: false) {
			HStack(alignment: .top, spacing: 10) {
				ForEach(shots.indices, id: \.self) { index in
					let shot = shots[index]
					BSAppShotCard(shot: shot, size: size)
						.opacity(ready ? 1 : 0)
						.animation(.easeOut(duration: 0.18), value: ready)
						.onTapGesture {
							_selectedScreenshotIndex = index
							_isScreenshotPreviewPresented = true
						}
				}
			}
			.padding(.horizontal, 16)
		}
		// Cancels the page's own inset so the carousel spans the screen, then
		// re-applies it inside so the first shot lines up with the page.
		.padding(.horizontal, -16)
		.padding(.bottom, 4)
	}

	// MARK: Shots

	/// What the carousel is showing, as one value, so the shape resolver runs
	/// again when the store's shots arrive — and not on every redraw.
	private var _shotKey: String {
		_shots.map(\.url.absoluteString).joined(separator: "|")
	}

	/// A shot's width over height: whatever its source declared, and otherwise
	/// whatever the image turns out to be. Nil until that is known.
	private func _aspect(for shot: ASRepository.App.Screenshots.Shot) -> CGFloat? {
		if let declared = shot.aspectRatio { return CGFloat(declared) }
		return _shotShapes[shot.url]
	}

	/// The one size every card in this row is drawn at.
	///
	/// The store gives a row of shots one shape, and the row is built around it:
	/// a phone app's shots are all one portrait shape and its cards stand as tall
	/// as the store's own; a landscape game's shots are all wide, and its cards
	/// are wide instead — capped to the page, so a card can never run wider than
	/// the screen it is on. Either way the shots inside are drawn to fit, so
	/// nothing is cropped and nothing is padded.
	private var _cardSize: CGSize {
		let aspect = _rowAspect ?? BSAppShotCard.fallbackAspect

		guard aspect >= 1 else {
			return CGSize(width: _shotHeight * aspect, height: _shotHeight)
		}

		let width = min(_shotHeight * aspect, max(240, _pageWidth - 48))
		return CGSize(width: width, height: width / aspect)
	}

	/// Whether the carousel may draw yet.
	private var _showsShots: Bool {
		_rowAspect != nil || _shapesResolved
	}

	/// The shape the whole row is built around: the first shot's own when it
	/// could be read, and otherwise the first one in the row that could be.
	/// Every card in the row is drawn at this one size, so one honest answer is
	/// all the row needs — and it means a single unreadable first shot cannot
	/// take the whole Preview down with it.
	private var _rowAspect: CGFloat? {
		for shot in _shots {
			if let aspect = _aspect(for: shot) { return aspect }
		}
		return nil
	}

	/// Reads the shape of every shot that did not bring one — all at once.
	///
	/// Serially this was a page that showed nothing until the *last* shot had
	/// been measured: six round trips, one after another, before a single card
	/// could be drawn. In parallel the row is ready in the time of its slowest
	/// single fetch. Every shot the pass touches is cached by the pipeline as it
	/// lands, so the cards come up already filled rather than fading in one by
	/// one as their own fetches complete.
	private func _resolveShotShapes() async {
		// The same shot can be published under both the object and the array
		// form; asking twice for one URL is a wasted request.
		var seen = Set<URL>()
		let unknown = _shots
			.filter { $0.aspectRatio == nil }
			.map(\.url)
			.filter { _shotShapes[$0] == nil && seen.insert($0).inserted }

		guard !unknown.isEmpty else {
			_shapesResolved = true
			return
		}

		let pipeline = ImagePipeline.shared

		await withTaskGroup(of: (URL, CGFloat?).self) { group in
			for url in unknown {
				group.addTask {
					// Measured against the thumbnail, which has the shot's own
					// proportions and is a fraction of the bytes the sharp render
					// is. Measuring against the render itself meant the Preview
					// waited on the heaviest asset the page has.
					let probe = AppStoreLookup.probeURL(url)
					guard let response = try? await pipeline.imageTask(with: probe).response else {
						return (url, nil)
					}
					let size = response.image.size
					guard size.width > 0, size.height > 0 else { return (url, nil) }
					return (url, size.width / size.height)
				}
			}

			// Applied as they land, not collected first. The whole row is built
			// on one shape, so the row is ready the moment *any* shot has been
			// measured — waiting for the slowest of eight was most of the time
			// the Preview spent not being on screen.
			for await (url, aspect) in group {
				if let aspect {
					_shotShapes[url] = aspect
					// The row is built on one shape, so the first one measured is
					// enough to lay it out.
					_shapesResolved = true
				}
			}
		}

		guard !Task.isCancelled else { return }
		_shapesResolved = true
	}

	// MARK: Data

	/// The description the page shows: the source's own when it wrote one, and
	/// otherwise the store's.
	private var _description: String? {
		if let description = app.localizedDescription,
		   !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return description
		}
		return _store?.summary
	}

	private var _whatsNew: (version: String, date: Date?, notes: String)? {
		guard
			let version = app.currentVersion,
			let notes = app.currentAppVersion?.localizedDescription,
			!notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else { return nil }
		return (version, app.currentDate?.date, notes)
	}

	/// The App Store's Information list, in its own order — identifier first,
	/// the store's provenance last.
	private var _information: [(label: String, value: String)] {
		var rows: [(String, String)] = []
		if let identifier = app.id { rows.append(("Bundle ID", identifier)) }
		if let version = app.currentVersion { rows.append(("Version", version)) }
		if let category = app.category ?? _store?.category, !category.isEmpty {
			rows.append(("Category", category))
		}
		if let date = app.currentDate?.date {
			rows.append(("Updated", date.formatted(date: .abbreviated, time: .omitted)))
		}
		if let size = app.size ?? _store?.bytes { rows.append(("Size", size.formattedByteCount)) }
		if let developer = app.developer ?? _store?.developer, !developer.isEmpty {
			rows.append(("Developer", developer))
		}
		if let sourceName = source.name { rows.append(("Source", sourceName)) }
		if let website = source.website?.absoluteString { rows.append(("Website", website)) }
		return rows
	}

	private var _permissions: [(title: String, subtitle: String?)]? {
		guard let permissions = app.appPermissions else { return nil }
		var items: [(String, String?)] = []
		if let entitlements = permissions.entitlements, !entitlements.isEmpty {
			for entitlement in entitlements {
				items.append((entitlement.name, nil))
			}
		}
		if let privacy = permissions.privacy, !privacy.isEmpty {
			for item in privacy {
				items.append((item.name, item.usageDescription))
			}
		}
		return items.isEmpty ? nil : items
	}
}

// MARK: - Shared pieces

/// A single hairline that runs past the page's own margin, the way the store's
/// rules do. Drawn rather than a `Divider` so its weight is the same everywhere.
struct BSHairline: View {
	var body: some View {
		Rectangle()
			.fill(BSStore.separator)
			.frame(height: 0.5)
			.padding(.trailing, -16)
	}
}

/// One of the store's app shots: a card at a fixed height whose width comes
/// from the shot's own shape, the image filling it exactly — the store's rows
/// are uniform and filled, never letterboxed.
struct BSAppShotCard: View {
	let shot: ASRepository.App.Screenshots.Shot
	/// The row's own card size, shared by every shot in it — the store's rows
	/// are uniform, and a row of mixed sizes reads as a mistake.
	let size: CGSize

	/// A plain portrait phone, for the moment before a shape is known.
	static let fallbackAspect: CGFloat = 0.4625

	/// The render width every card asks the store for. One fixed width for the
	/// whole app — the width the store's own pages request for these shots —
	/// so a card, the prefetcher and the cache all agree on one URL per shot
	/// instead of each deriving a width of its own. The card is at most ~354 pt
	/// wide, so 1242 px is at least 3× that: sharp at every scale, and a
	/// fraction of the full-size asset.
	static let renderWidth = 1242

	var body: some View {
		// The sized render first, downsampled as a backstop for the rare shot
		// that is not a store URL and arrives full-size. A full-size decode was
		// most of the page's lag — this request is small by construction.
		LazyImage(request: ImageRequest(
			url: AppStoreLookup.renderURL(shot.url, width: Self.renderWidth),
			processors: [ImageProcessors.Resize(width: CGFloat(Self.renderWidth), unit: .pixels)]
		)) { state in
			if let image = state.image {
				image
					.resizable()
					// Fill, like the store's own cards: the card was shaped from
					// this shot's proportions, so a fill is an exact fit — and for
					// a row with mixed shapes it crops at the edge rather than
					// letterboxing. The probe below fills too, so the shot never
					// changes shape when the sharp render lands.
					.aspectRatio(contentMode: .fill)
			} else if state.error != nil {
				Image(systemName: "photo")
					.font(.system(size: 22))
					.foregroundStyle(BSStore.tertiary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				// The thumbnail this row was measured with, filling in until the
				// sharp render lands. It is already in the pipeline's cache, so it
				// costs nothing — the store's own blur-up: the shot is there at
				// once, and sharpens, rather than the card sitting empty.
				BSShotProbe(url: AppStoreLookup.probeURL(shot.url), size: size)
			}
		}
		.frame(width: size.width, height: size.height)
		.background(BSStore.card)
		.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 18, style: .continuous)
				.strokeBorder(BSStore.separator, lineWidth: 0.6)
		}
	}
}

/// The measuring thumbnail, drawn to fill its card while the sharp shot loads.
///
/// It is a cache hit in every case that matters — the shape pass fetched this
/// exact URL moments earlier — so it turns a blank card into the shot for the
/// price of a decode.
private struct BSShotProbe: View {
	let url: URL
	let size: CGSize

	var body: some View {
		LazyImage(url: url) { state in
			if let image = state.image {
				image
					.resizable()
					.aspectRatio(contentMode: .fill)
					.blur(radius: 1.5)
			} else {
				Color.clear
			}
		}
		.frame(width: size.width, height: size.height)
		.clipped()
	}
}

/// The app's icon in the bar. Kept in the view tree at all times and faded
/// rather than inserted, so the bar's own layout never jumps as the page
/// scrolls past the header.
struct BSAppBarIcon: View {
	let url: URL?
	let shows: Bool

	var body: some View {
		WSAppIcon(url: url, size: 28, cornerRadius: 6.5)
			.opacity(shows ? 1 : 0)
			.animation(.easeInOut(duration: 0.18), value: shows)
			.accessibilityHidden(!shows)
	}
}
