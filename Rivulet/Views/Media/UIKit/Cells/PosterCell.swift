//
//  PosterCell.swift
//  Rivulet
//
//  Poster-style hub cell (Recently Added rows, Personalized Recommendations).
//  Wraps `TVPosterView` for native tvOS focus motion (parallax, scale, glow).
//
//  Caption (`title` / `subtitle`) is intentionally nil. When set,
//  `TVPosterView` reserves bottom space for the on-focus caption block
//  even while the caption is hidden, which compresses the image area and
//  visibly crops the bottom of 2:3 Plex posters. SwiftUI MediaPosterCard
//  doesn't render a caption either; the title surfaces in the preview
//  overlay / detail view instead.
//
//  Overlay subviews (watched badge, in-progress info bar, failure icon)
//  live in a sibling `overlayContainer` view that:
//    * matches the poster's 260x390 frame
//    * applies its own 16pt corner mask so the watched corner-tag clips
//      to the same rounded edge as the poster image
//    * tracks the cell's focus state and applies the same scale
//      transform `TVPosterView` uses for the image (so overlays grow
//      with the poster instead of staying static during focus zoom)
//
//  Earlier attempts to host overlays inside `posterView.contentView` or
//  `posterView.imageView` either produced invisible badges (Apple's
//  internal layout doesn't render subviews on the imageView) or didn't
//  inherit clipping correctly. The sibling-with-matching-transform
//  approach is reliable on both counts.
//
//  In-progress composition matches Continue Watching exactly (per user
//  direction): MediaBottomGradient behind a MediaProgressInfoBar with
//  play.fill icon + 44pt capsule progress + "S1, E2 . 35m" info text.
//  Only renders when `0 < item.watchProgress < 1`. Watched and
//  unwatched items show no bottom bar.
//

import UIKit
import TVUIKit

@MainActor
final class PosterCell: UICollectionViewCell {
    static let reuseID = "PosterCell"

    private let posterView = TVPosterView()

    /// Sibling of `posterView` that hosts overlays. Has its own rounded
    /// mask so the corner-tag clips to the same shape as the poster; its
    /// transform is kept in sync with the posterView's focus zoom in
    /// `didUpdateFocus`.
    private let overlayContainer = UIView()

    private let watchedBadge = PosterWatchedBadge()
    private let failureIcon = UIImageView()
    private let progressBottomGradient = MediaBottomGradient()
    private let progressInfoBar = MediaProgressInfoBar()

    private var imageLoadTask: Task<Void, Never>?
    private var currentURL: URL?

    private let cornerRadius: CGFloat = 16
    private let posterWidth: CGFloat = 260
    private let posterHeight: CGFloat = 390

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        // Drop shadow on the cell (matches SwiftUI .shadow(black-0.35, r 8, y 6)).
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.35
        contentView.layer.shadowRadius = 8
        contentView.layer.shadowOffset = CGSize(width: 0, height: 6)

        posterView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(posterView)

        // Overlay container clipped to the same rounded rect as the poster.
        overlayContainer.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.isUserInteractionEnabled = false
        overlayContainer.clipsToBounds = true
        overlayContainer.layer.cornerRadius = cornerRadius
        overlayContainer.layer.cornerCurve = .continuous
        contentView.addSubview(overlayContainer)

        progressBottomGradient.translatesAutoresizingMaskIntoConstraints = false
        progressBottomGradient.isHidden = true
        overlayContainer.addSubview(progressBottomGradient)

        progressInfoBar.translatesAutoresizingMaskIntoConstraints = false
        progressInfoBar.isHidden = true
        overlayContainer.addSubview(progressInfoBar)

        // Watched badge: top-trailing, 10pt inset (mirrors SwiftUI `.padding(10)`).
        watchedBadge.translatesAutoresizingMaskIntoConstraints = false
        watchedBadge.isHidden = true
        overlayContainer.addSubview(watchedBadge)

        // Failure icon: centred. Hidden by default; visible only when the
        // image load fails or the source URL is missing.
        failureIcon.translatesAutoresizingMaskIntoConstraints = false
        failureIcon.contentMode = .scaleAspectFit
        failureIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        failureIcon.isHidden = true
        overlayContainer.addSubview(failureIcon)

