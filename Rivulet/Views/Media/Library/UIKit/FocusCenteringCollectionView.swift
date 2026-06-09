//
//  FocusCenteringCollectionView.swift
//  Rivulet
//
//  Drives its own vertical focus-scroll: `isScrollEnabled = false` so the focus
//  engine's auto-scroll can't race us, and on each focus change we centre the
//  focused row via a CADisplayLink (shared `FocusScrollMotion` curve/duration).
//  Cells inside orthogonal (continuous) sections do NOT resolve to
//  `context.nextFocusedIndexPath` (nil), so we drive off `context.nextFocusedView`
//  and walk to its enclosing cell. Horizontal moves within a shelf are handled by
//  the section's own inner orthogonal scroller.
//
//  This is the generalised, always-centre variant of FocusScrollControlledCollectionView.
//  It has no topBand/topSection pinning — every focused row centres, clamped to the
//  collection's valid offset range.
//

import UIKit

/// Drives its own vertical focus-scroll: `isScrollEnabled = false` so the focus
/// engine's auto-scroll can't race us, and on each focus change we centre the
/// focused row via a CADisplayLink (shared `FocusScrollMotion` curve/duration).
/// Cells inside orthogonal (continuous) sections do NOT resolve to
/// `context.nextFocusedIndexPath` (nil), so we drive off `context.nextFocusedView`
/// and walk to its enclosing cell. Horizontal moves within a shelf are handled by
/// the section's own inner orthogonal scroller.
final class FocusCenteringCollectionView: UICollectionView {
    var onFocusedIndexPath: ((IndexPath?) -> Void)?

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let nextView = context.nextFocusedView,
              nextView.isDescendant(of: self),
              let cell = enclosingCell(of: nextView) else { return }
        onFocusedIndexPath?(indexPath(for: cell))
        let frame = cell.convert(cell.bounds, to: self)
        let minY = -adjustedContentInset.top
        let maxY = max(minY, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let targetY = frame.midY - bounds.height / 2
        animateOffset(to: max(minY, min(targetY, maxY)))
    }

    private func enclosingCell(of view: UIView) -> UICollectionViewCell? {
        var v: UIView? = view
        while let cur = v { if let c = cur as? UICollectionViewCell { return c }; if cur === self { return nil }; v = cur.superview }
        return nil
    }

    // Per-frame offset driver (mirrors the proven loop from FocusScrollControlledCollectionView).
    private var link: CADisplayLink?
    private var startY: CGFloat = 0, targetY: CGFloat = 0, startTime: CFTimeInterval = 0
    private func animateOffset(to y: CGFloat) {
        link?.invalidate()
        if abs(y - contentOffset.y) < 0.5 { contentOffset = CGPoint(x: 0, y: y); link = nil; return }
        startY = contentOffset.y; targetY = y; startTime = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(step)); l.add(to: .main, forMode: .common); link = l
    }
    @objc private func step(_ l: CADisplayLink) {
        let d = FocusScrollMotion.settleDuration
        let t = d > 0 ? min(1, (CACurrentMediaTime() - startTime) / d) : 1
        contentOffset = CGPoint(x: 0, y: startY + (targetY - startY) * CGFloat(FocusScrollMotion.ease(t)))
        if t >= 1 { l.invalidate(); link = nil; contentOffset = CGPoint(x: 0, y: targetY) }
    }
}
