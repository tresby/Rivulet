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

/// Custom attributes carrying parallax + alpha info to each cell.
/// Cells read these in `apply(_:)` and translate their inner image.
final class PreviewCardLayoutAttributes: UICollectionViewLayoutAttributes {
    /// Horizontal translation to apply to the cell's inner artwork.
    /// Computed from the cell's distance from viewport center.
    var parallaxOffsetX: CGFloat = 0

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! PreviewCardLayoutAttributes
        copy.parallaxOffsetX = parallaxOffsetX
        return copy
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PreviewCardLayoutAttributes else { return false }
        guard parallaxOffsetX == other.parallaxOffsetX else { return false }
        return super.isEqual(object)
    }
}

final class PreviewCarouselLayout: UICollectionViewLayout {
    /// Number of items. Set by the controller before
    /// `prepare()` runs the first time.
    var itemCount: Int = 0

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

    // MARK: - Layout queries

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let cv = collectionView, itemCount > 0 else { return nil }
        let centeredWidth = cv.bounds.width - 2 * PreviewCarouselGeometry.centeredHorizontalInset
        let stride = centeredWidth + PreviewCarouselGeometry.sideCardGap
        let edgePad = PreviewCarouselGeometry.centeredHorizontalInset

        // Determine which indices intersect `rect`. The rect is in
        // content-space, so we invert the cell layout: index =
        // (rect.x - edgePad) / stride.
        let minIndex = max(0, Int(floor((rect.minX - edgePad) / stride)) - 1)
        let maxIndex = min(itemCount - 1, Int(ceil((rect.maxX - edgePad) / stride)) + 1)
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
        let frame = cellFrame(for: indexPath.item)
        attrs.frame = frame

        // Compute distance from viewport center, normalized to one
        // stride. distanceUnits == 0 means centered; ±1 means
        // exactly one slot to the side.
        let viewportCenterX = cv.bounds.midX
        let cellCenterX = frame.midX
        let distancePx = cellCenterX - viewportCenterX
        let distanceUnits = distancePx / stride

        // Parallax: artwork translates against the scroll. When the
        // card is to the right of center (distanceUnits > 0), the
        // image inside should lean right (translation > 0), so
        // visually the image lags the moving card. Factor 0.30
        // matches the SwiftUI parallaxFactor of 0.70 (artwork moves
        // at 70% of card velocity → counter-translation is 30%).
        //
        // Multiplied by stride so the units are points, not units.
        attrs.parallaxOffsetX = distanceUnits * stride * 0.30

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
