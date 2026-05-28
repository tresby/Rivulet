//
//  PreviewCardView.swift
//  Rivulet
//
//  One hero card in the preview carousel. A UICollectionViewCell so
//  the collection view handles cell recycling + positioning; we
//  override `apply(_:)` to read parallax + alpha from custom layout
//  attributes computed by `PreviewCarouselLayout` based on the
//  cell's distance from the centered viewport position.
//
//  Chrome cascade (selected center cell only):
//   - Vignette gradients (left scrim + bottom scrim) fade in 140ms
//     after paging settles, over 260ms easeOut.
//   - Title logo + metadata stack fade in 210ms after paging settles
//     (70ms after vignette), over 480ms easeOut.
//   - On paging start, both snap to alpha 0 (no fade-out).
//   Timings match perf-spike research from the SwiftUI source
//   (page-cascade branch — see perf-spike/CAROUSEL_COMPARISON.md
//   research notes).
//
//  Designed to keep offscreen passes near zero outside the entry
//  storm: single rounded clip on contentView, opaque backdrop, no
//  Material, no shadows. CAGradientLayer sublayers for the vignette
//  (one offscreen pass each, rasterized by Core Animation once).
//

import UIKit
import os.log

private let previewCardLog = Logger(
    subsystem: "com.rivulet.app",
    category: "PreviewCardView"
)

final class PreviewCardView: UICollectionViewCell {
    static let reuseIdentifier = "PreviewCardCell"

    // MARK: - State

    /// Current item this card is showing. `nil` means the card is
    /// idle (cleared for reuse). Setting the property kicks off
    /// artwork loading.
    var item: MediaItem? {
        didSet {
            guard item != oldValue else { return }
            applyItem()
        }
    }

    /// Whether this cell is the currently-focused / centered card in
    /// the carousel. Drives the chrome cascade — only the current
    /// cell shows vignette + metadata. Side peeks render bare
    /// backdrop only.
    ///
    /// Use `setIsCurrent(_:animated:)` rather than assigning directly
    /// so the cascade fires with the right animation behavior.
    private(set) var isCurrent: Bool = false

    /// Monotonic load token. Bumped on every `applyItem()`; the async
    /// image fetch checks against this on completion and discards
    /// stale results. Prevents the wrong artwork from snapping in
    /// when the user pages quickly.
    private var loadToken: UInt64 = 0

    /// Monotonic cascade token. Bumped on every cascade kickoff so
    /// any in-flight delayed animations from a prior cascade are
    /// discarded if the cell is paged away before they fire.
    private var cascadeToken: UInt64 = 0

    // MARK: - Subviews (inside contentView)

