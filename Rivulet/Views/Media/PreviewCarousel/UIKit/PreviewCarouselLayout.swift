//
//  PreviewCarouselLayout.swift
//  Rivulet
//
//  Custom UICollectionViewLayout for the preview carousel. Models
//  every item as a fixed-width card at a fixed x position along the
//  scroll content, then computes per-cell alpha falloff + z-order from
//  each cell's distance to the centered viewport position.
//
//  The viewport center always aligns with the cell at
//  `contentOffset.x / stride` rounded. Cells get plain
//  UICollectionViewLayoutAttributes (frame + alpha + zIndex). The
//  backdrop artwork (position + parallax) is owned by the VC-level
//  BackdropPlaneView, which reads this layout's public geometry API
//  (`cardFrame(for:)`, `parallaxOffset(for:)`, `visibleIndices(at:)`).
//  Expanded geometry lives in PreviewExpandedLayout; the morph swaps
//  between the two via setCollectionViewLayout(_:animated:). See
//  docs/superpowers/specs/2026-05-31-two-layout-carousel-morph-design.md.
//

import UIKit

final class PreviewCarouselLayout: UICollectionViewLayout {
    /// Number of items. Set by the controller before
    /// `prepare()` runs the first time.
    var itemCount: Int = 0

    override var collectionViewContentSize: CGSize {
        guard let cv = collectionView, itemCount > 0 else { return .zero }
        // Content is item count * stride, plus enough leading +
        // trailing padding so the first and last items can center
        // in the viewport. Padding = (viewport width - card width) / 2.
        let centeredWidth = cv.bounds.width - 2 * PreviewCarouselGeometry.centeredHorizontalInset
        let stride = centeredWidth + PreviewCarouselGeometry.sideCardGap
        let totalCardSpan = stride * CGFloat(itemCount) - PreviewCarouselGeometry.sideCardGap
        // Pad on both sides so item 0 and item N-1 can center.
        let edgePad = PreviewCarouselGeometry.centeredHorizontalInset
        return CGSize(width: totalCardSpan + 2 * edgePad, height: cv.bounds.height)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        // Every scroll position change invalidates layout so parallax
        // and alpha track the offset continuously. The actual frames
        // depend on the *collection view's bounds origin* (which is
        // contentOffset), so we must recompute attrs each frame.
        return true
    }

    private func cellFrame(for index: Int) -> CGRect {
        guard let cv = collectionView else { return .zero }
        let centeredWidth = cv.bounds.width - 2 * PreviewCarouselGeometry.centeredHorizontalInset
        let cardHeight = cv.bounds.height - PreviewCarouselGeometry.topInset
        let stride = centeredWidth + PreviewCarouselGeometry.sideCardGap
        let edgePad = PreviewCarouselGeometry.centeredHorizontalInset
        let x = edgePad + stride * CGFloat(index)
        return CGRect(
            x: x,
            y: PreviewCarouselGeometry.topInset,
            width: centeredWidth,
            height: cardHeight
        )
    }

    /// Stride (one card + gap) in points. Public so the controller
    /// can compute paging targets without re-deriving from geometry
    /// constants.
    var stride: CGFloat {
        guard let cv = collectionView else { return 0 }
        let centeredWidth = cv.bounds.width - 2 * PreviewCarouselGeometry.centeredHorizontalInset
        return centeredWidth + PreviewCarouselGeometry.sideCardGap
    }

    /// Content offset that centers the given index in the viewport.
    /// Used by the controller for entry placement and paging.
    func contentOffsetCentered(index: Int) -> CGPoint {
        return CGPoint(x: stride * CGFloat(index), y: 0)
    }

    // MARK: - Public geometry (consumed by BackdropPlaneView)

    /// The card's frame in collection-view content space, carousel mode.
    /// Public so the backdrop plane can position its panels to match the
    /// card windows exactly. This is the same math as the private
    /// `cellFrame(for:)`; exposed without the expanded short-circuit.
    func cardFrame(for index: Int) -> CGRect {
        return cellFrame(for: index)
    }

