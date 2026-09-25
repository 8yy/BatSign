//
//  BSStore.swift
//  Feather
//
//  The App Store's own language, rebuilt for this storefront: the palette, the
//  ground, the Today story card and the action pill.
//
//  Two things here are load-bearing rather than cosmetic:
//
//  * The story card measures its artwork before using it as a banner. AltStore
//    sources put a square app icon in the `headerURL` slot, and stretching one
//    across a 330-pt card is what turns a feed into a wall of blown-up icons.
//    Genuinely wide artwork is drawn sharp; anything else becomes the App
//    Store's blurred-artwork ground.
//
//  * The pill reports what is *actually* happening. A download reports its own
//    byte progress, and the install half is read from the system's own install
//    progress for the bundle id, so the pill never claims "done" for a package
//    that was only signed and never landed on the Home Screen.
//

import SwiftUI
import Combine
import CoreData
import AltSourceKit
import NukeUI
import NimbleViews

// MARK: - Palette

/// The App Store's palette. Semantic colours on purpose: in dark mode this is
/// the storefront's black ground with #1C1C1E cards, and in light mode the same
/// layout in light greys — one set of tokens, both appearances correct.
enum BSStore {
	static var ground: Color { Color(uiColor: .systemBackground) }
	static var card: Color { Color(uiColor: .secondarySystemBackground) }
	static var cardElevated: Color { Color(uiColor: .tertiarySystemBackground) }
	static var separator: Color { Color(uiColor: .separator) }
	static var secondary: Color { Color(uiColor: .secondaryLabel) }
	static var tertiary: Color { Color(uiColor: .tertiaryLabel) }
	static var blue: Color { BS.accent }

	/// "THURSDAY, SEPTEMBER 12".
	static var eyebrowFont: Font { .footnote.weight(.semibold) }

	/// The card's artwork area. Fixed, so a card's height never depends on how
	/// long a source's description happens to be.
	static let bannerHeight: CGFloat = 330
}

// MARK: - Ground

/// The storefront's ground: the system background, edge to edge. The App Store
/// is not a slab of its own colour, and neither is this.
struct BSStoreGround: View {
	var body: some View {
		BSStore.ground.ignoresSafeArea()
	}
}

extension View {
	/// What every storefront screen sits on.
	func bsStoreScreen() -> some View {
		self.background { BSStoreGround() }
	}
}

// MARK: - Artwork ground

/// A remote image that fills its frame, or a colour while it loads.
private struct BSFill: View {
	let url: URL
	let fallback: Color

	var body: some View {
		LazyImage(url: url) { state in
			if let image = state.image {
				image
					.resizable()
					.aspectRatio(contentMode: .fill)
			} else {
				fallback
			}
		}
	}
}

// MARK: - Story card

/// The Today feed's card, the App Store's signature surface: a tall banner with
/// the category eyebrow and a huge title over the artwork, then the info strip
/// — icon, name, one grey line, and its own Get pill.
struct BSStoryCard: View {
	let source: AltSource
	let repository: ASRepository
	let app: ASRepository.App

	/// The banner URL once it has been measured and found wide. Nil while the
	/// shape is unknown and for artwork that turned out to be square; both draw
	/// the card's own ground, so a card never jumps from a stretched icon to a
	/// correct banner.
	@State private var wideBanner: URL?
	/// A colour lifted from the app's own icon, for sources that publish no
	/// tint of their own.
	@State private var iconTint: Color?

	/// The only banner slot an AltStore source publishes lives on the repository
	/// itself; individual apps carry an icon, not a header. When the repository's
	/// header is missing — or turns out to be a square icon in a banner's slot —
	/// the card falls back to the blurred-artwork ground.
	private var bannerCandidate: URL? {
		repository.headerURL
	}

	private var tint: Color {
		app.tintColor
			?? repository.tintColor
			?? iconTint
			?? Color.bsIdentifierTint(app.currentName)
	}

	private var eyebrow: String {
		if let category = app.category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty {
			return category
		}
		return "TODAY"
	}

