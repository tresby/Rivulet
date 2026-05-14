//
//  PosterCell.swift
//  Rivulet
//
//  Poster-style hub cell for the UIKit home (Recently Added rows).
//  Wraps `TVPosterView` for native focus motion (parallax, scale, glow).
//
//  Usage: dequeue, call `configure(item:)`. Cell handles image load
//  cancellation in `prepareForReuse`. ImageDecode signposts on each load.
//

import UIKit
import TVUIKit

@MainActor
final class PosterCell: UICollectionViewCell {
    static let reuseID = "PosterCell"

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
        // Caption hidden when not focused; appears below on focus.
        contentView.addSubview(posterView)
        NSLayoutConstraint.activate([
            posterView.topAnchor.constraint(equalTo: contentView.topAnchor),
            posterView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            posterView.widthAnchor.constraint(equalToConstant: 260),
            posterView.heightAnchor.constraint(equalToConstant: 390)
        ])
    }

    func configure(item: PlexMetadata) {
        posterView.title = item.title
        posterView.subtitle = displaySubtitle(for: item)

        let url = posterURL(for: item)
        loadImage(from: url)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageLoadTask?.cancel()
        imageLoadTask = nil
        currentURL = nil
        posterView.image = nil
    }

    // MARK: - Image load

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

    private func posterURL(for item: PlexMetadata) -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken
        else { return nil }
        // Episodes use grandparent (show) thumb when available — same logic
        // as MediaPosterCard.posterURL.
        let path: String?
        if item.type == "episode" {
            path = item.grandparentThumb ?? item.parentThumb ?? item.thumb
        } else {
            path = item.thumb
        }
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(token)")
    }

    private func displaySubtitle(for item: PlexMetadata) -> String? {
        if item.type == "episode" {
            // "S2E5"
            if let s = item.parentIndex, let e = item.index {
                return "S\(s)E\(e)"
            }
        }
        if let year = item.year {
            return "\(year)"
        }
        return nil
    }
}
