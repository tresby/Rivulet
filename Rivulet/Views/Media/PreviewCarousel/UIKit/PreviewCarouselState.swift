//
//  PreviewCarouselState.swift
//  Rivulet
//
//  Geometry constants and lightweight types for the UIKit preview
//  carousel. Mirrors the SwiftUI `PreviewOverlayHost` constants verbatim
//  (see perf-spike/DETAIL_AUDIT.md section 2.1).
//

import UIKit

/// Constants that govern the 3-slot preview carousel layout.
///
/// Numbers were copied verbatim from the SwiftUI source so the UIKit
/// host renders pixel-identical card frames during paging. Do not
/// change without re-grounding against the audit doc.
enum PreviewCarouselGeometry {
    /// Distance from the top of the screen to the top edge of each
    /// card. SwiftUI uses 52pt; matches the inset on every card slot.
    static let topInset: CGFloat = 52

    /// Card corner radius. Applied to the center slot, the side
    /// peeks, and the expanded hero (which lerps to 0 as it grows
    /// into the fullscreen detail surface).
    static let cornerRadius: CGFloat = 28

    /// Horizontal inset used to compute the centered card's frame.
    /// `centeredFrame.width = screenWidth - 2 * centeredHorizontalInset`.
    static let centeredHorizontalInset: CGFloat = 88

    /// Gap between the centered card and either side peek.
    static let sideCardGap: CGFloat = 14

    /// Multiplier applied to a side peek's inner image translation so
    /// the artwork parallaxes as the user pages.
    static let carouselParallaxFactor: CGFloat = 0.70
}

/// Selected slot of the 3-slot host. Used by
/// `PreviewCarouselViewController` for paging and slot recycling.
enum PreviewCarouselSlot: Int {
    case left = -1
    case center = 0
    case right = 1
}

/// Computes the carousel frame for a card at a given offset from the
/// selected index (always 0 for the center card; ±1 for the peeks).
///
/// Mirrors `PreviewOverlayHost.carouselFrame(for:)` from the SwiftUI
/// source. Z-order is set separately by the host.
func previewCarouselFrame(
    slot: PreviewCarouselSlot,
    in bounds: CGRect
) -> CGRect {
    let geom = PreviewCarouselGeometry.self
    let centeredWidth = bounds.width - 2 * geom.centeredHorizontalInset
    let centeredHeight = bounds.height - geom.topInset

    let centered = CGRect(
        x: geom.centeredHorizontalInset,
        y: geom.topInset,
        width: centeredWidth,
        height: centeredHeight
    )

    switch slot {
    case .center:
        return centered
    case .left:
        // Peek to the left. Width stays the same; x slides off the
        // leading edge by `centeredWidth + sideCardGap`.
        return centered.offsetBy(dx: -(centeredWidth + geom.sideCardGap), dy: 0)
    case .right:
        return centered.offsetBy(dx: centeredWidth + geom.sideCardGap, dy: 0)
    }
}