	private var summary: String {
		let text = app.localizedDescription ?? app.developer ?? repository.name ?? source.name ?? ""
		return text
			.replacingOccurrences(of: "\n", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// The artwork the blurred ground is made of — the source's own header when
	/// it publishes one, else the app icon. Nil only when there is no artwork
	/// at all, and the tint is then the whole ground.
	private var artworkUnderlay: URL? {
		bannerCandidate ?? app.iconURL
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			banner
			infoStrip
		}
		.background(BSStore.card)
		.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
		.shadow(color: .black.opacity(0.35), radius: 16, y: 8)
		.task(id: bannerCandidate) {
			guard let candidate = bannerCandidate else {
				wideBanner = nil
				return
			}
			wideBanner = await BSArtwork.shared.isWide(candidate) ? candidate : nil
		}
		.task(id: app.iconURL) {
			guard iconTint == nil, let icon = app.iconURL else { return }
			iconTint = await BSArtwork.shared.dominantColor(icon)
		}
	}

	/// The artwork area.
	///
	/// Sized by a colour and then decorated with backgrounds and overlays, never
	/// assembled as ZStack siblings: a fill-cropped image has no intrinsic size,
	/// so as a sibling it inflates the stack and pushes the story text past the
	/// card's fixed height where the strip below clips it. Overlays are sized by
	/// their parent, so the artwork cannot move the text.
	private var banner: some View {
		Color.clear
			.frame(height: BSStore.bannerHeight)
			.background { bannerGround }
			.overlay { scrim }
			.overlay(alignment: .bottomLeading) { storyText }
			.clipped()
	}

	@ViewBuilder
	private var bannerGround: some View {
		// The ground: the app's or source's own tint, so every card is
		// recognisably that app's before a word is read. Held back whenever real
		// artwork sits under it, so the artwork's colours lead.
		LinearGradient(
			colors: [
				tint.opacity(wideBanner == nil ? 0.9 : 0.5),
				tint.opacity(wideBanner == nil ? 0.35 : 0.16),
			],
			startPoint: .topLeading,
			endPoint: .bottomTrailing
		)

		if let wideBanner {
			BSFill(url: wideBanner, fallback: Color.clear)
		} else if let artworkUnderlay {
			// No wide banner: the App Store's blurred-artwork ground. The
			// artwork is blown up and thrown out of focus under the tint rather
			// than shown as itself — the icon is already in the strip below, and
			// lifting it into the banner is what made the feed read as a wall of
			// app icons instead of a storefront.
			//
			// Overscanned before it is blurred. A blur samples past its own
			// bounds and feathers the result, which is what leaves a pale rim
			// inside the card's rounded corners; pushing the layer wider than
			// the card moves that soft edge outside the clip, so the artwork
			// reaches all four corners, corner curves included.
			BSFill(url: artworkUnderlay, fallback: Color.clear)
				.scaleEffect(1.34)
				.blur(radius: 34, opaque: true)
				.saturation(1.5)
				.opacity(0.92)
		}
	}

	/// The scrim the text sits on. It starts low because the ground is a blur:
	/// the artwork has no hard edges for the title to fight, so only the bottom
	/// third needs holding down.
	private var scrim: some View {
		LinearGradient(
			stops: [
				.init(color: .clear, location: 0.1),
				.init(color: .black.opacity(0.22), location: 0.5),
				.init(color: .black.opacity(0.88), location: 1),
			],
			startPoint: .top,
			endPoint: .bottom
		)
	}

	private var storyText: some View {
		VStack(alignment: .leading, spacing: 7) {
			Text(eyebrow.uppercased())
				.font(.system(size: 12, weight: .semibold))
				.tracking(0.9)
				.foregroundStyle(.white.opacity(0.85))
			Text(app.currentName)
				.font(.system(size: 29, weight: .bold, design: .rounded))
				.foregroundStyle(.white)
				.lineLimit(2)
				.minimumScaleFactor(0.7)
			Text(summary)
				.font(.system(size: 14))
				.foregroundStyle(.white.opacity(0.8))
				.lineLimit(2)
				.multilineTextAlignment(.leading)
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 16)
		.padding(.bottom, 16)
		.shadow(color: .black.opacity(0.55), radius: 8, y: 2)
	}

	private var infoStrip: some View {
		HStack(spacing: 12) {
			// The same 60 the catalogue rows use. The strip itself carries the
			// card's colour as a darker glass below, so the icon stays flat on
			// it — a pane of its own would double the brand. The strip icon used
			// to be drawn a step smaller, which made the identical file read as a
			// lower-resolution asset on Today than on Apps.
			WSAppIcon(url: app.iconURL, size: 60, cornerRadius: 13.5)

			VStack(alignment: .leading, spacing: 2) {
				Text(app.currentName)
					.font(.system(size: 15, weight: .semibold))
					.lineLimit(1)
				Text(app.developer ?? repository.name ?? source.name ?? "App")
					.font(.system(size: 13))
					.foregroundStyle(BSStore.secondary)
					.lineLimit(1)
			}

			Spacer(minLength: 8)

			BSGetPill(sourceURL: source.sourceURL, repository: repository, app: app)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 13)
		// The App Store's strip: the card's own colour carried down past the
		// artwork as a darker glass, so the icon and the button stand on the
		// brand instead of on the card's flat grey. The screen's own ground
		// under the tint is what makes it darker than the banner above it.
		.background {
			ZStack {
				Color(uiColor: .systemBackground)
				LinearGradient(
					colors: [tint.opacity(0.40), tint.opacity(0.12)],
					startPoint: .topLeading,
					endPoint: .bottomTrailing
				)
			}
		}
	}
}

// MARK: - Story card link

/// A story card that opens the app's page when the card is tapped — and whose
/// pill still works.
///
/// Wrapping the card in a `NavigationLink` is what breaks the pill: SwiftUI
/// resolves a link's whole label as one control, so the nested button never
/// sees the touch and tapping GET navigates instead of downloading. A card
/// built the other way — a `NavigationLink(isActive:)` hidden beside the card
/// — is worse than that: the deprecation it rests on no longer drives a
/// `NavigationStack` reliably, and cards stop responding anywhere in the feed.
///
/// So the card is a plain view with a tap gesture, and the feed that owns the
/// stack does the pushing. Gestures resolve to the innermost view that handles
/// them, which leaves the pill free to be a real button, and the navigation no
/// longer depends on a dead API or on a card's own `@State` surviving the lazy
/// stack recycling it.
struct BSStoryCardLink: View {
	let source: AltSource
	let repository: ASRepository
	let app: ASRepository.App
	/// What the feed does when the card — and not the pill — is tapped.
	let onOpen: () -> Void