        NSLayoutConstraint.activate([
            posterView.topAnchor.constraint(equalTo: contentView.topAnchor),
            posterView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            posterView.widthAnchor.constraint(equalToConstant: posterWidth),
            posterView.heightAnchor.constraint(equalToConstant: posterHeight),

            overlayContainer.topAnchor.constraint(equalTo: posterView.topAnchor),
            overlayContainer.bottomAnchor.constraint(equalTo: posterView.bottomAnchor),
            overlayContainer.leadingAnchor.constraint(equalTo: posterView.leadingAnchor),
            overlayContainer.trailingAnchor.constraint(equalTo: posterView.trailingAnchor),

            // Bottom gradient + info bar pinned to the bottom of the
            // overlay container (= bottom of the poster).
            progressBottomGradient.topAnchor.constraint(equalTo: overlayContainer.topAnchor),
            progressBottomGradient.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor),
            progressBottomGradient.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor),
            progressBottomGradient.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor),

            progressInfoBar.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor, constant: 16),
            progressInfoBar.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor, constant: -16),
            progressInfoBar.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor, constant: -16),

            watchedBadge.topAnchor.constraint(equalTo: overlayContainer.topAnchor, constant: 10),
            watchedBadge.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor, constant: -10),

            failureIcon.centerXAnchor.constraint(equalTo: overlayContainer.centerXAnchor),
            failureIcon.centerYAnchor.constraint(equalTo: overlayContainer.centerYAnchor),
            failureIcon.widthAnchor.constraint(equalToConstant: 32),
            failureIcon.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    // MARK: - Focus zoom sync

    /// `TVPosterView` applies its own focus scale transform to the image
    /// (via `focusSizeIncrease`) that doesn't propagate to our sibling
    /// `overlayContainer`. We mirror it here so overlays grow with the
    /// poster instead of staying static. The 1.1 scale is the published
    /// default for `TVPosterView` at standard contentSize (260x390); it's
    /// close enough that the visual offset is imperceptible.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
                      || context.nextFocusedView?.isDescendant(of: self) == true
        coordinator.addCoordinatedAnimations {
            self.overlayContainer.transform = nowFocused
                ? CGAffineTransform(scaleX: 1.1, y: 1.1)
                : .identity
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Pre-compute shadowPath to keep the shadow off the offscreen-render
        // critical path. Matches the poster's rounded 260x390 frame.
        let posterFrame = posterView.frame
        contentView.layer.shadowPath = UIBezierPath(
            roundedRect: posterFrame,
            cornerRadius: cornerRadius
        ).cgPath
    }

    // MARK: - Configure

    func configure(item: PlexMetadata) {
        let url = posterURL(for: item)
        loadImage(from: url, item: item)
        configureProgressBar(item: item)
        configureWatchedBadge(item: item)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageLoadTask?.cancel()
        imageLoadTask = nil
        currentURL = nil
        posterView.image = nil
        progressBottomGradient.isHidden = true
        progressInfoBar.isHidden = true
        progressInfoBar.reset()
        watchedBadge.isHidden = true
        failureIcon.isHidden = true
        failureIcon.image = nil
    }

    // MARK: - Image load

    private func loadImage(from url: URL?, item: PlexMetadata) {
        imageLoadTask?.cancel()
        guard let url else {
            posterView.image = nil
            currentURL = nil
            showFailureIcon(for: item)
            return
        }
        if currentURL == url, posterView.image != nil {
            failureIcon.isHidden = true
            return
        }
        currentURL = url
        failureIcon.isHidden = true
        let key = url.absoluteString as AnyHashable
        imageLoadTask = Task { [weak self] in
            let image: UIImage? = await Perf.interval(.imageDecode, key: key) {
                await ImageCacheManager.shared.image(for: url)
            }
            await MainActor.run {
                guard let self, self.currentURL == url else { return }
                if let image {
                    self.posterView.image = image
                    self.failureIcon.isHidden = true
                } else {
                    self.posterView.image = nil
                    self.showFailureIcon(for: item)
                }
            }
        }
    }

    private func showFailureIcon(for item: PlexMetadata) {
        failureIcon.image = failureIconImage(for: item)
        failureIcon.isHidden = false
    }

    /// Mirror of SwiftUI `MediaPosterCard.iconForType`.
    private func failureIconImage(for item: PlexMetadata) -> UIImage? {
        let name: String
        switch item.type {
        case "movie": name = "film"
        case "show": name = "tv"
        case "season": name = "number.square"
        case "episode": name = "play.rectangle"
        case "artist": name = "music.mic"
        case "album": name = "square.stack"
        case "track": name = "music.note"
        default: name = "photo"
        }
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }

    private func posterURL(for item: PlexMetadata) -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken
        else { return nil }
        // Episodes prefer the show (grandparent) thumb so Recently-Added
        // episode rows render show posters, not letterboxed episode stills.
        let path: String?
        if item.type == "episode" {
            path = item.grandparentThumb ?? item.parentThumb ?? item.thumb
        } else {
            path = item.thumb
        }
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(token)")
    }

    // MARK: - In-progress bar (CW-style)

    private func configureProgressBar(item: PlexMetadata) {
        // Show the CW-style info bar only when an item is in progress
        // (0 < watchProgress < 1). Audio items (album / artist / track)
        // suppress progress entirely.
        if isAudioItem(item) {
            progressBottomGradient.isHidden = true
            progressInfoBar.isHidden = true
            progressInfoBar.reset()
            return
        }
        if let progress = item.watchProgress, progress > 0, progress < 1 {
            progressBottomGradient.isHidden = false
            progressInfoBar.isHidden = false
            progressInfoBar.configure(item: item)
        } else {
            progressBottomGradient.isHidden = true
            progressInfoBar.isHidden = true
            progressInfoBar.reset()
        }
    }

    private func isAudioItem(_ item: PlexMetadata) -> Bool {
        switch item.type {
        case "album", "artist", "track": return true
        default: return false
        }
    }

    // MARK: - Watched badge

    private func configureWatchedBadge(item: PlexMetadata) {
        // SwiftUI ladder:
        //  1. Audio items: nothing
        //  2. TV show with leafCount > 0 and unwatched > 0: blue capsule with count
        //  3. TV show with all watched: corner tag
        //  4. Movie/episode fully watched: corner tag
        if isAudioItem(item) {
            watchedBadge.isHidden = true
            return
        }
        if item.type == "show", let leafCount = item.leafCount, leafCount > 0 {
            let viewed = item.viewedLeafCount ?? 0
            let unwatched = leafCount - viewed
            if unwatched > 0 {
                watchedBadge.setStyle(.unwatchedCount(unwatched))
                watchedBadge.isHidden = false
                return
            }
            if viewed >= leafCount {
                watchedBadge.setStyle(.cornerTag)
                watchedBadge.isHidden = false
                return
            }
        }
        if isFullyWatched(item) {
            watchedBadge.setStyle(.cornerTag)
            watchedBadge.isHidden = false
            return
        }
        watchedBadge.isHidden = true
    }

    /// Mirror of SwiftUI `MediaPosterCard.isFullyWatched`.
    private func isFullyWatched(_ item: PlexMetadata) -> Bool {
        guard let viewCount = item.viewCount, viewCount > 0 else { return false }
        if let progress = item.watchProgress, progress > 0, progress < 1 {
            return false
        }
        if let viewOffset = item.viewOffset, let duration = item.duration {
            let remaining = duration - viewOffset
            if remaining > 60_000 { return false }   // >1 minute left
        }
        return true
    }
}

