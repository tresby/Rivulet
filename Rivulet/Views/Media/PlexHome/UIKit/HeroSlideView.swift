//
//  HeroSlideView.swift
//  Rivulet
//
//  UIKit per-slide hero content: logo (or fallback serif title), metadata
//  row (type · genre · rating-badge) and a single-sentence tagline. Mirror
//  of SwiftUI `HeroSlideContent`.
//
//  Logo image swaps with a brief crossfade (0.22s) on slide change so the
//  beat lines up with `HeroOverlayView.displayedIndex` and the backdrop's
//  own crossfade.
//

import UIKit

@MainActor
final class HeroSlideView: UIView {

    // MARK: - Subviews

    private let logoImageView = UIImageView()
    private let fallbackTitleLabel = UILabel()
    private let metadataLabel = UILabel()
    private let ratingBadge = HeroRatingBadgeView()
    private let metadataRow = UIStackView()
    private let taglineLabel = UILabel()
    private let stack = UIStackView()

    // MARK: - Image loading state

    private var currentLogoURL: URL?
    private var logoLoadTask: Task<Void, Never>?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear

        // Logo
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.setContentHuggingPriority(.required, for: .horizontal)

        // Fallback title (serif heavy, two lines max)
        fallbackTitleLabel.font = .systemFont(ofSize: 72, weight: .heavy)
        fallbackTitleLabel.textColor = .white
        fallbackTitleLabel.numberOfLines = 2
        fallbackTitleLabel.shadowColor = UIColor.black.withAlphaComponent(0.5)
        fallbackTitleLabel.shadowOffset = CGSize(width: 0, height: 3)
        fallbackTitleLabel.isHidden = true

        // Metadata text (type · genre)
        metadataLabel.font = .systemFont(ofSize: 20, weight: .medium)
        metadataLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        metadataLabel.numberOfLines = 1

        // Metadata row container (text + rating badge inline)
        metadataRow.axis = .horizontal
        metadataRow.spacing = 12
        metadataRow.alignment = .center
        metadataRow.addArrangedSubview(metadataLabel)
        metadataRow.addArrangedSubview(ratingBadge)
        ratingBadge.isHidden = true

        // Tagline
        taglineLabel.font = .systemFont(ofSize: 22, weight: .regular)
        taglineLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        taglineLabel.numberOfLines = 2

        // Stack the rows
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(logoImageView)
        stack.addArrangedSubview(fallbackTitleLabel)
        stack.addArrangedSubview(metadataRow)
        stack.addArrangedSubview(taglineLabel)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            logoImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 180),
            logoImageView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),

            taglineLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 720)
        ])
    }

    // MARK: - Configure

    func configure(item: PlexMetadata?, serverURL: String, authToken: String, animated: Bool) {
        guard let item else {
            logoImageView.image = nil
            fallbackTitleLabel.text = nil
            metadataLabel.text = nil
            ratingBadge.isHidden = true
            taglineLabel.text = nil
            return
        }

        // Logo / fallback title
        let logoURL: URL? = {
            guard let path = item.clearLogoPath else { return nil }
            return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(authToken)")
        }()
        loadLogo(from: logoURL, fallbackTitle: item.seriesTitleForDisplay ?? item.title ?? "",
                 animated: animated)

        // Metadata row
        metadataLabel.text = metaLine(for: item)
        if let rating = item.contentRating, !rating.isEmpty {
            ratingBadge.text = rating
            ratingBadge.isHidden = false
        } else {
            ratingBadge.text = nil
            ratingBadge.isHidden = true
        }

        // Tagline
        taglineLabel.text = tagline(for: item)

        if animated {
            // Brief fade-in for the whole stack (matches SwiftUI's
            // `.transition(.opacity)` on slide swap).
            alpha = 0.0
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
                self.alpha = 1
            }
        } else {
            alpha = 1
        }
    }

    // MARK: - Logo loader

    private func loadLogo(from url: URL?, fallbackTitle: String, animated: Bool) {
        logoLoadTask?.cancel()

        if url == currentLogoURL && logoImageView.image != nil {
            // Same logo as before; just refresh fallback label visibility.
            fallbackTitleLabel.text = fallbackTitle
            fallbackTitleLabel.isHidden = true
            logoImageView.isHidden = false
            return
        }
        currentLogoURL = url

        guard let url else {
            logoImageView.image = nil
            logoImageView.isHidden = true
            fallbackTitleLabel.text = fallbackTitle
            fallbackTitleLabel.isHidden = false
            return
        }

        // Show fallback while loading so we never have a blank slot.
        logoImageView.image = nil
        logoImageView.isHidden = true
        fallbackTitleLabel.text = fallbackTitle
        fallbackTitleLabel.isHidden = false

        logoLoadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.currentLogoURL == url else { return }
                guard let image else { return }
                self.logoImageView.image = image
                self.logoImageView.isHidden = false
                self.fallbackTitleLabel.isHidden = true
                if animated {
                    self.logoImageView.alpha = 0
                    UIView.animate(withDuration: 0.22) { self.logoImageView.alpha = 1 }
                }
            }
        }
    }

    // MARK: - Metadata helpers (mirror SwiftUI versions)

    private func metaLine(for item: PlexMetadata) -> String? {
        var parts: [String] = []
        if let type = typeLabel(for: item.type) { parts.append(type) }
        if let firstGenre = item.Genre?.first?.tag, !firstGenre.isEmpty {
            parts.append(firstGenre)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func typeLabel(for type: String?) -> String? {
        switch type {
        case "movie": return "Movie"
        case "show", "season", "episode": return "TV Show"
        case "artist": return "Artist"
        case "album": return "Album"
        case .some(let t): return t.capitalized
        case .none: return nil
        }
    }

    private func tagline(for item: PlexMetadata) -> String? {
        if let explicit = item.tagline, !explicit.isEmpty { return explicit }
        guard let summary = item.summary, !summary.isEmpty else { return nil }
        // First-sentence trim to mirror Apple-TV-style single line.
        if let endIdx = summary.firstIndex(where: { ".!?".contains($0) }) {
            return String(summary[..<summary.index(after: endIdx)])
        }
        return summary
    }
}

/// Small content-rating badge: rounded outline, sized to its text.
@MainActor
final class HeroRatingBadgeView: UIView {
    private let label = UILabel()

    var text: String? {
        get { label.text }
        set {
            label.text = newValue
            invalidateIntrinsicContentSize()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        layer.cornerRadius = 4
        layer.cornerCurve = .continuous

        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