	var body: some View {
		BSStoryCard(source: source, repository: repository, app: app)
			.contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
			.onTapGesture(perform: onOpen)
	}
}

// MARK: - List row

/// One catalogue row: 60-pt icon, 17-pt semibold name, one grey line, hairline
/// separator inset to the text, and the pill trailing.
struct BSStoreRow: View {
	let storedSource: AltSource
	let sourceURL: URL?
	let repository: ASRepository
	let app: ASRepository.App
	var showsSeparator: Bool = true
	var showsChevron: Bool = false
	/// Whether the row carries its GET pill. Kept switchable because a row can
	/// also be *picked* — a multi-sign run takes several apps at once, and a
	/// pill that downloads one of them belongs to the other mode.
	var showsPill: Bool = true

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 12) {
				WSAppIcon(url: app.iconURL, size: 60, cornerRadius: 13.5)

				VStack(alignment: .leading, spacing: 2) {
					Text(app.currentName)
						.font(.system(size: 17, weight: .semibold))
						.lineLimit(1)
					Text(verbatim: subtitle)
						.font(.system(size: 14))
						.foregroundStyle(BSStore.secondary)
						.lineLimit(1)
				}

				Spacer(minLength: 8)

				if showsPill {
					BSGetPill(sourceURL: sourceURL, repository: repository, app: app)
				}

				if showsChevron {
					Image(systemName: "chevron.forward")
						.font(.footnote.weight(.semibold))
						.foregroundStyle(BSStore.tertiary)
				}
			}
			// The App Store's row is 10 pt of padding around a 60-pt icon.
			.padding(.vertical, 10)

