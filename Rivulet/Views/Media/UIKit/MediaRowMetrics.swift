//
//  MediaRowMetrics.swift
//  Rivulet
//
//  THE single source of tile + row metrics for every media shelf row:
//  home/library hub rows, the watchlist row, loading skeletons, and the
//  detail page's Related row. Layout sections AND cell-internal constraints
//  must read from here — the sizes drifting apart across copies is exactly
//  the bug class this file exists to kill.
//
//  2026-06-10: tiles bumped +10% over the original SwiftUI sizes to match
//  the ATV+ app, and the inter-row vertical chrome reduced by about the same
//  amount so rows sit closer (bigger posters eat the whitespace).
//

import UIKit

enum MediaRowMetrics {
    // MARK: The shelf equation (ATV+-style symmetric peek)
    //
    // Every horizontal shelf is sized so that, at any resting scroll position,
    // N tiles are fully visible with the tile before/after peeking in by the
    // SAME sliver on both screen edges, and scrolling one step lands tile k+1
    // exactly where tile k was. That holds on a full-bleed 1920pt canvas iff:
    //
    //     1920 = 2·rowLeading + N·tileWidth + (N − 1)·gap
    //     sliver each side = rowLeading − gap        (so keep gap < rowLeading)
    //
    // CW:      2·52 + 5·357 + 4·8 ≈ 1920   → 44pt sliver
    // Posters: 2·52 + 6·296 + 5·8 = 1920   → 44pt sliver
    //
    // The peek/sliver is rowLeading − gap, and the at-rest content margin IS
    // rowLeading — the two are NOT independent. A fatter peek needs a bigger
    // rowLeading (the peek can never exceed rowLeading, since the leftmost full
    // tile sits at rowLeading and the previous tile shows only the gap-sized
    // remainder before it). rowLeading is the app-wide content margin — the
    // hero, the expanded detail, and these shelves all share it (see
    // PreviewCarouselGeometry.expandedChromeInset), so changing it moves the
    // WHOLE app's left edge, not just the peek.
    //
    // Each shelf is a ShelfRowCell hosting its own horizontal collection with
    // isScrollEnabled = false; ShelfRowCell drives the offset to pitch
    // multiples itself (NOT the focus engine), so the landings are exact. If
    // you change any number here, keep the equation EXACT or the peeks go
    // lopsided.

    // MARK: Tiles

    /// 2:3 poster tile (PosterCell, WatchlistPosterCell, detail Related row).
    static let posterWidth: CGFloat = 296
    static let posterHeight: CGFloat = 444

    /// 1:1 square tile for music (artist/album/track). Same WIDTH as the
    /// poster, so the shelf equation (and the 6-across grid) is unchanged —
    /// only the height differs.
    static let musicWidth: CGFloat = posterWidth
    static let musicHeight: CGFloat = posterWidth

    /// Continue Watching landscape card (~1.29:1, the ATV+ CW card ratio).
    static let cwWidth: CGFloat = 357
    static let cwHeight: CGFloat = 277

    /// Fully-visible tile count per shelf type (the N in the equation).
    static let posterFullCount = 6
    static let cwFullCount = 5

    // MARK: Row chrome (vertical)

    /// Extra group height beneath tiles for the focus-scale growth.
    /// (Was 80 when tiles were smaller and carried a drop shadow.)
    static let focusGrowthPadding: CGFloat = 48

    /// Vertical insets around each row section. (Were 12 / 15.)
    static let rowTopInset: CGFloat = 8
    static let rowBottomInset: CGFloat = 8

    // MARK: Row chrome (horizontal)

    /// Leading + trailing inset rows and headers align to, measured from the
    /// PANEL edge (sections opt out of the safe-area reference). Kept EQUAL on
    /// purpose: the trailing inset makes the last snap position symmetric with
    /// the first. Hero content shares this margin (HeroOverlayView reads
    /// `rowLeading`) so its title/buttons align with row titles + first card.
    static let rowLeading: CGFloat = 52
    static let rowTrailing: CGFloat = 52

    /// Gap between tiles within a row. Must satisfy the equation above.
    static let posterGap: CGFloat = 8
    static let cwGap: CGFloat = 8
}

extension NSLayoutConstraint {
    /// Returns self with a non-required priority. Used on cell-internal
    /// constraints that meet TVUIKit's transient zero-width first layout pass
    /// (TVCardView lays its content host out at width 0 before contentSize
    /// applies) — at 999 Auto Layout compromises silently instead of spamming
    /// "Unable to simultaneously satisfy constraints" on every cell configure.
    func withPriority(_ rawValue: Float) -> NSLayoutConstraint {
        priority = UILayoutPriority(rawValue)
        return self
    }
}
