//
//  CarouselMorphController.swift
//  Rivulet
//
//  Owns the SINGLE UIViewPropertyAnimator + CADisplayLink that drive the
//  carousel expand/collapse morph. One clock owns: the collection-view
//  layout swap (carousel <-> expanded), the backdrop panel container
//  grow/shrink, the chrome inset tween, and the corner-radius lerp.
//  Because there is exactly one timeline, nothing can drift. See
//  docs/superpowers/specs/2026-05-31-two-layout-carousel-morph-design.md
//  and perf-spike/UIKIT_FOUNDATIONS.md §1, §5.
//

import UIKit

@MainActor
final class CarouselMorphController {
    private weak var collectionView: UICollectionView?
    private weak var backdropPlane: BackdropPlaneView?
    private let carouselLayout: PreviewCarouselLayout
    private let expandedLayout: PreviewExpandedLayout

    private var animator: UIViewPropertyAnimator?
    private var displayLink: CADisplayLink?

    /// Index being morphed.
    private var morphingIndex: Int = 0
    /// Corner-radius lerp endpoints for the current morph.
    private var radiusFrom: CGFloat = 0
    private var radiusTo: CGFloat = 0

    init(
        collectionView: UICollectionView,
        backdropPlane: BackdropPlaneView,
        carouselLayout: PreviewCarouselLayout,
        expandedLayout: PreviewExpandedLayout
    ) {
        self.collectionView = collectionView
        self.backdropPlane = backdropPlane
        self.carouselLayout = carouselLayout
        self.expandedLayout = expandedLayout
    }

    var isAnimating: Bool { animator?.isRunning ?? false }

    // MARK: - Expand

    func expand(
        centeredIndex: Int,
        in viewBounds: CGRect,
        cell: PreviewCardView?,
        completion: @escaping () -> Void
    ) {
        guard let cv = collectionView, let plane = backdropPlane else { return }
        morphingIndex = centeredIndex

        plane.isMorphing = true
        expandedLayout.itemCount = carouselLayout.itemCount
        expandedLayout.expandedIndex = centeredIndex

        let animator = UIViewPropertyAnimator(
            duration: PreviewCarouselGeometry.expandAnimationDuration,
            curve: .easeInOut
        )
        animator.addAnimations { [weak self] in
            guard let self else { return }
            // a) Card window (cell) morph under THIS animator's curve.
            cv.setCollectionViewLayout(self.expandedLayout, animated: false)
            cv.layoutIfNeeded()
            // b) Backdrop centered panel container grows to fullscreen.
            plane.expandPanel(centeredIndex, to: viewBounds)
            // c) Chrome insets 118 -> 140.
            cell?.setExpanded(true)
            cell?.contentView.layoutIfNeeded()
        }
        animator.addCompletion { [weak self] _ in
            self?.endMorph()
            completion()
        }
        self.animator = animator
        startRadiusLink(from: PreviewCarouselGeometry.cornerRadius, to: 0)
        animator.startAnimation()
    }

    // MARK: - Collapse

    func collapse(
        centeredIndex: Int,
        cell: PreviewCardView?,
        completion: @escaping () -> Void
    ) {
        guard let cv = collectionView, let plane = backdropPlane else { return }
        morphingIndex = centeredIndex

        // If an expand is mid-flight, reverse it instead of starting fresh.
        if let animator, animator.isRunning {
            animator.isReversed = true
            swap(&radiusFrom, &radiusTo)
            // Reverse the cell's chrome insets too so it tracks the reversal.
            cell?.setExpanded(false)
            return
        }

        let stage = plane.bounds.size
        let window = carouselWindow(centeredIndex, offset: cv.contentOffset)
        let parallax = carouselLayout.parallaxOffset(for: centeredIndex)

        plane.isMorphing = true
        let animator = UIViewPropertyAnimator(
            duration: PreviewCarouselGeometry.expandAnimationDuration,
            curve: .easeInOut
        )
        animator.addAnimations { [weak self] in
            guard let self else { return }
            cv.setCollectionViewLayout(self.carouselLayout, animated: false)
            cv.layoutIfNeeded()
            plane.collapsePanel(centeredIndex, to: window, parallax: parallax, stage: stage)
            cell?.setExpanded(false)
            cell?.contentView.layoutIfNeeded()
        }
        animator.addCompletion { [weak self] _ in
            self?.endMorph()
            completion()
        }
        self.animator = animator
        startRadiusLink(from: 0, to: PreviewCarouselGeometry.cornerRadius)
        animator.startAnimation()
    }

    // MARK: - Corner-radius display link

    private func startRadiusLink(from: CGFloat, to: CGFloat) {
        radiusFrom = from
        radiusTo = to
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tickRadius))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tickRadius() {
        guard let animator, let plane = backdropPlane else { return }
        let raw = animator.fractionComplete
        let t = animator.isReversed ? (1 - raw) : raw
        let r = radiusFrom + (radiusTo - radiusFrom) * t
        plane.setWindowCornerRadius(r, for: morphingIndex)
    }

    private func endMorph() {
        displayLink?.invalidate()
        displayLink = nil
        backdropPlane?.isMorphing = false
        animator = nil
    }

    // MARK: - Geometry

    /// The centered card's window rect in viewport (plane) coords.
    private func carouselWindow(_ index: Int, offset: CGPoint) -> CGRect {
        // Compute the card window directly from the collection view's bounds
        // + the carousel stride math. We CANNOT delegate to
        // carouselLayout.cardFrame here: during collapse the active layout is
        // still PreviewExpandedLayout, so carouselLayout.collectionView is nil
        // and cardFrame would return .zero — which made the backdrop panel
        // collapse to (0,0,0,0) and fly to the top-left corner. (Same stride
        // math as PreviewCarouselLayout.cellFrame, kept in sync.)
        guard let cv = collectionView else { return .zero }
        let geom = PreviewCarouselGeometry.self
        let centeredWidth = cv.bounds.width - 2 * geom.centeredHorizontalInset
        let cardHeight = cv.bounds.height - geom.topInset
        let stride = centeredWidth + geom.sideCardGap
        let edgePad = geom.centeredHorizontalInset
        let x = edgePad + stride * CGFloat(index)
        return CGRect(
            x: x - offset.x,
            y: geom.topInset - offset.y,
            width: centeredWidth,
            height: cardHeight
        )
    }
}