			if showsSeparator {
				Rectangle()
					.fill(BSStore.separator)
					.frame(height: 0.5)
			}

		}
		.padding(.horizontal, 16)
		.contentShape(Rectangle())
	}

	private var subtitle: String {
		if let category = app.category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty {
			return category
		}
		if let developer = app.developer?.trimmingCharacters(in: .whitespacesAndNewlines), !developer.isEmpty {
			return developer
		}
		return repository.name ?? storedSource.name ?? "App"
	}
}

// MARK: - Headers

/// The Today masthead: the date eyebrow and the huge title.
struct BSStoreHeroHeader: View {
	let eyebrow: String
	let title: String

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			Text(eyebrow.uppercased())
				.font(BSStore.eyebrowFont)
				.foregroundStyle(BSStore.secondary)
			Text(title)
				.font(.system(size: 34, weight: .bold, design: .rounded))
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

/// A section heading: big bold title, optional trailing link or count.
struct BSStoreSectionHeader: View {
	let title: String
	var trailing: String?

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Text(title)
				.font(.system(size: 22, weight: .bold, design: .rounded))
			Spacer(minLength: 12)
			if let trailing {
				Text(trailing)
					.font(.system(size: 15))
					.foregroundStyle(BSStore.blue)
			}
		}
	}
}

/// A filter chip: capsule with an optional symbol, selected state in blue.
struct BSStoreChip: View {
	let title: String
	var symbol: String?
	let selected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let symbol {
					Image(systemName: symbol)
						.font(.system(size: 13, weight: .semibold))
				}
				Text(title)
					.font(.system(size: 15, weight: .semibold))
			}
			.foregroundStyle(selected ? BSStore.blue : Color.primary)
			.padding(.horizontal, 14)
			.frame(height: 36)
			.background(selected ? BSStore.blue.opacity(0.16) : BSStore.cardElevated, in: Capsule())
		}
		.buttonStyle(.plain)
	}
}

// MARK: - The pill

/// What the pill is doing for one app, derived only from state the app can
/// actually observe.
enum BSPillState: Equatable {
	case get
	/// A transfer with real byte progress.
	case downloading(Double)
	/// Unpacking, signing, or waiting in the queue — work with no fraction.
	case signing
	/// The system is installing the package, at its own reported fraction.
	case installing(Double)
	/// The app is on the Home Screen.
	case open
	/// Nothing downloadable.
	case unavailable

	/// The store's own casing: the button is set in caps, and the width follows
	/// from the word rather than from a fixed frame.
	var label: String {
		switch self {
		case .get: return "GET"
		case .signing: return ""
		case .installing: return ""
		case .downloading: return ""
		case .open: return "OPEN"
		case .unavailable: return ""
		}
	}
}

/// The App Store's action pill — a neutral capsule with the tint's own blue
/// type on it, becoming a bare progress ring while work is in flight. One
/// derivation feeds every row and card, so two surfaces cannot disagree.
struct BSGetPill: View {
	let sourceURL: URL?
	let repository: ASRepository?
	let app: ASRepository.App
	/// The bar's own copy. A navigation bar carries a step smaller control than
	/// a list row does, and drawing the row's pill at the row's size up there is
	/// what made the scrolled state read as a button that had been misplaced.
	var compact: Bool = false
	/// Whether this pill is drawn *inside* the navigation bar — the GET that
	/// takes the header's place in the top-right corner as a detail page
	/// scrolls.
	///
	/// It changes one thing, and it is the thing that made that control look
	/// broken: the surface. A toolbar item on iOS 26 is already given the
	/// system's Liquid Glass, and adjacent items are grouped into a single
	/// capsule around it, so a pill that paints a glass surface of its own up
	/// there is two glasses stacked on one another — which renders as a
	/// washed-out slab rather than as a capsule. In the bar on 26 the surface is
	/// the system's, and below 26 the system draws nothing, so the app's own
	/// fallback is the only one there is and stands as it always did.
	var inBar: Bool = false

	@ObservedObject private var downloadManager = DownloadManager.shared
	@ObservedObject private var autoSignManager = AutoSignManager.shared

	@FetchRequest private var signedApps: FetchedResults<Signed>

