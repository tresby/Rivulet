//
//  FocusScrollControlledCollectionView.swift
//  Rivulet
//
//  The default focus engine CENTERS the focused cell but races/drifts as it does
//  it. So we take over the vertical focus-scroll: the collection's
//  `isScrollEnabled = false` stops the engine's own focus-scroll animator (and
//  the offset drift when focus moves to external views like the season pills),
//  and on each focus change we drive the offset ourselves.
//
//  Scroll model (matches the home screen / the ATV+ detail refs):
//   - The TOP section (episodes, section 0) pins under the fixed logo + season
//     pills at `topBand` — that landing is also the hero-fade rest position.
//   - Every other focused row CENTERS vertically. The clamp to [minY, maxY]
//     makes the very top/bottom rows sit naturally (above/below center) rather
//     than centering — exactly the "centered except the top and bottom ones"
//     behavior. (Centering needs LESS scroll than top-pinning, so the lower
//     rows actually come into view instead of running off the bottom.)
//
//  Horizontal navigation within an orthogonal row is unaffected — that's the
//  section's own inner orthogonal scroller.
//

import UIKit

final class FocusScrollControlledCollectionView: UICollectionView {
    /// Screen-y the TOP section's row top is pinned to (under the logo + pills).
    var topBand: CGFloat = 230
    /// Duration of the controlled vertical scroll. Defaults to the shared
    /// `FocusScrollMotion.settleDuration` so the home and detail surfaces stay
    /// in sync; still overridable per instance.
    var scrollDuration: TimeInterval = FocusScrollMotion.settleDuration
    /// Fires on every focus change — the newly-focused index path, or nil when
    /// focus leaves the collection. Used to track which episode/season is current.
    var onFocusedIndexPath: ((IndexPath?) -> Void)?

    /// Whether focus is currently on the TOP section (the episodes row). The Up
    /// handler uses this to decide: from the episodes, Up goes to the season
    /// pills; from a LOWER section, Up must fall through to the focus engine so it
    /// moves up one row (rather than jumping straight to the pills).
    private(set) var focusedCellIsTopSection = false {
        didSet { if focusedCellIsTopSection && !oldValue { lastTopFocusTime = CACurrentMediaTime() } }
    }
    private var lastTopFocusTime: CFTimeInterval = 0
    /// True for a brief window after focus first lands on the episodes row. The
    /// focus engine moves a lower row → episode ~4ms BEFORE pressesBegan fires on
    /// the same Up press, so without this the Up handler would see "on episodes"
    /// and immediately jump to the pills (the "sometimes falls through to pills"
    /// bug). A later, deliberate Up (outside the window) does go to the pills.
    var topSectionJustTookFocus: Bool { CACurrentMediaTime() - lastTopFocusTime < 0.06 }

    /// Section index of the episodes row (the "top section"). Set by the owner
    /// after each snapshot. Keying off the SECTION (not the cell class) matters
    /// because trailers now reuse `EpisodeCollectionCell` too — a class check
    /// would mis-tag a focused trailer as "on episodes" and send Up to the pills.
    var topSectionIndex: Int?

    /// True while the focused view is an episode DESCRIPTION (vs a thumb). When
    /// true, every episode description becomes focusable so Left/Right moves
    /// between adjacent descriptions; when false they stay gated so Up coming up
    /// from a lower row skips them and lands on the thumb. Computed from the
    /// authoritative focused view (no per-cell race).
    private(set) var focusedViewIsEpisodeDescription = false
    /// Index path of the focused episode cell (top section), or nil. Used to
    /// redirect Left/Right from a description to the adjacent episode's thumb.
    private(set) var focusedEpisodeIndexPath: IndexPath?

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let ctx = context as? UICollectionViewFocusUpdateContext
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusedIndexPath?(ctx?.nextFocusedIndexPath)
        focusedViewIsEpisodeDescription = context.nextFocusedView is EpisodeDescriptionView

        // Drive the vertical scroll off the focused VIEW, not the index path:
        // cells inside orthogonal compositional sections don't resolve to a
        // nextFocusedIndexPath at the collection level (it comes back nil), but
        // context.nextFocusedView is always the real focused view. Walk up to its
        // enclosing cell and center it (the top section pins under the logo).
        guard let nextView = context.nextFocusedView,
              nextView.isDescendant(of: self),
              let cell = enclosingCell(of: nextView) else {
            focusedCellIsTopSection = false   // focus left the collection (pills/hero)
            focusedEpisodeIndexPath = nil
            return
        }
        let frame = cell.convert(cell.bounds, to: self)   // content coordinates
        let minY = -adjustedContentInset.top
        let maxY = max(minY, contentSize.height - bounds.height + adjustedContentInset.bottom)
        // Top section = the EPISODES section, by index. (Not `cell is
        // EpisodeCollectionCell` — trailers reuse that same cell class.)
        let cellIndexPath = indexPath(for: cell)
        let isTop = topSectionIndex != nil && cellIndexPath?.section == topSectionIndex
        focusedCellIsTopSection = isTop
        focusedEpisodeIndexPath = isTop ? cellIndexPath : nil
        let targetY = isTop ? (frame.minY - topBand) : (frame.midY - bounds.height / 2)
        let clamped = max(minY, min(targetY, maxY))
        animateOffset(to: clamped)
    }

    // MARK: - Per-frame scroll driver

    // `UIView.animate { contentOffset = }` only animates the PRESENTATION layer —
    // the model offset jumps to the target immediately, so the collection recycles
    // cells based on the final offset and a row that ends up off-screen has its
    // cells removed at once (the "row pops before it scrolls out" jank). A
    // CADisplayLink advancing the real contentOffset per frame recycles cells
    // progressively, so rows slide out smoothly.
    private var scrollLink: CADisplayLink?
    private var scrollStartY: CGFloat = 0
    private var scrollTargetY: CGFloat = 0
    private var scrollStartTime: CFTimeInterval = 0

    private func animateOffset(to targetY: CGFloat) {
        scrollLink?.invalidate()
        if abs(targetY - contentOffset.y) < 0.5 {
            contentOffset = CGPoint(x: 0, y: targetY)
            scrollLink = nil
            return
        }
        scrollStartY = contentOffset.y          // continue from the current position
        scrollTargetY = targetY
        scrollStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepScroll))
        link.add(to: .main, forMode: .common)
        scrollLink = link
    }

    @objc private func stepScroll(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - scrollStartTime
        let t = scrollDuration > 0 ? min(1, elapsed / scrollDuration) : 1
        let e = FocusScrollMotion.ease(t)   // shared focus-scroll curve (cubic ease-out)
        contentOffset = CGPoint(x: 0, y: scrollStartY + (scrollTargetY - scrollStartY) * CGFloat(e))
        if t >= 1 {
            link.invalidate()
            scrollLink = nil
            contentOffset = CGPoint(x: 0, y: scrollTargetY)
        }
    }

    /// Walk up from a focused view to its enclosing collection-view cell (or nil
    /// if the focus left the collection entirely).
    private func enclosingCell(of view: UIView) -> UICollectionViewCell? {
        var v: UIView? = view
        while let cur = v {
            if let cell = cur as? UICollectionViewCell { return cell }
            if cur === self { return nil }
            v = cur.superview
        }
        return nil
    }
}
