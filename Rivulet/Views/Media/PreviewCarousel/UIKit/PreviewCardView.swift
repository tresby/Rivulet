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

    /// Backdrop fills the slot. Opaque. Scale-aspect-fill so the
    /// image always covers the card; the cornerRadius on contentView
    /// clips overflow.
    private let backdropImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = false
        v.isOpaque = true
        v.backgroundColor = .black
        return v
    }()

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
            backdropImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdropImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdropImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdropImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

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
        CATransaction.commit()
    }

    // MARK: - Custom layout attribute application

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        // The layout supplies parallaxOffsetX + scrimOpacity through
        // PreviewCardLayoutAttributes. Reading those drives the
        // visual depth-on-motion feel without any per-frame timer.
        guard let attrs = layoutAttributes as? PreviewCardLayoutAttributes else { return }

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

        if let cached = ImageCacheManager.shared.cachedImage(for: url) {
            backdropImageView.image = cached
            return
        }

        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            await MainActor.run {
                guard let self else { return }
                guard self.loadToken == token else {
                    previewCardLog.debug("stale image discarded for token \(token)")
                    return
                }
                self.backdropImageView.image = image
            }
        }
    }
}
