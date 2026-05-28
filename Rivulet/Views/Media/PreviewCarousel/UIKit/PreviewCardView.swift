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
//  Designed to keep offscreen passes near zero:
//   - Single rounded clip on the contentView (cornerRadius + .continuous).
//   - Backdrop UIImageView is opaque, fills bounds, scaleAspectFill.
//   - Title scrim is a CAGradientLayer sublayer (one gradient, no blur).
//   - No shadows. No nested clipping. No Material.
//
//  Image loads go through ImageCacheManager.shared so we share the
//  cache with the SwiftUI version and any perf delta is rendering,
//  not asset pipeline.
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

    /// Monotonic load token. Bumped on every `applyItem()`; the async
    /// image fetch checks against this on completion and discards
    /// stale results. Prevents the wrong artwork from snapping in
    /// when the user pages quickly.
    private var loadToken: UInt64 = 0

    // MARK: - Subviews (inside contentView)

    /// Backdrop is rendered at the FULL SCREEN size, not the card
    /// size. The card's contentView clips to its card-sized bounds
    /// (the visible window), but the image extends past the clip on
    /// all sides. This is the SwiftUI carousel's model: the card is
    /// a viewport mask over a full-screen-sized image, so parallax
    /// translation never runs out of pixels, and expanding the card
    /// to fill the screen reveals the rest of the same image with
    /// no resize.
    ///
    /// Frame is set in layoutSubviews based on the cell's bounds
    /// (which is the card size) and the stage size injected via
    /// PreviewCardLayoutAttributes.stageSize.
    private let backdropImageView: UIImageView = {
        let v = UIImageView()
        // No autolayout — frame is driven manually in layoutSubviews
        // so we can size it to the stage (screen), not the card.
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

    /// Bottom gradient scrim so the title is readable against any
    /// image. Implemented as a CAGradientLayer sublayer (one gradient,
    /// no per-frame blur).
    private let scrimLayer: CAGradientLayer = {
        let g = CAGradientLayer()
        g.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.withAlphaComponent(0.85).cgColor
        ]
        g.locations = [0.0, 0.6, 1.0]
        g.startPoint = CGPoint(x: 0.5, y: 0.0)
        g.endPoint = CGPoint(x: 0.5, y: 1.0)
        return g
    }()

    /// Title label drawn directly on top of the scrim.
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 56, weight: .heavy)
        l.textColor = .white
        l.numberOfLines = 2
        l.lineBreakMode = .byTruncatingTail
        l.isOpaque = false
        return l
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
        // The contentView owns the rounded clip. Single mask, no
        // nested clipping below.
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
        contentView.layer.cornerCurve = .continuous

        contentView.addSubview(backdropImageView)
        contentView.layer.addSublayer(scrimLayer)
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 48),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -48),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -56)
        ])
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Scrim spans the bottom 50% of the card.
        let scrimHeight = contentView.bounds.height * 0.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrimLayer.frame = CGRect(
            x: 0,
            y: contentView.bounds.height - scrimHeight,
            width: contentView.bounds.width,
            height: scrimHeight
        )

        // Position the backdrop image at the FULL STAGE SIZE,
        // centered so the card window reveals the middle of it.
        //
        // The card lives inside a window of bounds.size, but the
        // image is `stageSize` (= screen size) wide and tall. We
        // translate it negatively by (stageSize - bounds.size) / 2
        // so the centered slice of the image fills the card's
        // visible area when at the resting position. The layout
        // attributes then add `parallaxOffsetX` to this baseline
        // for the depth-on-motion effect.
        if stageSize.width > 0 {
            let xOffset = (bounds.width - stageSize.width) / 2
            let yOffset = (bounds.height - stageSize.height) / 2
            backdropImageView.frame = CGRect(
                x: xOffset,
                y: yOffset,
                width: stageSize.width,
                height: stageSize.height
            )
        } else {
            backdropImageView.frame = contentView.bounds
        }
        CATransaction.commit()
    }

    // MARK: - Custom layout attribute application

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        guard let attrs = layoutAttributes as? PreviewCardLayoutAttributes else { return }

        // Update stageSize and trigger layoutSubviews if it changed.
        if attrs.stageSize != stageSize {
            stageSize = attrs.stageSize
            setNeedsLayout()
        }

        // Apply parallax by translating the backdrop image. Wrapped
        // in a no-action CATransaction so the translation tracks the
        // scroll position instantaneously rather than animating
        // across frames (which would lag the carousel scroll).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropImageView.transform = CGAffineTransform(translationX: attrs.parallaxOffsetX, y: 0)
        CATransaction.commit()
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken &+= 1
        backdropImageView.image = nil
        backdropImageView.transform = .identity
        titleLabel.text = nil
        item = nil
    }

    // MARK: - Apply / load

    private func applyItem() {
        loadToken &+= 1
        let token = loadToken

        guard let item = item else {
            backdropImageView.image = nil
            titleLabel.text = nil
            return
        }

        titleLabel.text = item.title

        guard let url = item.artwork.backdrop ?? item.artwork.poster else {
            backdropImageView.image = nil
            return
        }

        // Always go through the async path. ImageCacheManager is an
        // `actor`; the sync `cachedImage(for:)` accessor would
        // require hop-into-actor anyway, and Swift 5 mode doesn't
        // enforce that at compile time — calling it without await
        // appears to compile but the result is unreliable.
        // image(for:) is stale-while-revalidate, so a memory-cache
        // hit returns immediately without network.
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            await MainActor.run {
                guard let self else { return }
                guard self.loadToken == token else { return }
                self.backdropImageView.image = image
            }
        }
    }
}
