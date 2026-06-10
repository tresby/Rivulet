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
    // MARK: Tiles

    /// 2:3 poster tile (PosterCell, WatchlistPosterCell, detail Related row).
    static let posterWidth: CGFloat = 286    // was 260
    static let posterHeight: CGFloat = 429   // was 390

    /// Continue Watching landscape card (~1.29:1).
    static let cwWidth: CGFloat = 396        // was 360
    static let cwHeight: CGFloat = 308       // was 280

    // MARK: Row chrome (vertical)

    /// Extra group height beneath tiles for the focus-scale growth.
    /// (Was 80 when tiles were smaller and carried a drop shadow.)
    static let focusGrowthPadding: CGFloat = 48

    /// Vertical insets around each row section. (Were 12 / 15.)
    static let rowTopInset: CGFloat = 8
    static let rowBottomInset: CGFloat = 8

    // MARK: Row chrome (horizontal)

    /// Leading edge rows + headers align to; trailing inset.
    static let rowLeading: CGFloat = 32
    static let rowTrailing: CGFloat = 48

    /// Gap between tiles within a row.
    static let posterGap: CGFloat = 30
    static let cwGap: CGFloat = 16
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