	/// The transfer's own numbers, relayed from the `Download` itself.
	///
	/// The manager only republishes when the queue changes, so a view observing
	/// nothing but the manager would draw a ring that never moved — which is
	/// exactly how the storefront's ring used to behave next to the download
	/// header's. These two mirrors are fed by the download's own publishers, so
	/// the ring tracks the bytes as they arrive and animates between them.
	@State private var _fileProgress: Double = 0
	@State private var _unpackageProgress: Double = 0

	/// The system's own install fraction for this bundle id, polled only while
	/// an install is plausibly running.
	@State private var installFraction: Double?
	@State private var presentingInstall: Signed?

	init(
		sourceURL: URL?,
		repository: ASRepository?,
		app: ASRepository.App,
		compact: Bool = false,
		inBar: Bool = false
	) {
		self.sourceURL = sourceURL
		self.repository = repository
		self.app = app
		self.compact = compact
		self.inBar = inBar

		let identifier = app.id ?? ""
		_signedApps = FetchRequest(
			entity: Signed.entity(),
			sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
			predicate: NSPredicate(format: "identifier == %@", identifier),
			animation: .snappy
		)
	}

	// MARK: Derivation

	private var download: Download? {
		// The store's own install is keyed by the catalogue id, the one the row
		// is built from.
		if let storeDownload = downloadManager.getDownload(by: app.currentUniqueId) {
			return storeDownload
		}

		// An update is a different job with a different id: it is started from
		// the Updates tab or the Library under a prefix that carries the *local*
		// app's uuid, which the catalogue row has no reason to know. Matching it
		// here by download URL is what keeps the pill honest in both places —
		// the row was showing "GET" beside an app that was already fetching,
		// which is the one thing a pill must not do.
		guard let downloadURL = app.currentDownloadUrl else { return nil }
		return downloadManager.downloads.first { $0.url == downloadURL }
	}

	private var newestSigned: Signed? {
		signedApps.first
	}

	private var jobInFlight: Bool {
		guard let identifier = app.id else { return false }
		if let current = autoSignManager.currentJob, current.appIdentifier == identifier { return true }
		return autoSignManager.queue.contains { $0.appIdentifier == identifier }
	}

	/// The real answer, from the system, not from our own bookkeeping.
	private var isInstalled: Bool {
		if let installFraction, installFraction >= 0.999 { return true }
		return false
	}

	// MARK: Transfer

	/// The fraction the ring reports while a transfer runs.
	///
	/// The transfer's own bytes, and nothing else. The download header narrates
	/// transfer and unpacking as a single bar, which is honest for a header and
	/// wrong for this ring: blended the same way, the ring stops at 70% the
	/// instant the file lands, which is what "the download never reaches the
	/// end" looked like.
	private var _transferFraction: Double {
		guard let download else { return 0 }
		return download.onlyArchiving ? _unpackageProgress : _fileProgress
	}

	/// True once there is nothing left to move — the transfer's half of the job
	/// is over, and everything after it is a phase with a name of its own.
	private var _transferIsComplete: Bool { _transferFraction >= 0.999 }

	private var state: BSPillState {
		if download != nil {
			return _transferIsComplete ? .signing : .downloading(_transferFraction)
		}
		if jobInFlight {
			// Signing first, then the system's own install progress. Only a
			// genuine install fraction above zero means the package has left
			// our hands and iOS has started putting it on the Home Screen.
			if let installFraction, installFraction > 0, installFraction < 0.999 {
				return .installing(installFraction)
			}
			if isInstalled { return .open }
			return .signing
		}
		if let installFraction, installFraction > 0, installFraction < 0.999 {
			return .installing(installFraction)
		}
		if isInstalled { return .open }
		if app.currentDownloadUrl == nil { return .unavailable }
		// A package is signed and waiting. That is an invitation to install,
		// not a ring: work that is not running must never be drawn as work.
		if newestSigned != nil { return .installing(1) }
		return .get
	}

	// MARK: Body

	/// A ring means a fraction is genuinely in flight. A finished install is a
	/// word — "Install" — and drawing it as a full ring hid the one control
	/// that could still do something.
	private var isRing: Bool {
		switch state {
		case .downloading: return true
		case .installing(let fraction): return fraction < 0.999
		default: return false
		}
	}

