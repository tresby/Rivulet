//
//  ContinueWatchingCell.swift
//  Rivulet
//
//  Wide landscape Continue Watching tile (392x280). One-for-one clone of
//  SwiftUI `ContinueWatchingCard`:
//
//    ZStack {
//      artwork (scaleAspectFill, .clipped())
//      bottom gradient (clear@0.3 → black-0.7@0.7 → black-0.85@1.0)
//      centered title logo (Plex clearLogo, falls back to centered title)
//      bottom info bar (play icon + capsule progress + "S1, E2 • 35m")
//    }
//    .frame(392, 280)
//    .clipShape(RoundedRectangle(cornerRadius: 16, .continuous))
//    .hoverEffect(.highlight)
//    .shadow(.black-0.35, radius 8, y 6)
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
    private let bottomGradient = MediaBottomGradient()
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
        card.contentSize = CGSize(width: 392, height: 280)
        contentView.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: 392),
            card.heightAnchor.constraint(equalToConstant: 280)
        ])

        // Drop shadow on the cell (TVCardView doesn't render one). Matches
        // SwiftUI: `.shadow(color: .black.opacity(0.35), radius: 8, y: 6)`.
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.35
        contentView.layer.shadowRadius = 8
        contentView.layer.shadowOffset = CGSize(width: 0, height: 6)

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

        // Bottom gradient — replicates SwiftUI's LinearGradient
        // (see MediaBottomGradient for stops).
        bottomGradient.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(bottomGradient)

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

            bottomGradient.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            bottomGradient.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            bottomGradient.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            bottomGradient.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),

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

        // Shadow path follows the card's outer rounded frame so the shadow
        // renders without the off-screen offscreen-render penalty.
        let shadowRect = card.frame
        contentView.layer.shadowPath = UIBezierPath(
            roundedRect: shadowRect,
            cornerRadius: cornerRadius
        ).cgPath
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

    private func loadArtwork(for item: PlexMetadata) {
        artworkLoadTask?.cancel()
        guard let url = artworkURL(for: item) else {
            artworkImageView.image = nil
            currentArtworkURL = nil
            placeholderView.isHidden = false
            placeholderIcon.image = failurePlaceholderImage(for: item)
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
                    self.placeholderIcon.image = self.failurePlaceholderImage(for: item)
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

    private func failurePlaceholderImage(for item: PlexMetadata) -> UIImage? {
        // SwiftUI failure icon: "film" for movies, "play.rectangle" otherwise.
        let name = item.type == "movie" ? "film" : "play.rectangle"
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
    private let cardWidth: CGFloat = 392
    private let cardHeight: CGFloat = 280
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
