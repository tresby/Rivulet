//
//  PreviewCarouselLayout.swift
//  Rivulet
//
//  Custom UICollectionViewLayout for the preview carousel. Models
//  every item as a fixed-width card at a fixed x position along the
//  scroll content, then computes per-cell parallax + alpha falloff
//  from each cell's distance to the centered viewport position.
//
//  The viewport center always aligns with the cell at
//  `contentOffset.x / stride` rounded. The layout returns
//  `PreviewCardLayoutAttributes` carrying:
//
//   - frame:          cell rect in collection-view content space
//   - alpha:          full opacity near center, falls off past the
//                     visible peeks
//   - parallaxOffsetX: artwork translation inside the cell. Equals
//                     -(distanceFromCenter * parallaxFactor), so the
//                     artwork visually lags the card during scroll.
//

import UIKit

/// Custom attributes carrying parallax + alpha + stage info to each
/// cell. Cells read these in `apply(_:)` and translate their inner
/// image accordingly.
final class PreviewCardLayoutAttributes: UICollectionViewLayoutAttributes {
    /// Horizontal translation to apply to the cell's inner artwork.
    /// Computed from the cell's distance from viewport center.
    var parallaxOffsetX: CGFloat = 0

    /// Stage size — the full screen size. The cell uses this to size
    /// its backdrop image view *larger than the card's clip*, so the
    /// parallax translation never runs out of pixels and the visible
    /// card window always shows image content.
    var stageSize: CGSize = .zero

    /// The cell's frame's origin in COLLECTION VIEW coords, minus the
    /// collection view's contentOffset — i.e. the cell's origin in
    /// VIEWPORT coords. Used by the cell to compute its backdrop's
    /// local origin so the backdrop appears at viewport (0, 0) (i.e.
    /// fullscreen) regardless of cell.frame: backdrop.local.origin =
    /// -cellViewportOrigin. Set by the layout for the currently-
    /// centered cell so the expand morph leaves the image stationary.
    /// For peek cells the cell uses the older "centered in cell-local"
    /// math (no anchoring to viewport).
    var cellViewportOrigin: CGPoint = .zero

    /// Whether to use the viewport-anchored formula. True only for the
    /// currently-centered (and expanded) cell; false for peek cells.
    var anchorBackdropToViewport: Bool = false

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! PreviewCardLayoutAttributes
        copy.parallaxOffsetX = parallaxOffsetX
        copy.stageSize = stageSize
        copy.cellViewportOrigin = cellViewportOrigin
        copy.anchorBackdropToViewport = anchorBackdropToViewport
        return copy
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PreviewCardLayoutAttributes else { return false }
        guard parallaxOffsetX == other.parallaxOffsetX else { return false }
        guard stageSize == other.stageSize else { return false }
        guard cellViewportOrigin == other.cellViewportOrigin else { return false }
        guard anchorBackdropToViewport == other.anchorBackdropToViewport else { return false }
        return super.isEqual(object)
    }
}

final class PreviewCarouselLayout: UICollectionViewLayout {
    /// Number of items. Set by the controller before
    /// `prepare()` runs the first time.
    var itemCount: Int = 0

    /// True while the carousel is in expanded-detail mode. The
    /// centered cell at `expandedIndex` gets a fullscreen frame +
    /// zero corner-inset; all other cells get alpha 0 (still laid
    /// out so the system can later collapse back to carousel
    /// without re-dequeueing).
    var isExpanded: Bool = false

    /// The cell index that should occupy the fullscreen frame when
    /// `isExpanded` is true. Caller sets this to `selectedIndex`
    /// before invalidating the layout.
    var expandedIndex: Int = 0

    override class var layoutAttributesClass: AnyClass {
        return PreviewCardLayoutAttributes.self
    }

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
        let attrs = PreviewCardLayoutAttributes(forCellWith: indexPath)

        // Expanded layout short-circuit: the centered cell at
        // `expandedIndex` gets the full collection-view bounds
        // (translated by contentOffset so it sits at viewport origin
        // regardless of scroll position). All other cells get their
        // normal carousel frame but alpha 0 — they stay laid out so
        // the collapse animation can reverse smoothly.
        if isExpanded && indexPath.item == expandedIndex {
            let originX = cv.contentOffset.x
            attrs.frame = CGRect(
                x: originX,
                y: 0,
                width: cv.bounds.width,
                height: cv.bounds.height
            )
            attrs.stageSize = cv.bounds.size
            attrs.parallaxOffsetX = 0
            attrs.alpha = 1
            attrs.zIndex = 100
            attrs.cellViewportOrigin = .zero
            attrs.anchorBackdropToViewport = true
            return attrs
        }

        let frame = cellFrame(for: indexPath.item)
        attrs.frame = frame
        attrs.stageSize = cv.bounds.size
        if isExpanded {
            attrs.alpha = 0
            attrs.zIndex = 0
            return attrs
        }

        // For the CENTERED cell in carousel mode, anchor the backdrop
        // to viewport (0, 0). For peek cells, the cell uses the older
        // center-in-cell math. "Centered" ↔ this cell's center in
        // viewport coords is closest to viewport-center (within half
        // a stride).
        let cellViewportX = frame.origin.x - cv.contentOffset.x
        let cellViewportY = frame.origin.y - cv.contentOffset.y
        attrs.cellViewportOrigin = CGPoint(x: cellViewportX, y: cellViewportY)
        let strideWidth = (cv.bounds.width - 2 * PreviewCarouselGeometry.centeredHorizontalInset) + PreviewCarouselGeometry.sideCardGap
        let cellCenterInViewport = cellViewportX + frame.width / 2
        let viewportMid = cv.bounds.midX
        attrs.anchorBackdropToViewport = abs(cellCenterInViewport - viewportMid) < strideWidth / 2

        // Compute distance from viewport center, normalized to one
        // stride. distanceUnits == 0 means centered; ±1 means
        // exactly one slot to the side.
        let viewportCenterX = cv.bounds.midX
        let cellCenterX = frame.midX
        let distancePx = cellCenterX - viewportCenterX
        let distanceUnits = distancePx / stride

        // Parallax: when the card is to the right of center
        // (distanceUnits > 0), the inner image translates LEFT a
        // bit so the image visually lags the card. Factor 0.30
        // matches the SwiftUI parallaxFactor of 0.70 — artwork
        // moves at 70% of card velocity in world space, which is
        // -0.30 × card-translation in local space.
        attrs.parallaxOffsetX = -distanceUnits * stride * 0.30

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