	// MARK: Metrics

	/// Whether the toolbar's own glass is the surface for this pill.
	///
	/// True only for the bar on 26: below that the system draws no surface
	/// around a toolbar item, so the app's fallback material is the only one
	/// there is.
	private var _leavesSurfaceToTheSystem: Bool {
		guard inBar else { return false }
		if #available(iOS 26.0, *) { return true }
		return false
	}

	/// The store's own control: 30 pt tall in a list, a step smaller in a bar,
	/// as wide as its word needs and no wider.
	private var _height: CGFloat { compact ? 28 : 30 }
	private var _ringSide: CGFloat { compact ? 22 : 24 }
	private var _ringBoxWidth: CGFloat { compact ? 32 : 36 }
	/// The store's own side padding on its button. Wide enough that "GET"
	/// reads as a control and not as a word.
	private var _labelInset: CGFloat { compact ? 16 : 18 }

	var body: some View {
		Button(action: _act) {
			// The shell is the content's *background*, not a sibling in a stack.
			// A `Capsule` is a flexible shape and takes whatever width it is
			// offered, so as a sibling it made the whole pill greedy — the label
			// stopped sizing the button and the button stretched across the row.
			// A background is laid out from the content, which is the store's
			// own arrangement: the word decides the width.
			_content
				.background {
					if !isRing, !_leavesSurfaceToTheSystem {
						// The store's own shell: a neutral capsule, so the tint is
						// carried by the type rather than by the fill — and the
						// surface itself is the system's Liquid Glass where there is
						// one. This is the storefront's most-tapped control, and it
						// was the last place still painting a flat system fill while
						// every other pill in the app drew glass.
						Color.clear.bsGlassCapsule(interactive: true)
					}
				}
				.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.disabled(state == .unavailable || state == .signing)
		.animation(.spring(response: 0.3, dampingFraction: 0.8), value: state)
		.sheet(item: $presentingInstall) { signed in
			InstallPreviewView(app: signed)
		}
		// The transfer's own publishers, not the manager's queue.
		.onReceive(_fileProgressValues) { _fileProgress = $0 }
		.onReceive(_unpackageValues) { _unpackageProgress = $0 }
		.task(id: _pollKey) { await _watchInstall() }
	}

	@ViewBuilder
	private var _content: some View {
		switch state {
		case .downloading(let fraction):
			BSProgressRing(fraction: fraction, size: _ringSide, lineWidth: 2.4, showsStop: true)
				.frame(width: _ringBoxWidth, height: _height)
		case .installing(let fraction):
			if fraction >= 0.999 {
				_label("INSTALL")
			} else {
				BSProgressRing(fraction: fraction, size: _ringSide, lineWidth: 2.4, showsStop: false)
					.frame(width: _ringBoxWidth, height: _height)
			}
		case .signing:
			ProgressView()
				.controlSize(.small)
				.tint(BSStore.blue)
				.frame(width: _ringBoxWidth, height: _height)
		default:
			_label(state.label)
		}
	}

	private func _label(_ text: String) -> some View {
		Text(text)
			.font(.system(size: 15, weight: .semibold))
			.tracking(0.4)
			.foregroundStyle(BSStore.blue)
			.padding(.horizontal, _labelInset)
			.frame(height: _height)
	}

	/// Nil-safe relays of the download's own progress publishers, so the ring
	/// re-renders when a byte arrives rather than only when the queue moves.
	private var _fileProgressValues: AnyPublisher<Double, Never> {
		download?.$progress.eraseToAnyPublisher() ?? Empty<Double, Never>().eraseToAnyPublisher()
	}

	private var _unpackageValues: AnyPublisher<Double, Never> {
		download?.$unpackageProgress.eraseToAnyPublisher() ?? Empty<Double, Never>().eraseToAnyPublisher()
	}

	// MARK: Actions

	private func _act() {
		BSHaptics.tap()
		switch state {
		case .get:
			guard let url = app.currentDownloadUrl else { return }
			_ = downloadManager.startDownload(
				from: url,
				id: app.currentUniqueId,
				bundleID: app.id,
				sourceProvenance: _provenance(),
				expectedBytes: app.size ?? 0
			)
		case .downloading:
			// The ring is a stop button: tapping a running transfer cancels it
			// and the pill falls back to GET.
			if let download { downloadManager.cancelDownload(download) }
		case .installing(let fraction):
			if fraction >= 0.999, let signed = newestSigned {
				presentingInstall = signed
			}
		case .open:
			UIApplication.openApp(with: app.id ?? "")
		case .signing, .unavailable:
			break
		}
	}

	// MARK: Install probe

	/// Re-arms the probe whenever the picture changes: a new job, a new signed
	/// package, or a transfer starting.
	private var _pollKey: String {
		let job = jobInFlight ? "1" : "0"
		let signed = newestSigned?.date?.timeIntervalSince1970.description ?? "0"
		let downloading = download != nil ? "1" : "0"
		return "\(job)|\(signed)|\(downloading)"
	}

	/// Reads the system's install progress — and whether the app is on the
	/// device at all — until the install lands, or until it is clear that
	/// nothing is installing any more. Called off the main actor because it
	/// reaches SpringBoard's workspace, and only while there is something to
	/// watch.
	///
	/// Two things end the watch, and both matter. The system saying the bundle
	/// is installed is the truth this pill exists to report. Failing that,
	/// installd's progress object simply goes away once the package has landed,
	/// which is how the app's own install screen has always read it. A number
	/// that has not moved for three quarters of a minute, with no install and no
	/// progress behind it, is a leftover — and the pill must not sit in a ring
	/// for ever because a transfer was refused or a job died.
	private func _watchInstall() async {
		guard jobInFlight || newestSigned != nil else {
			installFraction = nil
			return
		}
		guard let identifier = app.id else { return }

		let deadline = Date().addingTimeInterval(240)
		/// Long enough to outlast a slow package, short enough that a dead
		/// install does not hold the ring for minutes.
		let stall: TimeInterval = 45

		var started = false
		var lastValue: Double?
		var lastChange = Date()

		while !Task.isCancelled, Date() < deadline {
			let probe = await Task.detached(priority: .utility) {
				(
					UIApplication.installProgress(for: identifier),
					UIApplication.isInstalled(identifier)
				)
			}.value

			if probe.1, started {
				installFraction = 1
				return
			}

			if let fraction = probe.0, fraction > 0 {
				started = true
				if fraction != lastValue {
					lastValue = fraction
					lastChange = Date()
				}
				installFraction = fraction
				if fraction >= 0.999 { return }
			} else if started {
				// Started, and now nothing is reported: that is a finished
				// install, which is how a landing has always been read here.
				installFraction = 1
				return
			}

			if started, Date().timeIntervalSince(lastChange) > stall { break }

			try? await Task.sleep(nanoseconds: 400_000_000)
		}

		// Nothing is installing any more, and the system never said it landed.
		// Drop what we learned so the pill falls back to the package it holds —
		// an "Install" the user can actually tap.
		installFraction = nil
	}

	private func _provenance() -> SourceAppProvenance? {
		guard let repository else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: repository, app: app)
	}
}

// MARK: - Progress ring

/// The App Store's download ring: a blue arc over a faint track, with the
/// rounded stop bar in the middle while a transfer can still be cancelled.
struct BSProgressRing: View {
	let fraction: Double
	var size: CGFloat = 32
	var lineWidth: CGFloat = 2.5
	var showsStop = true

	var body: some View {
		ZStack {
			Circle()
				.stroke(BSStore.blue.opacity(0.2), lineWidth: lineWidth)
			Circle()
				.trim(from: 0, to: max(0.02, min(1, fraction)))
				.stroke(BSStore.blue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
				.rotationEffect(.degrees(-90))
			if showsStop {
				RoundedRectangle(cornerRadius: 1.5, style: .continuous)
					.fill(BSStore.blue)
					.frame(width: size * 0.26, height: size * 0.26)
			}
		}
		.frame(width: size, height: size)
		.animation(.linear(duration: 0.2), value: fraction)
	}
}
