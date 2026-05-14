//
//  HeroCell.swift
//  Rivulet
//
//  Hero carousel cell for the UIKit home. Full-width backdrop with
//  title-logo / metadata overlay. Currently a placeholder visual; the
//  hero section is not enabled in PlexHomeViewController until the
//  basic structure is verified — once the rest of the view renders
//  correctly the hero gets enabled.
//

import UIKit

@MainActor
final class HeroCell: UICollectionViewCell {
    static let reuseID = "HeroCell"

    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private var imageLoadTask: Task<Void, Never>?
    private var currentURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        contentView.addSubview(imageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 56, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.shadowColor = .black
        titleLabel.shadowOffset = CGSize(width: 0, height: 2)
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 60),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -60),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -60)
        ])
    }

    func configure(item: PlexMetadata) {
        titleLabel.text = item.title
        let url = backdropURL(for: item)
        loadImage(from: url)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageLoadTask?.cancel()
        imageLoadTask = nil
        currentURL = nil
        imageView.image = nil
        titleLabel.text = nil
    }

    private func loadImage(from url: URL?) {
        imageLoadTask?.cancel()
        guard let url else { return }
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

    private func backdropURL(for item: PlexMetadata) -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken
        else { return nil }
        let path = item.art ?? item.thumb
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(token)")
    }
}
