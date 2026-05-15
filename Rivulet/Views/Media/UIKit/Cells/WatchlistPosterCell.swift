//
//  WatchlistPosterCell.swift
//  Rivulet
//
//  Poster tile for the Watchlist hub row on the UIKit home. Mirrors
//  `WatchlistTile` (SwiftUI) — 260x390 portrait poster with corner
//  radius, drop shadow and `TVPosterView`-driven focus motion.
//
//  Caption (`title` / `subtitle`) is intentionally left nil for the
//  same reason as `PosterCell` — setting them makes `TVPosterView`
//  reserve bottom space that crops the image area; the SwiftUI
//  `WatchlistTile` doesn't render a caption either.
//
//  Backed by `PlexWatchlistItem` (not PlexMetadata) — items come from
//  the Plex Discover Watchlist API and may or may not be present in the
//  user's local library.
//

import UIKit
import TVUIKit

@MainActor
final class WatchlistPosterCell: UICollectionViewCell {
    static let reuseID = "WatchlistPosterCell"

    private let posterView = TVPosterView()
    private var imageLoadTask: Task<Void, Never>?
    private var currentURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        posterView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(posterView)
        NSLayoutConstraint.activate([
            posterView.topAnchor.constraint(equalTo: contentView.topAnchor),
            posterView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            posterView.widthAnchor.constraint(equalToConstant: 260),
            posterView.heightAnchor.constraint(equalToConstant: 390)
        ])
    }

    func configure(item: PlexWatchlistItem) {
        loadImage(from: item.posterURL)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageLoadTask?.cancel()
        imageLoadTask = nil
        currentURL = nil
        posterView.image = nil
    }

    private func loadImage(from url: URL?) {
        imageLoadTask?.cancel()
        guard let url else {
            posterView.image = nil
            currentURL = nil
            return
        }
        if currentURL == url, posterView.image != nil { return }
        currentURL = url
        let key = url.absoluteString as AnyHashable
        imageLoadTask = Task { [weak self] in
            let image: UIImage? = await Perf.interval(.imageDecode, key: key) {
                await ImageCacheManager.shared.image(for: url)
            }
            await MainActor.run {
                guard let self, self.currentURL == url else { return }
                self.posterView.image = image
            }
        }
    }
}
