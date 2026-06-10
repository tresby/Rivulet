//
//  ContinueWatchingCell.swift
//  Rivulet
//
//  Landscape Continue Watching tile (360x280, ~1.29:1). Began as a 1:1 clone of
//  SwiftUI `ContinueWatchingCard` (392x280, 1.4:1); per design direction the
//  aspect was tightened to ~1.28:1 landscape. Composition is otherwise the same:
//
//    ZStack {
//      artwork (scaleAspectFill, .clipped())
//      (no bottom gradient — removed 2026-06-10, the darkness read badly)
//      centered title logo (Plex clearLogo, falls back to centered title)
//      bottom info bar (play icon + capsule progress + "S1, E2 • 35m")
//    }
//    .frame(360, 280)
//    .clipShape(RoundedRectangle(cornerRadius: 16, .continuous))
//    .hoverEffect(.highlight)
//    (no resting drop shadow — ATV+ ref: cards float clean over the background)
//
//  Wrapped in `TVCardView` for native tvOS focus motion (parallax, glow).
//

import UIKit
import TVUIKit

@MainActor
final class ContinueWatchingCell: UICollectionViewCell {
    static let reuseID = "ContinueWatchingCell"

    private let card = TVCardView()
    private let artworkImageView = UIImageView()
    private let placeholderView = UIView()
    private let placeholderIcon = UIImageView()
    private let titleLogoView = ContinueWatchingTitleLogoView()
    private let infoBar = MediaProgressInfoBar()

    private var artworkLoadTask: Task<Void, Never>?
    private var currentArtworkURL: URL?

    private let cornerRadius: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        // TVCardView provides Apple's tvOS focus motion (parallax + glow).
        card.translatesAutoresizingMaskIntoConstraints = false
        card.contentSize = CGSize(width: MediaRowMetrics.cwWidth, height: MediaRowMetrics.cwHeight)
        contentView.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: MediaRowMetrics.cwWidth),
            card.heightAnchor.constraint(equalToConstant: MediaRowMetrics.cwHeight)
        ])

        // No resting drop shadow (ATV+ reference: cards float clean over the
        // page background; see Docs/atv_ref/below_home_hero_ref.md).

        // Placeholder underlay (dark grey) — visible until the artwork
        // resolves. SwiftUI .empty branch uses `Color(white: 0.15)`.
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        card.contentView.addSubview(placeholderView)

        // SwiftUI failure branch: dark gradient + film/play.rectangle icon.
        // We reuse the placeholder view for both empty and failure states;
        // the icon is hidden by default and shown only when the load fails.
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        placeholderIcon.isHidden = true
        placeholderView.addSubview(placeholderIcon)

        // Artwork. scaleAspectFill + clipsToBounds matches SwiftUI's
        // `.aspectRatio(contentMode: .fill)` + `.clipped()`.
        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.clipsToBounds = true
        card.contentView.addSubview(artworkImageView)

        // Centered title logo (Plex clearLogo fallback to centered title).
        titleLogoView.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(titleLogoView)

        // Bottom info bar.
        infoBar.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(infoBar)

        NSLayoutConstraint.activate([
            placeholderView.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 32),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 32),

            artworkImageView.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            artworkImageView.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            artworkImageView.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            artworkImageView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),


            titleLogoView.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            titleLogoView.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            titleLogoView.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            titleLogoView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),

            // Info bar pinned bottom with 20pt inset on all sides — matches
            // SwiftUI's `.padding(20)` inside the VStack/Spacer/bottomInfoBar.
            infoBar.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 20),
            infoBar.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -20),
            infoBar.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -20)
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.contentView.layer.cornerRadius = cornerRadius
        card.contentView.layer.cornerCurve = .continuous
        card.contentView.clipsToBounds = true
        CATransaction.commit()

    }

    // MARK: - Configure

    func configure(item: PlexMetadata) {
        // Title-logo view fetches the clearLogo asynchronously (with a
        // text fallback while the fetch is in flight or if it fails).
        titleLogoView.configure(item: item)

        // Info bar: play icon + (optional) progress capsule + info text.
        infoBar.configure(item: item)

        loadArtwork(for: item)
    }

    /// MediaItem path. All artwork URLs are already resolved — no serverURL/token needed.
    func configure(item: MediaItem) {
        // Episodes/shows: prefer the grandparent (show) logo; fall back to
        // the item's own logo. The URL is already resolved — no async fetch.
        let logoURL = item.grandparentArtwork?.logo ?? item.artwork.logo
        titleLogoView.configure(logoURL: logoURL, fallbackTitle: item.title)

        infoBar.configure(item: item)

        // Backdrop > thumbnail in landscape orientation.
        let url = item.grandparentArtwork?.backdrop
            ?? item.artwork.backdrop
            ?? item.artwork.thumbnail
        loadArtwork(from: url, failureKind: item.kind)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        currentArtworkURL = nil
        artworkImageView.image = nil
        placeholderView.isHidden = false
        placeholderIcon.isHidden = true
        titleLogoView.prepareForReuse()
        infoBar.reset()
    }

    // MARK: - Artwork

    /// PlexMetadata path: resolves failure icon then delegates to the shared loader.
    private func loadArtwork(for item: PlexMetadata) {
        loadArtwork(from: artworkURL(for: item),
                    failureIcon: failurePlaceholderImage(for: item))
    }

    /// MediaItem path: resolves failure icon via MediaKind then delegates.
    private func loadArtwork(from url: URL?, failureKind: MediaKind) {
        loadArtwork(from: url, failureIcon: failurePlaceholderImage(for: failureKind))
    }

    private func loadArtwork(from url: URL?, failureIcon: UIImage?) {
        artworkLoadTask?.cancel()
        guard let url else {
            artworkImageView.image = nil
            currentArtworkURL = nil
            placeholderView.isHidden = false
            placeholderIcon.image = failureIcon
            placeholderIcon.isHidden = false
            return
        }
        if currentArtworkURL == url, artworkImageView.image != nil {
            placeholderView.isHidden = true
            return
        }
        currentArtworkURL = url
        placeholderView.isHidden = false
        placeholderIcon.isHidden = true  // hidden during loading
        let key = url.absoluteString as AnyHashable
        artworkLoadTask = Task { [weak self] in
            let image: UIImage? = await Perf.interval(.imageDecode, key: key) {
                await ImageCacheManager.shared.image(for: url)
            }
            await MainActor.run {
                guard let self, self.currentArtworkURL == url else { return }
                if let image {
                    self.artworkImageView.image = image
                    self.placeholderView.isHidden = true
                } else {
                    self.placeholderIcon.image = failureIcon
                    self.placeholderIcon.isHidden = false
                }
            }
        }
    }

    private func artworkURL(for item: PlexMetadata) -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken
        else { return nil }
        // SwiftUI: episodes prefer grandparentArt; otherwise art > thumb.
        let path: String?
        if item.type == "episode" {
            path = item.grandparentArt ?? item.art ?? item.thumb
        } else {
            path = item.art ?? item.thumb
        }
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(token)")
    }

    /// PlexMetadata failure icon: "film" for movies, "play.rectangle" otherwise.
    private func failurePlaceholderImage(for item: PlexMetadata) -> UIImage? {
        let name = item.type == "movie" ? "film" : "play.rectangle"
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }

    /// MediaItem failure icon — maps MediaKind to a system image name.
    private func failurePlaceholderImage(for kind: MediaKind) -> UIImage? {
        let name: String
        switch kind {
        case .movie:   name = "film"
        case .show:    name = "tv"
        case .season:  name = "number.square"
        case .episode: name = "play.rectangle"
        case .person:  name = "person"
        default:       name = "photo"
        }
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }
}

