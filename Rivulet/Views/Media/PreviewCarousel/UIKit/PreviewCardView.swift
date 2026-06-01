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
//  This cell is the carousel-stable host of `MediaDetailChromeView`.
//  Layout of the chrome content itself (logo / genre / description /
//  quality / action+cast row) lives in `MediaDetailChromeView` so the
//  same code drives the expanded-detail surface. The cell adds:
//   - backdrop (full-stage sized, parallaxed, clipped by the card)
//   - vignette gradients (left + bottom)
//   - corner-clipped card window
//   - the chrome cascade (vignette + chrome alpha 0→1 on becoming current)
//
//  Chrome cascade (selected center cell only):
//   - Vignette gradients (left scrim + bottom scrim) fade in 140ms
//     after paging settles, over 260ms easeOut.
//   - Chrome view (logo + metadata + action row) fades in 210ms after
//     paging settles (70ms after vignette), over 480ms easeOut.
//   - On paging start, both snap to alpha 0 (no fade-out).
//   Timings match perf-spike research from the SwiftUI source
//   (see perf-spike/CAROUSEL_COMPARISON.md research notes).
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

    /// Current item this card is showing. `nil` means the card is idle
    /// (cleared for reuse). Setting forwards to the chrome view and
    /// kicks off the backdrop image load here.
    var item: MediaItem? {
        didSet {
            guard item != oldValue else { return }
            applyItem()
        }
    }

    /// Whether this cell is the currently-focused / centered card in
    /// the carousel. Drives the chrome cascade — only the current
    /// cell shows vignette + chrome. Side peeks render bare backdrop.
    ///
    /// Use `setIsCurrent(_:animated:)` rather than assigning directly
    /// so the cascade fires with the right animation behavior.
    private(set) var isCurrent: Bool = false

    /// Monotonic load token for the backdrop image fetch. Chrome view
    /// owns its own token for logo/detail fetches.
    private var loadToken: UInt64 = 0

    /// Monotonic cascade token. Bumped on every `setIsCurrent` so any
    /// in-flight delayed UIView.animate blocks from a prior cascade
    /// no-op if the cell is paged away before they fire.
    private var cascadeToken: UInt64 = 0

    // MARK: - Subviews

    /// Vignette container — holds left + bottom gradient sublayers.
    /// Alpha 0 by default; cascade fades to 1.
    private let vignetteContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        v.alpha = 0
        return v
    }()

    /// Left-side darkening gradient. Subtle — peaks at 0.7 black at
    /// the leading edge, drops to 0.12 at 42% across, clears at 55%.
    /// Matches MediaDetailView.swift:1657-1666 stops exactly.
    private let leftGradientLayer: CAGradientLayer = {
        let g = CAGradientLayer()
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        g.colors = [
            UIColor.black.withAlphaComponent(0.70).cgColor,
            UIColor.black.withAlphaComponent(0.40).cgColor,
            UIColor.black.withAlphaComponent(0.12).cgColor,
            UIColor.clear.cgColor
        ]
        g.locations = [0.0, 0.25, 0.42, 0.55]
        return g
    }()

    /// Bottom-fading gradient. Five-stop ramp from clear (top) to
    /// 0.95 black (bottom). Covers 55% of the card height.
    /// Matches MediaDetailView.swift:1673-1683 stops exactly.
    private let bottomGradientLayer: CAGradientLayer = {
        let g = CAGradientLayer()
        g.startPoint = CGPoint(x: 0.5, y: 0)
        g.endPoint = CGPoint(x: 0.5, y: 1)
        g.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.25).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.withAlphaComponent(0.80).cgColor,
            UIColor.black.withAlphaComponent(0.95).cgColor
        ]
        g.locations = [0.0, 0.2, 0.4, 0.65, 1.0]
        return g
    }()

    /// Shared chrome view (logo / genre / description / quality /
    /// action+cast). Anchored bottom-leading inside the card with
    /// `heroOverlayHorizontalInset` (118pt in carousel-stable mode,
    /// 140pt in expanded mode) and 220pt up from the bottom (shelf
    /// peek reserve). Alpha 0 by default; cascade fades `chromeAlpha`
    /// to 1.
    private let chromeView: MediaDetailChromeView = {
        let v = MediaDetailChromeView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.mode = .carouselStable
        v.chromeAlpha = 0
        return v
    }()

    /// Leading chrome inset constraint. The host carousel VC mutates
    /// `.constant` during the expand morph to slide chrome inward
    /// (118 → 140). Same view, same constraint, same chrome subview
    /// tree throughout — true visual continuity.
    private var chromeLeadingConstraint: NSLayoutConstraint!

    /// Trailing chrome inset constraint. Mirrors leading (constants
    /// are negative). The host mutates this to keep the chrome
    /// symmetric during morph.
    private var chromeTrailingConstraint: NSLayoutConstraint!

    /// Chrome bottom inset constraint (the shelf-peek reserve). In
    /// carousel mode this is -220 (movie) or -160 (TV) from the card
    /// bottom; same value used in expanded mode (no animation).
    /// Exposed for future iter where TV shows shrink the peek.
    private var chromeBottomConstraint: NSLayoutConstraint!

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
        // Transparent: the VC-owned BackdropPlaneView renders artwork
        // behind the collection view, masked to the card windows. The
        // cell holds only vignette + chrome. No corner clip here — the
        // rounded window is the plane's mask (see BackdropPlaneView).
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false

        vignetteContainer.layer.addSublayer(leftGradientLayer)
        vignetteContainer.layer.addSublayer(bottomGradientLayer)
        contentView.addSubview(vignetteContainer)
        contentView.addSubview(chromeView)

        chromeLeadingConstraint = chromeView.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: PreviewCarouselGeometry.carouselChromeInset
        )
        chromeTrailingConstraint = chromeView.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -PreviewCarouselGeometry.carouselChromeInset
        )
        chromeBottomConstraint = chromeView.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor,
            constant: -PreviewCarouselGeometry.carouselChromeShelfPeek
        )

        NSLayoutConstraint.activate([
            // Vignette covers the full card; gradient stops do the fade.
            vignetteContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            vignetteContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            vignetteContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            vignetteContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Chrome anchored bottom-leading inside the card. The host
            // animates the inset constraint constants during expand to
            // morph 118 → 140 (carousel → expanded). Same view, same
            // constraint instance — no second view tree.
            chromeLeadingConstraint,
            chromeTrailingConstraint,
            chromeBottomConstraint
        ])
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        // Backdrop frame is updated from `apply()` (animatable, rides
        // the UIView.animate curve) — not here. layoutSubviews fires
        // mid-animation, and re-setting backdrop.frame inside a
        // disabled-actions CATransaction would snap it to its new
        // target instead of letting the morph animation interpolate.

        // Vignette gradient frames match the container bounds. Left
        // gradient covers full height + first 55% width (clipped by
        // the gradient stops themselves); bottom covers full width +
        // bottom 55% height. These NEED disabled actions because they
        // shouldn't animate; only the backdrop and chrome constraint
        // tweens ride the expand curve.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
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
        // Backdrop + parallax are owned by BackdropPlaneView now. The
        // cell only consumes frame + alpha from the layout (handled by
        // super). Nothing cell-local to update here.
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken &+= 1
        cascadeToken &+= 1
        isCurrent = false
        vignetteContainer.alpha = 0
        chromeView.chromeAlpha = 0
        chromeView.reset()
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
        let currentChromeAlpha = chromeView.layer.presentation()?.opacity ?? Float(chromeView.chromeAlpha)
        vignetteContainer.layer.removeAllAnimations()
        chromeView.layer.removeAllAnimations()
        vignetteContainer.alpha = CGFloat(currentVignetteAlpha)
        chromeView.chromeAlpha = CGFloat(currentChromeAlpha)

        if !current {
            // Snap to invisible. No fade-out — matches SwiftUI behavior.
            vignetteContainer.alpha = 0
            chromeView.chromeAlpha = 0
            return
        }

        if !animated {
            vignetteContainer.alpha = 1
            chromeView.chromeAlpha = 1
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
            self.chromeView.chromeAlpha = 1
        }
    }

    // MARK: - Apply

    private func applyItem() {
        loadToken &+= 1

        // Forward to chrome view — it owns logo + metadata + detail fetch.
        // Backdrop artwork is owned by BackdropPlaneView now.
        chromeView.item = item
    }

    // MARK: - Expand state

    /// Set chrome layout mode + insets for carousel vs expanded. Corner
    /// radius and backdrop are no longer the cell's concern (plane owns
    /// them). Kept minimal; the morph controller drives the animation.
    func setExpanded(_ expanded: Bool) {
        let inset = expanded
            ? PreviewCarouselGeometry.expandedChromeInset
            : PreviewCarouselGeometry.carouselChromeInset
        chromeLeadingConstraint.constant = inset
        chromeTrailingConstraint.constant = -inset
        chromeView.mode = expanded ? .expandedDetail : .carouselStable
    }
}
