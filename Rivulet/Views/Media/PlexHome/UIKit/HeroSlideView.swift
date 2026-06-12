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

        // Fallback title (serif heavy, two lines max).
        // SwiftUI uses `.font(.system(size: 72, weight: .heavy, design: .serif))`.
        // UIFont system fonts gain `.serif` via UIFontDescriptor.withDesign.
        let baseFont = UIFont.systemFont(ofSize: 72, weight: .heavy)
        if let serifDescriptor = baseFont.fontDescriptor.withDesign(.serif) {
            fallbackTitleLabel.font = UIFont(descriptor: serifDescriptor, size: 72)
        } else {
            fallbackTitleLabel.font = baseFont
        }
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

        // Stack the rows. SwiftUI HeroSlideContent uses VStack(spacing: 14)
        // and only the tagline gets an extra `.padding(.top, 4)`. We
        // replicate that by adding a 4pt custom spacing right above the
        // tagline (so visual gap between metadata row and tagline = 14 + 4
        // = 18pt). All other gaps stay at 14pt.
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(logoImageView)
        stack.addArrangedSubview(fallbackTitleLabel)
        stack.addArrangedSubview(metadataRow)
        stack.addArrangedSubview(taglineLabel)
        stack.setCustomSpacing(18, after: metadataRow)

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

    /// Stores the most recent crossfade snapshot so we can clean it up if
    /// configure is called again before the previous fade finishes.
    private weak var inflightCrossfadeSnapshot: UIView?

    func configure(item: PlexMetadata?, serverURL: String, authToken: String,
                   animated: Bool, manageAlpha: Bool = true, onReady: (() -> Void)? = nil) {
        // Snapshot the CURRENT state before we mutate anything — so the
        // fade-out has the old content to anim against. SwiftUI's
        // `.transition(.opacity)` is symmetric: old fades out as new
        // fades in. Just fading the new in would snap the old away.
        let snapshot: UIView?
        if animated, bounds.width > 0, bounds.height > 0 {
            snapshot = self.snapshotView(afterScreenUpdates: false)
            if let snapshot {
                snapshot.frame = self.bounds
                snapshot.isUserInteractionEnabled = false
                self.addSubview(snapshot)
                self.inflightCrossfadeSnapshot?.removeFromSuperview()
                self.inflightCrossfadeSnapshot = snapshot
            }
        } else {
            snapshot = nil
        }

        guard let item else {
            logoImageView.image = nil
            fallbackTitleLabel.text = nil
            metadataLabel.text = nil
            ratingBadge.isHidden = true
            taglineLabel.text = nil
            snapshot?.removeFromSuperview()
            onReady?()
            return
        }

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

        // Logo / fallback title. Loaded LAST so `onReady` fires only after every
        // piece of content (metadata, tagline, logo) is final. Callers gate a
        // fade-in on it so the slide never flashes the fallback text and then
        // jumps to the logo mid-fade.
        let logoURL: URL? = {
            guard let path = item.clearLogoPath else { return nil }
            return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(authToken)")
        }()
        loadLogo(from: logoURL, fallbackTitle: item.seriesTitleForDisplay ?? item.title ?? "",
                 animated: animated, completion: onReady)

        if let snapshot {
            // Old content stays at alpha 1 while new content (this view)
            // is briefly invisible; crossfade swaps the two over 0.22s.
            self.alpha = 0
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
                self.alpha = 1
                snapshot.alpha = 0
            } completion: { [weak self, weak snapshot] _ in
                snapshot?.removeFromSuperview()
                if self?.inflightCrossfadeSnapshot === snapshot {
                    self?.inflightCrossfadeSnapshot = nil
                }
            }
        } else if manageAlpha {
            alpha = 1
        }
    }

    // MARK: - Logo loader

    private func loadLogo(from url: URL?, fallbackTitle: String, animated: Bool,
                          completion: (() -> Void)? = nil) {
        logoLoadTask?.cancel()

        if url == currentLogoURL && logoImageView.image != nil {
            // Same logo as before; just refresh fallback label visibility.
            fallbackTitleLabel.text = fallbackTitle
            fallbackTitleLabel.isHidden = true
            logoImageView.isHidden = false
            completion?()   // already resolved
            return
        }
        currentLogoURL = url

        guard let url else {
            logoImageView.image = nil
            logoImageView.isHidden = true
            fallbackTitleLabel.text = fallbackTitle
            fallbackTitleLabel.isHidden = false
            completion?()   // no logo -> fallback is the final state
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
                if let image {
                    self.logoImageView.image = image
                    self.logoImageView.isHidden = false
                    self.fallbackTitleLabel.isHidden = true
                    if animated {
                        self.logoImageView.alpha = 0
                        UIView.animate(withDuration: 0.22) { self.logoImageView.alpha = 1 }
                    }
                }
                // Resolved: logo loaded, or absent -> the fallback text stays.
                completion?()
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