// MARK: - Title Logo (Plex clearLogo fetch)

/// One-for-one port of SwiftUI `ContinueWatchingTitleLogo`. Fetches the
/// item's clearLogo (or the grandparent show's, for episodes) and renders
/// it centered. Falls back to a styled centered title label while loading
/// or on failure.
@MainActor
private final class ContinueWatchingTitleLogoView: UIView {
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    private var fetchTask: Task<Void, Never>?
    private var currentItemKey: String?

    /// Logo target area = 18000 pt² (matches SwiftUI `targetArea`).
    private let targetArea: CGFloat = 18000
    /// Max bounds clamp — 75% card width / 45% card height.
    private let cardWidth: CGFloat = MediaRowMetrics.cwWidth
    private let cardHeight: CGFloat = MediaRowMetrics.cwHeight
    private var maxLogoWidth: CGFloat { cardWidth * 0.75 }
    private var maxLogoHeight: CGFloat { cardHeight * 0.45 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // Fallback title — centered, 30pt bold, white, soft drop shadow.
        // Matches SwiftUI `textFallback`.
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.shadowColor = UIColor.black.withAlphaComponent(0.5)
        titleLabel.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(titleLabel)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.alpha = 0
        imageView.layer.shadowColor = UIColor.black.withAlphaComponent(0.6).cgColor
        imageView.layer.shadowOpacity = 1
        imageView.layer.shadowRadius = 4
        imageView.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(imageView)

        widthConstraint = imageView.widthAnchor.constraint(equalToConstant: 0)
        heightConstraint = imageView.heightAnchor.constraint(equalToConstant: 0)
        widthConstraint.priority = .defaultHigh
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthConstraint,
            heightConstraint
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: PlexMetadata) {
        let key = item.ratingKey ?? ""
        // Reset state when the item changes (covers cell reuse).
        if key != currentItemKey {
            fetchTask?.cancel()
            imageView.image = nil
            imageView.alpha = 0
            currentItemKey = key
        }
        titleLabel.text = displayTitle(for: item)
        // Make text visible until the logo loads (matches SwiftUI's
        // `opacity(loadedLogo == nil ? 1 : 0)`).
        titleLabel.alpha = imageView.image == nil ? 1 : 0

        if imageView.image == nil {
            fetchTask?.cancel()
            fetchTask = Task { [weak self] in
                await self?.fetchLogo(for: item, key: key)
            }
        }
    }