    /// Backdrop is rendered at the FULL SCREEN size, not the card
    /// size. The card's contentView clips to its card-sized bounds
    /// (the visible window), but the image extends past the clip on
    /// all sides. Manual frame management — see layoutSubviews.
    private let backdropImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = true
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = false
        v.isOpaque = true
        v.backgroundColor = .black
        return v
    }()

    /// Stage size — full screen size, set by the layout's
    /// PreviewCardLayoutAttributes. Used to size the backdrop image
    /// view so it extends past the cell's clip on all sides.
    private var stageSize: CGSize = .zero

    /// Parallax offset from the latest layout attributes. Applied as
    /// a delta to backdropImageView.center.x in layoutSubviews so we
    /// never have to juggle frame + transform on the same view (which
    /// UIKit explicitly warns is undefined).
    private var parallaxOffsetX: CGFloat = 0

    /// Vignette container — holds left + bottom gradient sublayers.
    /// Alpha 0 by default; cascade fades to 1.
    private let vignetteContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        v.alpha = 0
        return v
    }()

    /// Left-side darkening gradient. Black at the leading edge fading
    /// to clear at ~55% across. Used to anchor the chrome legibly
    /// against any backdrop image.
    private let leftGradientLayer: CAGradientLayer = {
        let g = CAGradientLayer()
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        g.colors = [
            UIColor.black.withAlphaComponent(0.70).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.withAlphaComponent(0.30).cgColor,
            UIColor.clear.cgColor
        ]
        g.locations = [0.0, 0.25, 0.42, 0.55]
        return g
    }()

    /// Bottom-fading gradient. Clear at the top, black at the bottom.
    /// Covers ~55% of the card height.
    private let bottomGradientLayer: CAGradientLayer = {
        let g = CAGradientLayer()
        g.startPoint = CGPoint(x: 0.5, y: 0)
        g.endPoint = CGPoint(x: 0.5, y: 1)
        g.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.50).cgColor,
            UIColor.black.withAlphaComponent(0.95).cgColor
        ]
        g.locations = [0.0, 0.55, 1.0]
        return g
    }()

    /// Chrome container — holds title (logo image or fallback label)
    /// plus metadata stack. Positioned bottom-leading. Alpha 0 by
    /// default; cascade fades to 1.
    private let chromeContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        v.alpha = 0
        return v
    }()

    /// Title logo image — preferred when the item has a logo URL.
    /// Sized 620 wide, 138 tall max (matches SwiftUI heroLogoSlot).
    private let titleLogoImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        // Pin the logo's natural alignment to the bottom-left of its
        // slot so smaller logos don't drift upward into the card.
        v.layer.anchorPoint = CGPoint(x: 0, y: 1)
        return v
    }()

    /// Title text fallback — shown when the item has no logo URL.
    /// Hidden when the logo image is visible.
    private let titleFallbackLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 52, weight: .heavy)
        l.textColor = .white
        l.numberOfLines = 2
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    /// Metadata row — year · runtime · kind. Horizontal stack with
    /// thin separator labels between fields.
    private let metadataStack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.spacing = 12
        s.alignment = .center
        return s
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewCardView is not Storyboard-backed")
    }

    private func commonInit() {
        backgroundColor = .clear
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
        contentView.layer.cornerCurve = .continuous

        contentView.addSubview(backdropImageView)
        vignetteContainer.layer.addSublayer(leftGradientLayer)
        vignetteContainer.layer.addSublayer(bottomGradientLayer)
        contentView.addSubview(vignetteContainer)
        contentView.addSubview(chromeContainer)

        chromeContainer.addSubview(titleLogoImageView)
        chromeContainer.addSubview(titleFallbackLabel)
        chromeContainer.addSubview(metadataStack)

        NSLayoutConstraint.activate([
            // Vignette covers the full card; the gradient layers do
            // the actual fading.
            vignetteContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            vignetteContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            vignetteContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            vignetteContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Chrome anchored bottom-leading with generous insets.
            chromeContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 56),
            chromeContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -56),
            chromeContainer.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -56),

            // Title logo at the top of the chrome stack. Caps at
            // 620 wide, 138 tall — matches SwiftUI heroLogoSlot.
            titleLogoImageView.topAnchor.constraint(equalTo: chromeContainer.topAnchor),
            titleLogoImageView.leadingAnchor.constraint(equalTo: chromeContainer.leadingAnchor),
            titleLogoImageView.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            titleLogoImageView.heightAnchor.constraint(equalToConstant: 138),

            // Fallback label occupies the same slot (one of the two
            // will be hidden depending on whether a logo loaded).
            titleFallbackLabel.topAnchor.constraint(equalTo: chromeContainer.topAnchor),
            titleFallbackLabel.leadingAnchor.constraint(equalTo: chromeContainer.leadingAnchor),
            titleFallbackLabel.trailingAnchor.constraint(equalTo: chromeContainer.trailingAnchor),

            // Metadata stack 16pt below the title logo / label.
            metadataStack.topAnchor.constraint(equalTo: titleLogoImageView.bottomAnchor, constant: 16),
            metadataStack.leadingAnchor.constraint(equalTo: chromeContainer.leadingAnchor),
            metadataStack.bottomAnchor.constraint(equalTo: chromeContainer.bottomAnchor)
        ])
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Backdrop at full stage size, centered + parallaxed.
        if stageSize.width > 0 {
            backdropImageView.bounds = CGRect(origin: .zero, size: stageSize)
        } else {
            backdropImageView.bounds = CGRect(origin: .zero, size: contentView.bounds.size)
        }
        backdropImageView.center = CGPoint(
            x: contentView.bounds.midX + parallaxOffsetX,
            y: contentView.bounds.midY
        )

        // Vignette gradient frames match the container bounds. Left
        // gradient covers full height + first 55% width (clipped by
        // the gradient stops themselves); bottom covers full width +
        // bottom 55% height.
        let bounds = contentView.bounds
        leftGradientLayer.frame = bounds
        let bottomHeight = bounds.height * 0.55
        bottomGradientLayer.frame = CGRect(
            x: 0,
            y: bounds.height - bottomHeight,
            width: bounds.width,
            height: bottomHeight
        )

        CATransaction.commit()
    }

    // MARK: - Custom layout attribute application

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        guard let attrs = layoutAttributes as? PreviewCardLayoutAttributes else { return }

        if attrs.stageSize != stageSize {
            stageSize = attrs.stageSize
        }

        parallaxOffsetX = attrs.parallaxOffsetX
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropImageView.center = CGPoint(
            x: contentView.bounds.midX + parallaxOffsetX,
            y: contentView.bounds.midY
        )
        CATransaction.commit()
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken &+= 1
        cascadeToken &+= 1
        backdropImageView.image = nil
        parallaxOffsetX = 0
        isCurrent = false
        vignetteContainer.alpha = 0
        chromeContainer.alpha = 0
        titleLogoImageView.image = nil
        titleFallbackLabel.text = nil
        titleLogoImageView.isHidden = false
        titleFallbackLabel.isHidden = false
        metadataStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        item = nil
    }

    // MARK: - Chrome cascade

    /// Update whether this cell is the currently-focused center card,
    /// optionally with the timed fade-in cascade.
    ///
    /// Passing `animated: true` runs the SwiftUI page-cascade timing:
    /// vignette fades in 140ms after call, chrome fades in 210ms after
    /// call (70ms stagger). Passing `animated: false` snaps to the
    /// final alpha values — used when the user pages away.
    func setIsCurrent(_ current: Bool, animated: Bool) {
        guard isCurrent != current || !animated else { return }
        isCurrent = current
        cascadeToken &+= 1
        let token = cascadeToken

        // Cancel any in-flight animations by reading the current
        // presentation alpha and committing it as the model value,
        // then issuing the new animation from there.
        let currentVignetteAlpha = vignetteContainer.layer.presentation()?.opacity ?? Float(vignetteContainer.alpha)
        let currentChromeAlpha = chromeContainer.layer.presentation()?.opacity ?? Float(chromeContainer.alpha)
        vignetteContainer.layer.removeAllAnimations()
        chromeContainer.layer.removeAllAnimations()
        vignetteContainer.alpha = CGFloat(currentVignetteAlpha)
        chromeContainer.alpha = CGFloat(currentChromeAlpha)

        if !current {
            // Snap to invisible. No fade-out — matches SwiftUI behavior.
            vignetteContainer.alpha = 0
            chromeContainer.alpha = 0
            return
        }

        if !animated {
            vignetteContainer.alpha = 1
            chromeContainer.alpha = 1
            return
        }

        // Cascade: vignette at 140ms / 260ms duration, chrome at
        // 210ms / 480ms duration. Both easeOut.
        UIView.animate(
            withDuration: 0.26,
            delay: 0.14,
            options: [.curveEaseOut, .allowUserInteraction]
        ) { [weak self] in
            guard let self, self.cascadeToken == token else { return }
            self.vignetteContainer.alpha = 1
        }
        UIView.animate(
            withDuration: 0.48,
            delay: 0.21,
            options: [.curveEaseOut, .allowUserInteraction]
        ) { [weak self] in
            guard let self, self.cascadeToken == token else { return }
            self.chromeContainer.alpha = 1
        }
    }

    // MARK: - Apply / load

    private func applyItem() {
        loadToken &+= 1
        let token = loadToken

        // Clear chrome content while item changes. Cascade alpha
        // managed by setIsCurrent — we just rebuild the contents.
        titleLogoImageView.image = nil
        titleFallbackLabel.text = nil
        metadataStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let item = item else {
            backdropImageView.image = nil
            return
        }

        // Title: show fallback text immediately; if a logo URL exists,
        // try to load it and swap to the image when it lands.
        titleFallbackLabel.text = item.title
        titleFallbackLabel.isHidden = false
        titleLogoImageView.isHidden = true

        // Metadata row.
        rebuildMetadataStack(for: item)

        // Backdrop load.
        if let url = item.artwork.backdrop ?? item.artwork.poster {
            Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                await MainActor.run {
                    guard let self else { return }
                    guard self.loadToken == token else { return }
                    self.backdropImageView.image = image
                }
            }
        } else {
            backdropImageView.image = nil
        }

        // Logo load — only if present. Falls back to text otherwise.
        if let logoURL = item.artwork.logo {
            Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: logoURL)
                await MainActor.run {
                    guard let self else { return }
                    guard self.loadToken == token else { return }
                    guard let image else { return }  // keep fallback text if logo failed
                    self.titleLogoImageView.image = image
                    self.titleLogoImageView.isHidden = false
                    self.titleFallbackLabel.isHidden = true
                }
            }
        }
    }

    private func rebuildMetadataStack(for item: MediaItem) {
        // Year · Runtime · Kind label
        var parts: [String] = []
        if let year = item.year {
            parts.append(String(year))
        }
        if let runtime = item.runtime, runtime > 0 {
            parts.append(Self.formatRuntime(runtime))
        }
        parts.append(Self.formatKind(item.kind))

        for (i, part) in parts.enumerated() {
            if i > 0 {
                metadataStack.addArrangedSubview(Self.makeSeparator())
            }
            metadataStack.addArrangedSubview(Self.makeMetadataLabel(part))
        }
    }

    private static func formatRuntime(_ runtime: TimeInterval) -> String {
        let minutes = Int(runtime / 60)
        let hours = minutes / 60
        let remaining = minutes % 60
        if hours > 0 {
            return remaining > 0 ? "\(hours)h \(remaining)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    private static func formatKind(_ kind: MediaKind) -> String {
        switch kind {
        case .movie: return "Movie"
        case .show: return "TV Show"
        case .season: return "Season"
        case .episode: return "Episode"
        case .collection: return "Collection"
        case .person: return "Person"
        case .unknown: return ""
        }
    }

    private static func makeMetadataLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = text
        l.font = .systemFont(ofSize: 22, weight: .semibold)
        l.textColor = UIColor.white.withAlphaComponent(0.85)
        return l
    }

    private static func makeSeparator() -> UILabel {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = "·"
        l.font = .systemFont(ofSize: 22, weight: .semibold)
        l.textColor = UIColor.white.withAlphaComponent(0.5)
        return l
    }
}