    /// The artwork parallax offset (in points) for the card at `index`,
    /// given the current contentOffset. Mirrors the `parallaxOffsetX`
    /// computed in `layoutAttributesForItem`. Positive contentOffset to
    /// the card's left yields negative offset (artwork lags the card).
    func parallaxOffset(for index: Int) -> CGFloat {
        guard let cv = collectionView else { return 0 }
        let frame = cellFrame(for: index)
        let viewportCenterX = cv.bounds.midX
        let distancePx = frame.midX - viewportCenterX
        let distanceUnits = distancePx / stride
        return -distanceUnits * stride * 0.30
    }

    /// Indices whose card frames intersect the current viewport, widened
    /// by one card each side so the plane pre-warms upcoming panels.
    func visibleIndices(at offset: CGPoint) -> [Int] {
        guard let cv = collectionView, itemCount > 0 else { return [] }
        let edgePad = PreviewCarouselGeometry.centeredHorizontalInset
        let minIndex = max(0, Int(floor((offset.x - edgePad) / stride)) - 1)
        let maxIndex = min(itemCount - 1, Int(ceil((offset.x + cv.bounds.width - edgePad) / stride)) + 1)
        if minIndex > maxIndex { return [] }
        return Array(minIndex...maxIndex)
    }

    // MARK: - Layout queries

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let cv = collectionView, itemCount > 0 else { return nil }
        let centeredWidth = cv.bounds.width - 2 * PreviewCarouselGeometry.centeredHorizontalInset
        let stride = centeredWidth + PreviewCarouselGeometry.sideCardGap
        let edgePad = PreviewCarouselGeometry.centeredHorizontalInset

        // Determine which indices intersect `rect`. Widen the window
        // by 2 cells on each side so the collection view dequeues
        // upcoming cells *before* they're visible. This pre-warms
        // their async image loads, so paging animations don't stall
        // halfway through waiting for artwork to load.
        let minIndex = max(0, Int(floor((rect.minX - edgePad) / stride)) - 2)
        let maxIndex = min(itemCount - 1, Int(ceil((rect.maxX - edgePad) / stride)) + 2)
        if minIndex > maxIndex { return [] }

        var result: [UICollectionViewLayoutAttributes] = []
        result.reserveCapacity(maxIndex - minIndex + 1)
        for i in minIndex...maxIndex {
            if let attrs = layoutAttributesForItem(at: IndexPath(item: i, section: 0)) {
                result.append(attrs)
            }
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let cv = collectionView else { return nil }
        let attrs = UICollectionViewLayoutAttributes(forCellWith: indexPath)

        // Carousel-only layout. Expanded geometry lives in
        // PreviewExpandedLayout; the morph swaps layouts via
        // setCollectionViewLayout(_:animated:) under the morph animator.
        // The backdrop (parallax + position) is owned by BackdropPlaneView,
        // which reads geometry from this layout's public API — the cell
        // only needs frame + alpha + zIndex here.
        let frame = cellFrame(for: indexPath.item)
        attrs.frame = frame

        // Distance from viewport center, normalized to one stride, drives
        // the alpha falloff + z-order below. (Parallax for the backdrop is
        // computed separately in `parallaxOffset(for:)`.)
        let viewportCenterX = cv.bounds.midX
        let cellCenterX = frame.midX
        let distancePx = cellCenterX - viewportCenterX
        let distanceUnits = distancePx / stride

        // Alpha falloff. Center cell fully visible, peeks fully
        // visible, anything beyond fades out fast.
        let absDist = abs(distanceUnits)
        if absDist <= 1.0 {
            attrs.alpha = 1.0
        } else if absDist <= 1.6 {
            // Smooth tail from peek edge to fully invisible.
            let t = (absDist - 1.0) / 0.6
            attrs.alpha = 1.0 - t
        } else {
            attrs.alpha = 0
        }

        // Z-order: center is on top. Negative zIndex on far cells
        // keeps them behind closer ones during a paging animation.
        attrs.zIndex = -Int(absDist * 10)

        return attrs
    }
}
