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

/// Slot positions for the 5-slot host. Cards live at these positions
/// in screen space. Paging shifts the *content mapping* (which item
/// each card displays), not the card identities or positions.
///
/// The two `offscreen*` slots are off-screen and serve two purposes:
///   1. They give us pre-rendered cards waiting in the wings, so the
///      first frame of a paging animation already has the right
///      artwork showing instead of asynchronously loading.
///   2. They give the cards a clean target to slide into / out of
///      without ever swapping content mid-animation.
enum PreviewCarouselSlot: Int, CaseIterable {
    case offscreenLeft = -2
    case leftPeek = -1
    case center = 0
    case rightPeek = 1
    case offscreenRight = 2
}

/// Computes the carousel frame for a card at the given slot.
///
/// Mirrors `PreviewOverlayHost.carouselFrame(for:)` from the SwiftUI
/// source for the three visible slots, and extends symmetrically for
/// the two off-screen slots.
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

    // Each step is one full card width plus the inter-card gap.
    let stride = centeredWidth + geom.sideCardGap
    return centered.offsetBy(dx: stride * CGFloat(slot.rawValue), dy: 0)
}
