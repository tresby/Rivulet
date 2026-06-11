//
//  PinnableCollectionView.swift
//  Rivulet
//
//  A UICollectionView that can PIN its horizontal contentOffset to a fixed
//  value. The expand morph swaps layouts via `setCollectionViewLayout`, which
//  asynchronously zeroes contentOffset (even with isScrollEnabled=false, and
//  `targetContentOffset(forProposedContentOffset:)` is NOT consulted on that
//  path). The expanded cell is placed at content x = contentOffset.x, so a
//  zeroed offset throws the cell — and its metadata chrome — off the right edge
//  for any non-first item, and destabilises the morph (the "metadata wrong
//  location / janky on non-first items" bug). The zeroing is deferred and
//  recurring, so a one-shot restore can't win.
//
//  Pinning intercepts EVERY offset write, so the carousel stays centered on the
//  expanded index through the whole morph + expanded state. The pin is set when
//  expand begins and cleared when collapse completes, so manual paging in
//  carousel-stable is unaffected.
//

import UIKit

final class PinnableCollectionView: UICollectionView {
    /// When non-nil, the horizontal contentOffset is forced to this value on
    /// every write. nil = normal (paging) behavior.
    var pinnedOffsetX: CGFloat? {
        didSet {
            guard let x = pinnedOffsetX, super.contentOffset.x != x else { return }
            super.contentOffset = CGPoint(x: x, y: super.contentOffset.y)
        }
    }

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            if let x = pinnedOffsetX {
                super.contentOffset = CGPoint(x: x, y: newValue.y)
            } else {
                super.contentOffset = newValue
            }
        }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if let x = pinnedOffsetX {
            super.setContentOffset(CGPoint(x: x, y: contentOffset.y), animated: false)
        } else {
            super.setContentOffset(contentOffset, animated: animated)
        }
    }
}
