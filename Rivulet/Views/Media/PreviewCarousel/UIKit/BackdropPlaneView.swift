//
//  BackdropPlaneView.swift
//  Rivulet
//
//  VC-owned backdrop plane that sits behind the carousel's collection
//  view and is the SINGLE SOURCE OF TRUTH for all on-screen artwork.
//  Renders one oversized (full-stage) panel per visible movie, each
//  positioned + parallaxed from PreviewCarouselLayout geometry, and
//  masks the plane to the rounded-rect card "windows" so artwork only
//  shows through the cards (and never leaks into the inter-card gaps).
//
//  During expand, the centered panel grows to fullscreen and the
//  window mask's corner radii lerp 28 -> 0 — both driven by the morph
//  controller's single animator (see CarouselMorphController). The cell
//  no longer owns any backdrop. See
//  docs/superpowers/specs/2026-05-31-two-layout-carousel-morph-design.md.
//

import UIKit

final class BackdropPlaneView: UIView {
    /// One artwork panel per visible movie index.
    private final class Panel {
        let imageView = UIImageView()
        var index: Int
        var loadToken: UInt64 = 0
        init(index: Int) {
            self.index = index
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = false
            imageView.isOpaque = true
            imageView.backgroundColor = .black
        }
    }

    /// Active panels keyed by movie index.
    private var panels: [Int: Panel] = [:]

    /// The rounded-rect mask cutouts (one per visible card window).
    private let maskLayer = CAShapeLayer()

    /// Current corner radius for the window cutouts. Lerped during morph.
    private var windowCornerRadius: CGFloat = PreviewCarouselGeometry.cornerRadius

    /// Items + image-URL provider injected by the VC.
    private var items: [MediaItem] = []

    /// While a morph is in flight, sync() is suppressed so the morph
    /// controller has exclusive control of panel frames + mask.
    var isMorphing: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.mask = maskLayer
        maskLayer.fillRule = .nonZero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not Storyboard-backed") }

    func configure(items: [MediaItem]) {
        self.items = items
    }

    // MARK: - Carousel-mode sync

    /// Position one panel per visible card, sized to the full stage
    /// (oversized) and offset by the card's parallax, then update the
    /// mask so each card window shows its panel. Called every scroll
    /// tick. Suppressed while morphing.
    func sync(to layout: PreviewCarouselLayout, offset: CGPoint) {
        guard !isMorphing else { return }
        let stage = bounds.size
        let visible = layout.visibleIndices(at: offset)

        // Recycle panels that scrolled away.
        for (idx, panel) in panels where !visible.contains(idx) {
            panel.imageView.removeFromSuperview()
            panels[idx] = nil
        }

        var windowRects: [CGRect] = []
        for idx in visible {
            guard idx >= 0 && idx < items.count else { continue }
            let panel = panels[idx] ?? makePanel(for: idx)
            // Card window in VIEWPORT (plane) coords.
            let cardContent = layout.cardFrame(for: idx)
            let cardWindow = CGRect(
                x: cardContent.origin.x - offset.x,
                y: cardContent.origin.y - offset.y,
                width: cardContent.width,
                height: cardContent.height
            )
            windowRects.append(cardWindow)

            // Panel is full-stage sized, centered on the card window's
            // center, plus parallax. Oversized so the window crops it.
            let parallax = layout.parallaxOffset(for: idx)
            panel.imageView.frame = CGRect(
                x: cardWindow.midX - stage.width / 2 + parallax,
                y: cardWindow.midY - stage.height / 2,
                width: stage.width,
                height: stage.height
            )
        }

        applyMask(windowRects: windowRects)
    }

    private func makePanel(for index: Int) -> Panel {
        let panel = Panel(index: index)
        addSubview(panel.imageView)
        panels[index] = panel
        loadArtwork(into: panel)
        return panel
    }

    private func loadArtwork(into panel: Panel) {
        guard panel.index >= 0 && panel.index < items.count else { return }
        let item = items[panel.index]
        panel.loadToken &+= 1
        let token = panel.loadToken
        // Match PreviewCardView.applyItem() EXACTLY: backdrop falls back
        // to poster; image loaded async via ImageCacheManager.image(for:).
        guard let url = item.artwork.backdrop ?? item.artwork.poster else {
            panel.imageView.image = nil
            return
        }
        Task { [weak panel] in
            let image = await ImageCacheManager.shared.image(for: url)
            await MainActor.run {
                guard let panel, panel.loadToken == token else { return }
                panel.imageView.image = image
            }
        }
    }

    // MARK: - Mask

    /// Rebuild the mask path: one rounded-rect cutout per visible card
    /// window. The plane is visible only inside these cutouts.
    private func applyMask(windowRects: [CGRect]) {
        let path = UIBezierPath()
        for rect in windowRects {
            path.append(UIBezierPath(roundedRect: rect, cornerRadius: windowCornerRadius))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        maskLayer.path = path.cgPath
        CATransaction.commit()
    }

    // MARK: - Morph hooks (driven by CarouselMorphController)

    /// Source rect (current viewport frame) of the panel at `index`.
    /// Used by the morph controller as the morph's start frame.
    func panelRect(for index: Int) -> CGRect {
        return panels[index]?.imageView.frame ?? .zero
    }

    /// Grow the centered panel to `rect` (fullscreen) and collapse the
    /// mask to a single full-screen cutout. Called inside the morph
    /// animator's animation block, so these property changes are tweened
    /// by that animator. `isMorphing` must be true.
    func expandPanel(_ index: Int, to rect: CGRect) {
        panels[index]?.imageView.frame = rect
        let path = UIBezierPath(roundedRect: rect, cornerRadius: windowCornerRadius)
        maskLayer.frame = bounds
        maskLayer.path = path.cgPath
        // Hide non-centered panels during expand.
        for (idx, panel) in panels where idx != index {
            panel.imageView.alpha = 0
        }
    }

    /// Reverse of expandPanel: shrink the centered panel back to its
    /// carousel rect and restore the multi-window mask. Called inside
    /// the (reversed) morph animator's block.
    func collapsePanel(_ index: Int, to rect: CGRect, windowRects: [CGRect]) {
        panels[index]?.imageView.frame = rect
        for (_, panel) in panels { panel.imageView.alpha = 1 }
        let path = UIBezierPath()
        for r in windowRects { path.append(UIBezierPath(roundedRect: r, cornerRadius: windowCornerRadius)) }
        maskLayer.frame = bounds
        maskLayer.path = path.cgPath
    }

    /// Set the window-cutout corner radius (lerped 28<->0 by the morph
    /// controller's display-link tick). Rebuilds the current mask path
    /// at the new radius without animating (the DisplayLink ticks every
    /// frame; CA actions are disabled).
    func setWindowCornerRadius(_ radius: CGFloat, windowRects: [CGRect]) {
        windowCornerRadius = radius
        let path = UIBezierPath()
        for r in windowRects { path.append(UIBezierPath(roundedRect: r, cornerRadius: radius)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = path.cgPath
        CATransaction.commit()
    }
}
