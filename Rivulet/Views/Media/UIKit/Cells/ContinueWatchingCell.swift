//
//  ContinueWatchingCell.swift
//  Rivulet
//
//  Continue Watching tile for the UIKit home. Wider landscape format
//  (392x280) using `TVCardView` so we can compose: backdrop image,
//  title-logo overlay (when available), and a progress bar at the
//  bottom — matches the SwiftUI `ContinueWatchingCard` shape.
//

import UIKit
import TVUIKit

@MainActor
final class ContinueWatchingCell: UICollectionViewCell {
    static let reuseID = "ContinueWatchingCell"

    private let card = TVCardView()
    private let imageView = UIImageView()
    private let progressBackground = UIView()
    private let progressFill = UIView()
    private let titleLabel = UILabel()

    private var imageLoadTask: Task<Void, Never>?
    private var currentURL: URL?
    private var watchProgress: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        card.translatesAutoresizingMaskIntoConstraints = false
        card.contentSize = CGSize(width: 392, height: 280)
        contentView.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: 392),
            card.heightAnchor.constraint(equalToConstant: 280)
        ])

        // Image fills the card content area.
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = UIColor(white: 0.12, alpha: 1.0)
        card.contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor)
        ])

        // Title (fallback when no clearLogo). Bottom-leading.
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.shadowColor = .black
        titleLabel.shadowOffset = CGSize(width: 0, height: 1)
        card.contentView.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -24)
        ])

        // Progress bar at the very bottom of the card.
        progressBackground.translatesAutoresizingMaskIntoConstraints = false
        progressBackground.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = UIColor.systemBlue
        card.contentView.addSubview(progressBackground)
        progressBackground.addSubview(progressFill)
        NSLayoutConstraint.activate([
            progressBackground.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            progressBackground.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            progressBackground.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            progressBackground.heightAnchor.constraint(equalToConstant: 4),

            progressFill.topAnchor.constraint(equalTo: progressBackground.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressBackground.bottomAnchor),
            progressFill.leadingAnchor.constraint(equalTo: progressBackground.leadingAnchor)
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Recompute progress fill width every layout (cell may resize on reuse).
        let total = progressBackground.bounds.width
        for constraint in progressFill.constraints where constraint.firstAttribute == .width {
            constraint.isActive = false
        }
        progressFill.widthAnchor.constraint(equalToConstant: total * CGFloat(watchProgress)).isActive = true
    }

    func configure(item: PlexMetadata) {
        titleLabel.text = primaryTitle(for: item)

        // Progress: viewOffset / duration, both in ms on Plex.
        if let duration = item.duration, duration > 0,
           let offset = item.viewOffset {
            watchProgress = min(max(Double(offset) / Double(duration), 0), 1)
            progressBackground.isHidden = false
        } else {
            watchProgress = 0
            progressBackground.isHidden = true
        }
        setNeedsLayout()

        let url = artworkURL(for: item)
        loadImage(from: url)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageLoadTask?.cancel()
        imageLoadTask = nil
        currentURL = nil
        imageView.image = nil
        watchProgress = 0
        progressBackground.isHidden = true
        titleLabel.text = nil
    }

    // MARK: Helpers

    private func primaryTitle(for item: PlexMetadata) -> String {
        if item.type == "episode" {
            // Show name (grandparent) is the user-recognisable title
            return item.grandparentTitle ?? item.title ?? ""
        }
        return item.title ?? ""
    }

    private func loadImage(from url: URL?) {
        imageLoadTask?.cancel()
        guard let url else {
            imageView.image = nil
            currentURL = nil
            return
        }
        if currentURL == url, imageView.image != nil { return }
        currentURL = url
        let key = url.absoluteString as AnyHashable
        imageLoadTask = Task { [weak self] in
            let image: UIImage? = await Perf.interval(.imageDecode, key: key) {
                await ImageCacheManager.shared.image(for: url)
            }
            await MainActor.run {
                guard let self, self.currentURL == url else { return }
                self.imageView.image = image
            }
        }
    }

    private func artworkURL(for item: PlexMetadata) -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken
        else { return nil }
        // Episodes prefer grandparent backdrop; otherwise art > thumb.
        let path: String?
        if item.type == "episode" {
            path = item.grandparentArt ?? item.art ?? item.thumb
        } else {
            path = item.art ?? item.thumb
        }
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(token)")
    }
}
