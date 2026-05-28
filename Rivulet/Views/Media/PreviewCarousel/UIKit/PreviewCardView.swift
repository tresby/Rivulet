//
//  PreviewCardView.swift
//  Rivulet
//
//  Minimal hero card for one slot of the preview carousel. Renders
//  the backdrop image + a title scrim. Designed to keep offscreen
//  passes near zero:
//
//   - Slot container clips to its rounded corner via `cornerRadius` +
//     `cornerCurve = .continuous`. Single mask, applied once.
//   - The backdrop `UIImageView` is opaque and fills the bounds. No
//     transparent fades, no `Material`.
//   - Title scrim is a `CAGradientLayer` (rasterized once during
//     layout, no per-frame blur).
//   - No shadows. No nested clipping.
//
//  The image load goes through `ImageCacheManager.shared.image(for:)`
//  — same cache the SwiftUI version uses, so any perf delta between
//  the two is the rendering pipeline, not the asset pipeline.
//

import UIKit
import os.log

private let previewCardLog = Logger(
    subsystem: "com.rivulet.app",
    category: "PreviewCardView"
)

final class PreviewCardView: UIView {
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

    /// Horizontal translation applied to the inner artwork only.
    /// During paging, the host drives this independently from the
    /// card's frame so the backdrop parallaxes at less than 1.0×
    /// the card's translation. Set to 0 at rest.
    var parallaxOffsetX: CGFloat = 0 {
        didSet {
            guard parallaxOffsetX != oldValue else { return }
            // Disable implicit CATransaction animation — we want the
            // change to apply on the current animation frame only.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdropImageView.transform = CGAffineTransform(translationX: parallaxOffsetX, y: 0)
            CATransaction.commit()
        }
    }

    // MARK: - Subviews

    /// Backdrop fills the slot. Opaque. Scale-aspect-fill so the
    /// image always covers the card; the cornerRadius on `self`
    /// clips overflow.
    private let backdropImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = false  // outer view clips via cornerRadius
        v.isOpaque = true
        v.backgroundColor = .black
        return v
    }()

    /// Bottom gradient scrim so the title is readable against any
    /// image. Implemented as a CAGradientLayer sublayer rather than
    /// a UIView with a gradient image — fewer compositing operations.
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

    /// Title label, drawn directly on top of the scrim. No background
    /// container, no material.
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 56, weight: .heavy)
        l.textColor = .white
        l.numberOfLines = 2
        l.lineBreakMode = .byTruncatingTail
        // Letting the label draw text shadows via NSAttributedString
        // would force an offscreen pass for every render. The scrim
        // gradient alone is enough contrast against any backdrop.
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
        backgroundColor = .black
        // The slot owns the rounded clip. Single mask, no nested
        // clipping below.
        clipsToBounds = true
        layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
        layer.cornerCurve = .continuous

        addSubview(backdropImageView)
        layer.addSublayer(scrimLayer)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            backdropImageView.topAnchor.constraint(equalTo: topAnchor),
            backdropImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropImageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -48),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -56)
        ])
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Scrim spans the bottom 50% of the card.
        let scrimHeight = bounds.height * 0.5
        // Disable implicit animation on layer-frame change so paging
        // doesn't accidentally animate the scrim alongside the slot.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrimLayer.frame = CGRect(
            x: 0,
            y: bounds.height - scrimHeight,
            width: bounds.width,
            height: scrimHeight
        )
        CATransaction.commit()
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
            // No artwork — leave backdrop empty; the black fill is
            // the placeholder.
            backdropImageView.image = nil
            return
        }

        // Fast path: synchronous cache hit. Avoids a Task hop when
        // the image is already in memory.
        if let cached = ImageCacheManager.shared.cachedImage(for: url) {
            backdropImageView.image = cached
            return
        }

        // Cold path: async load. Bail if the card was reconfigured
        // (paged) before the load finished.
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
