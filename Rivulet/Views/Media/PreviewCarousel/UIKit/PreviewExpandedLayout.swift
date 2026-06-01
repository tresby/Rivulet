//
//  PreviewExpandedLayout.swift
//  Rivulet
//
//  The expanded-detail layout for the preview carousel. The cell at
//  `expandedIndex` gets the full collection-view bounds (translated by
//  contentOffset so it sits at viewport origin); every other cell keeps
//  its normal carousel frame with alpha 0 (still laid out so a collapse
//  transition back to PreviewCarouselLayout reverses cleanly).
//
//  This is the former `isExpanded` short-circuit from
//  PreviewCarouselLayout, extracted so `setCollectionViewLayout(_:animated:)`
//  can interpolate between two concrete layouts (carousel <-> expanded)
//  instead of one layout mutating a bool. See
//  docs/superpowers/specs/2026-05-31-two-layout-carousel-morph-design.md
//  and perf-spike/UIKIT_FOUNDATIONS.md §1.
//

import UIKit

final class PreviewExpandedLayout: UICollectionViewLayout {
    /// Number of items. Set by the controller before `prepare()`.
    var itemCount: Int = 0

    /// The cell index that occupies the fullscreen frame.
    var expandedIndex: Int = 0

    override class var layoutAttributesClass: AnyClass {
        return PreviewCardLayoutAttributes.self
    }

    override var collectionViewContentSize: CGSize {
        // Same content size as the carousel layout so contentOffset is
        // preserved across the layout swap (the expanded cell is placed
        // relative to the live contentOffset).
        guard let cv = collectionView, itemCount > 0 else { return .zero }
        let centeredWidth = cv.bounds.width - 2 * PreviewCarouselGeometry.centeredHorizontalInset
        let stride = centeredWidth + PreviewCarouselGeometry.sideCardGap
        let totalCardSpan = stride * CGFloat(itemCount) - PreviewCarouselGeometry.sideCardGap
        let edgePad = PreviewCarouselGeometry.centeredHorizontalInset
        return CGSize(width: totalCardSpan + 2 * edgePad, height: cv.bounds.height)
    }

    private func carouselCellFrame(for index: Int) -> CGRect {
        guard let cv = collectionView else { return .zero }
        let centeredWidth = cv.bounds.width - 2 * PreviewCarouselGeometry.centeredHorizontalInset
        let cardHeight = cv.bounds.height - PreviewCarouselGeometry.topInset
        let stride = centeredWidth + PreviewCarouselGeometry.sideCardGap
        let edgePad = PreviewCarouselGeometry.centeredHorizontalInset
        let x = edgePad + stride * CGFloat(index)
        return CGRect(x: x, y: PreviewCarouselGeometry.topInset, width: centeredWidth, height: cardHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard itemCount > 0 else { return nil }
        var result: [UICollectionViewLayoutAttributes] = []
        for i in 0..<itemCount {
            if let attrs = layoutAttributesForItem(at: IndexPath(item: i, section: 0)) {
                result.append(attrs)
            }
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let cv = collectionView else { return nil }
        let attrs = PreviewCardLayoutAttributes(forCellWith: indexPath)

        if indexPath.item == expandedIndex {
            let originX = cv.contentOffset.x
            attrs.frame = CGRect(x: originX, y: 0, width: cv.bounds.width, height: cv.bounds.height)
            attrs.stageSize = cv.bounds.size
            attrs.parallaxOffsetX = 0
            attrs.alpha = 1
            attrs.zIndex = 100
            return attrs
        }

        attrs.frame = carouselCellFrame(for: indexPath.item)
        attrs.stageSize = cv.bounds.size
        attrs.alpha = 0
        attrs.zIndex = 0
        return attrs
    }
}
