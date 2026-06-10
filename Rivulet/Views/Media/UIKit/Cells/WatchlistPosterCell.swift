//
//  WatchlistPosterCell.swift
//  Rivulet
//
//  Poster tile for the Watchlist hub row on the UIKit home. Mirrors
//  SwiftUI `WatchlistTile` (`WatchlistHubRow.swift:237-290`):
//   - 260x390 frame, 16pt rounded-rect mask, .continuous corner curve
//   - no resting drop shadow (ATV+ ref: cards float clean over the background)
//   - `.hoverEffect(.highlight)` approximated via `TVPosterView` focus motion
//   - placeholder when no posterURL: dark gradient + film/tv SF symbol
//     (32pt light, white-0.3)
//
//  Caption (`title` / `subtitle`) is intentionally nil — see comment in
//  `PosterCell.swift` for the rationale (TVPosterView reserves bottom
//  caption space that crops 2:3 posters; SwiftUI WatchlistTile doesn't
//  render a caption either).
//

import UIKit
import TVUIKit

@MainActor
final class WatchlistPosterCell: UICollectionViewCell {
    static let reuseID = "WatchlistPosterCell"

    private let posterView = TVPosterView()
    /// Overlay clipped to the same rounded rect — shows the placeholder
    /// gradient + icon when there is no poster URL or the load fails.
    private let placeholderView = UIView()
    private let placeholderGradient = CAGradientLayer()
    private let placeholderIcon = UIImageView()

    private var imageLoadTask: Task<Void, Never>?
    private var currentURL: URL?

    private let cornerRadius: CGFloat = 16
    private let posterWidth: CGFloat = MediaRowMetrics.posterWidth
    private let posterHeight: CGFloat = MediaRowMetrics.posterHeight

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        // No resting drop shadow (ATV+ reference: cards float clean over the
        // page background; see Docs/atv_ref/below_home_hero_ref.md).

        posterView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(posterView)

        // Placeholder underlay (dark gradient + centred SF symbol). Visible
        // when posterURL is nil or the load fails. Sits behind the poster
        // image so the image hides it once loaded.
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.clipsToBounds = true
        placeholderView.layer.cornerRadius = cornerRadius
        placeholderView.layer.cornerCurve = .continuous
        placeholderGradient.colors = [
            UIColor(white: 0.18, alpha: 1.0).cgColor,
            UIColor(white: 0.12, alpha: 1.0).cgColor
        ]
        placeholderGradient.startPoint = CGPoint(x: 0.5, y: 0)
        placeholderGradient.endPoint = CGPoint(x: 0.5, y: 1)
        placeholderView.layer.addSublayer(placeholderGradient)

        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        placeholderView.addSubview(placeholderIcon)

        // Insert placeholder below the poster view so the image covers it.
        contentView.insertSubview(placeholderView, belowSubview: posterView)

        NSLayoutConstraint.activate([
            posterView.topAnchor.constraint(equalTo: contentView.topAnchor),
            posterView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            posterView.widthAnchor.constraint(equalToConstant: posterWidth),
            posterView.heightAnchor.constraint(equalToConstant: posterHeight),

            placeholderView.topAnchor.constraint(equalTo: posterView.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: posterView.bottomAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: posterView.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: posterView.trailingAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 32),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the gradient sized to the placeholder bounds (no implicit
        // animation so it doesn't interpolate the frame on every layout
        // pass when the cell is recycled).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderGradient.frame = placeholderView.bounds
        CATransaction.commit()
    }

    func configure(item: PlexWatchlistItem) {
        // Pick the SF Symbol that matches the watchlist type — `film` for
        // movies, `tv` for shows. Mirrors SwiftUI `WatchlistTile.placeholder`.
        let iconName = item.type == .movie ? "film" : "tv"
        let icon = UIImage(systemName: iconName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
        loadImage(from: item.posterURL, failureIcon: icon)
    }

    /// MediaItem path. Artwork URLs are already resolved — no serverURL/token needed.
    func configure(item: MediaItem) {
        loadImage(from: item.artwork.poster, failureIcon: failureIconImage(for: item.kind))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageLoadTask?.cancel()
        imageLoadTask = nil
        currentURL = nil
        posterView.image = nil
        placeholderView.isHidden = false
        placeholderIcon.image = nil
    }

    private func loadImage(from url: URL?, failureIcon: UIImage?) {
        imageLoadTask?.cancel()
        // Update the placeholder icon regardless of whether we have a URL.
        placeholderIcon.image = failureIcon
        guard let url else {
            posterView.image = nil
            currentURL = nil
            // No URL: show placeholder (no fade-out animation needed).
            placeholderView.isHidden = false
            return
        }
        if currentURL == url, posterView.image != nil {
            placeholderView.isHidden = true
            return
        }
        currentURL = url
        placeholderView.isHidden = false  // visible while loading
        let key = url.absoluteString as AnyHashable
        imageLoadTask = Task { [weak self] in
            let image: UIImage? = await Perf.interval(.imageDecode, key: key) {
                await ImageCacheManager.shared.image(for: url)
            }
            await MainActor.run {
                guard let self, self.currentURL == url else { return }
                if let image {
                    self.posterView.image = image
                    self.placeholderView.isHidden = true
                } else {
                    // Load failed: keep placeholder visible.
                    self.placeholderView.isHidden = false
                }
            }
        }
    }

    /// MediaItem failure icon -- maps MediaKind to a system image name.
    private func failureIconImage(for kind: MediaKind) -> UIImage? {
        let name: String
        switch kind {
        case .movie:      name = "film"
        case .show:       name = "tv"
        case .season:     name = "number.square"
        case .episode:    name = "play.rectangle"
        case .person:     name = "person"
        default:          name = "photo"
        }
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }
}
