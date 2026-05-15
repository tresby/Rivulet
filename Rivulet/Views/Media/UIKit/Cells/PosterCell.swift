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
//  Visual parity targets (line-by-line clone of SwiftUI MediaPosterCard):
//   - 260x390 frame
//   - 16pt rounded-rect mask, .continuous corner curve
//   - drop shadow black-0.35, radius 8, y 6
//   - in-progress capsule (6pt tall, white sharp core + soft glow) at the
//     bottom inset 8pt when 0 < watchProgress < 1
//   - status badge top-trailing (unwatched count or fully-watched corner)
//   - failure-state icon overlay (film / tv / play.rectangle / number.square)
//

import UIKit
import TVUIKit

@MainActor
final class PosterCell: UICollectionViewCell {
    static let reuseID = "PosterCell"

    private let posterView = TVPosterView()
    /// Sibling overlay holds in-progress capsule, watched indicators, and
    /// the failure-state icon — all need to clip to the same 260x390 area
    /// as the poster image.
    private let overlayContainer = UIView()
    private let progressBar = PosterProgressBar()
    private let watchedBadge = PosterWatchedBadge()
    private let failureIcon = UIImageView()

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

        // Overlay container hosts indicators that must clip to the same
        // rounded rect as the poster image (16pt continuous corners).
        overlayContainer.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.isUserInteractionEnabled = false
        overlayContainer.clipsToBounds = true
        overlayContainer.layer.cornerRadius = cornerRadius
        overlayContainer.layer.cornerCurve = .continuous
        contentView.addSubview(overlayContainer)

        // Progress bar pinned bottom-leading/trailing with 8pt horizontal
        // padding + 1pt bottom padding (matches SwiftUI).
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true
        overlayContainer.addSubview(progressBar)

        // Watched badge sits top-trailing, 10pt inset (matches SwiftUI
        // `.padding(10)` after the badge).
        watchedBadge.translatesAutoresizingMaskIntoConstraints = false
        watchedBadge.isHidden = true
        overlayContainer.addSubview(watchedBadge)

        // Failure icon centred. Hidden by default; visible only when the
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

            progressBar.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor, constant: 8),
            progressBar.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor, constant: -8),
            progressBar.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor, constant: -1),
            progressBar.heightAnchor.constraint(equalToConstant: 6),

            watchedBadge.topAnchor.constraint(equalTo: overlayContainer.topAnchor, constant: 10),
            watchedBadge.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor, constant: -10),

            failureIcon.centerXAnchor.constraint(equalTo: overlayContainer.centerXAnchor),
            failureIcon.centerYAnchor.constraint(equalTo: overlayContainer.centerYAnchor),
            failureIcon.widthAnchor.constraint(equalToConstant: 32),
            failureIcon.heightAnchor.constraint(equalToConstant: 32)
        ])
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
        progressBar.isHidden = true
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

    // MARK: - In-progress bar

    private func configureProgressBar(item: PlexMetadata) {
        // SwiftUI shows the bar only when 0 < progress < 1. Audio items
        // (album/artist/track) suppress progress entirely.
        if isAudioItem(item) {
            progressBar.isHidden = true
            return
        }
        if let progress = item.watchProgress, progress > 0, progress < 1 {
            progressBar.setProgress(progress)
            progressBar.isHidden = false
        } else {
            progressBar.isHidden = true
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

// MARK: - In-progress capsule

/// 6pt-tall capsule: dark backing + soft white glow + sharp white core.
/// Mirror of SwiftUI MediaPosterCard.progressBarOverlay (lines 147-175).
@MainActor
final class PosterProgressBar: UIView {
    private let backing = UIView()
    private let glow = UIView()
    private let core = UIView()

    private var glowWidthConstraint: NSLayoutConstraint!
    private var coreWidthConstraint: NSLayoutConstraint!

    private var progress: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false  // glow shadow needs room

        backing.translatesAutoresizingMaskIntoConstraints = false
        backing.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        backing.layer.cornerRadius = 3
        backing.layer.cornerCurve = .continuous
        backing.clipsToBounds = true
        addSubview(backing)

        // Glow = filled capsule with a soft white shadow. SwiftUI uses
        // `.blur(radius: 4).opacity(0.8)` on a white capsule; the closest
        // free CALayer approximation is shadow with radius 4 + 0.8 opacity.
        glow.translatesAutoresizingMaskIntoConstraints = false
        glow.backgroundColor = .white
        glow.layer.cornerRadius = 3
        glow.layer.cornerCurve = .continuous
        glow.layer.shadowColor = UIColor.white.cgColor
        glow.layer.shadowOpacity = 0.8
        glow.layer.shadowRadius = 4
        glow.layer.shadowOffset = .zero
        addSubview(glow)

        core.translatesAutoresizingMaskIntoConstraints = false
        core.backgroundColor = .white
        core.layer.cornerRadius = 3
        core.layer.cornerCurve = .continuous
        addSubview(core)

        glowWidthConstraint = glow.widthAnchor.constraint(equalToConstant: 0)
        coreWidthConstraint = core.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
            backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),

            glow.topAnchor.constraint(equalTo: topAnchor),
            glow.bottomAnchor.constraint(equalTo: bottomAnchor),
            glow.leadingAnchor.constraint(equalTo: leadingAnchor),
            glowWidthConstraint,

            core.topAnchor.constraint(equalTo: topAnchor),
            core.bottomAnchor.constraint(equalTo: bottomAnchor),
            core.leadingAnchor.constraint(equalTo: leadingAnchor),
            coreWidthConstraint
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setProgress(_ progress: Double) {
        self.progress = max(0, min(progress, 1))
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let total = bounds.width
        glowWidthConstraint.constant = total * CGFloat(progress)
        coreWidthConstraint.constant = total * CGFloat(progress)
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