    /// MediaItem path. The logo URL is already resolved — no async fetch
    /// needed. Loads the image via the cache and renders it with the same
    /// size / fade logic as the Plex async path.
    func configure(logoURL: URL?, fallbackTitle: String) {
        // Always update the title text. Setting .text is cheap and does not
        // animate, so a recycled cell shows the correct title for every item
        // regardless of whether a logo fetch is in flight.
        titleLabel.text = fallbackTitle

        guard let url = logoURL else {
            // No logo: cancel any in-flight fetch, clear the image state, and
            // show the title at full opacity. Do NOT update currentItemKey —
            // it is keyed to logo URLs only, and nil is not a distinct key
            // (two different logo-less items would alias to the same key and
            // suppress each other's title updates).
            fetchTask?.cancel()
            fetchTask = nil
            imageView.image = nil
            imageView.alpha = 0
            titleLabel.alpha = 1
            return
        }

        // For a non-nil URL, dedup only around the image fetch and fade-in.
        let key = url.absoluteString
        if key != currentItemKey {
            fetchTask?.cancel()
            imageView.image = nil
            imageView.alpha = 0
            currentItemKey = key
        }
        // Show title while the logo is absent; hide once it is loaded.
        titleLabel.alpha = imageView.image == nil ? 1 : 0

        guard imageView.image == nil else { return }
        fetchTask = Task { [weak self] in
            guard let self else { return }
            let image = await ImageCacheManager.shared.image(for: url)
            guard !Task.isCancelled, let image else { return }
            guard self.currentItemKey == key else { return }
            self.renderLogo(image)
        }
    }

    func prepareForReuse() {
        fetchTask?.cancel()
        fetchTask = nil
        currentItemKey = nil
        imageView.image = nil
        imageView.alpha = 0
        titleLabel.text = nil
    }

    private func displayTitle(for item: PlexMetadata) -> String {
        if item.type == "episode" {
            return item.grandparentTitle ?? item.title ?? "Unknown"
        }
        return item.title ?? "Unknown"
    }

    @MainActor
    private func fetchLogo(for item: PlexMetadata, key: String) async {
        guard let url = await resolveLogoURL(for: item) else { return }
        let image = await ImageCacheManager.shared.image(for: url)
        guard !Task.isCancelled, let image else { return }
        guard self.currentItemKey == key else { return }
        renderLogo(image)
    }

    /// Shared renderer used by both the Plex async-fetch path and the
    /// MediaItem already-resolved-URL path. Sizes the image to the
    /// target-area budget and fades it in, fading the title label out.
    private func renderLogo(_ image: UIImage) {
        // Compute logo size from target-area + aspect ratio.
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 2.0
        let rawW = sqrt(targetArea * ratio)
        let rawH = sqrt(targetArea / ratio)
        let w = min(rawW, maxLogoWidth)
        let h = min(rawH, maxLogoHeight)
        widthConstraint.constant = w
        heightConstraint.constant = h

        imageView.image = image
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
            self.imageView.alpha = 1
            self.titleLabel.alpha = 0
        }
    }

    /// Resolve the clearLogo URL — for episodes/shows, fetch the
    /// grandparent metadata (hub items don't carry the Image array).
    /// Caches the full-metadata response via PlexDataStore for reuse.
    private func resolveLogoURL(for item: PlexMetadata) async -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else {
            return nil
        }
        let sourceRatingKey: String?
        if item.type == "episode" {
            sourceRatingKey = item.grandparentRatingKey
        } else {
            sourceRatingKey = item.ratingKey
        }
        guard let ratingKey = sourceRatingKey else { return nil }

        let sourceMetadata: PlexMetadata
        if let cached = PlexDataStore.shared.getCachedFullMetadata(for: ratingKey) {
            sourceMetadata = cached
        } else {
            do {
                let fetched = try await PlexNetworkManager.shared.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                PlexDataStore.shared.cacheFullMetadata(fetched, for: ratingKey)
                sourceMetadata = fetched
            } catch {
                return nil
            }
        }

        guard let path = sourceMetadata.clearLogoPath else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(token)")
    }
}

// Info bar moved to `Rivulet/Views/Media/UIKit/Cells/MediaProgressInfoBar.swift`
// for reuse by PosterCell (in-progress items in Recently Added /
// Personalized Recommendations rows render the same composition).