// MARK: - Watched / unwatched-count badge

/// Top-trailing pill (unwatched count for in-progress shows) or corner tag
/// (fully-watched). Mirror of SwiftUI MediaPosterCard.unwatchedBadge +
/// WatchedCornerTag.
@MainActor
final class PosterWatchedBadge: UIView {
    enum Style {
        case unwatchedCount(Int)
        case cornerTag
    }

    private let pillLabel = UILabel()
    private let pillBackground = UIView()
    private let triangleLayer = CAShapeLayer()
    private let checkmarkImageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // Pill style: blue capsule with N text.
        pillBackground.translatesAutoresizingMaskIntoConstraints = false
        pillBackground.backgroundColor = .systemBlue
        pillBackground.layer.cornerRadius = 10
        pillBackground.layer.cornerCurve = .continuous
        pillBackground.layer.shadowColor = UIColor.black.cgColor
        pillBackground.layer.shadowOpacity = 0.3
        pillBackground.layer.shadowRadius = 4
        pillBackground.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(pillBackground)

        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillLabel.font = .systemFont(ofSize: 12, weight: .bold)
        pillLabel.textColor = .white
        pillBackground.addSubview(pillLabel)

        // Corner-tag style: green right-triangle with a checkmark inside.
        triangleLayer.fillColor = UIColor.systemGreen.cgColor
        triangleLayer.isHidden = true
        layer.addSublayer(triangleLayer)

        checkmarkImageView.translatesAutoresizingMaskIntoConstraints = false
        checkmarkImageView.image = UIImage(systemName: "checkmark")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 18, weight: .bold))
        checkmarkImageView.tintColor = .white
        checkmarkImageView.contentMode = .scaleAspectFit
        checkmarkImageView.isHidden = true
        addSubview(checkmarkImageView)

        NSLayoutConstraint.activate([
            pillLabel.topAnchor.constraint(equalTo: pillBackground.topAnchor, constant: 4),
            pillLabel.bottomAnchor.constraint(equalTo: pillBackground.bottomAnchor, constant: -4),
            pillLabel.leadingAnchor.constraint(equalTo: pillBackground.leadingAnchor, constant: 8),
            pillLabel.trailingAnchor.constraint(equalTo: pillBackground.trailingAnchor, constant: -8),

            pillBackground.topAnchor.constraint(equalTo: topAnchor),
            pillBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            pillBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillBackground.trailingAnchor.constraint(equalTo: trailingAnchor),

            checkmarkImageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            checkmarkImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            checkmarkImageView.widthAnchor.constraint(equalToConstant: 18),
            checkmarkImageView.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        // 48x48 triangle when in corner-tag mode; otherwise let the pill's
        // own constraints determine size.
        if !triangleLayer.isHidden {
            return CGSize(width: 48, height: 48)
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Triangle covers the top-trailing 48x48 corner: (0,0) -> (w,0) ->
        // (w,h) -> close. Matches SwiftUI WatchedCornerTag.CornerTriangle.
        let rect = bounds
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.close()
        triangleLayer.frame = rect
        triangleLayer.path = path.cgPath
    }

    func setStyle(_ style: Style) {
        switch style {
        case .unwatchedCount(let count):
            pillLabel.text = "\(count)"
            pillBackground.isHidden = false
            triangleLayer.isHidden = true
            checkmarkImageView.isHidden = true
        case .cornerTag:
            pillBackground.isHidden = true
            triangleLayer.isHidden = false
            checkmarkImageView.isHidden = false
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}
