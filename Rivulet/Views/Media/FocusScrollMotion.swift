//
//  FocusScrollMotion.swift
//  Rivulet
//
//  Shared timing AND easing for the focus-driven vertical re-center scroll used
//  across the UIKit media surfaces (the home rows, and the expanded-detail
//  below-fold collections). When focus moves between rows we take over the
//  vertical scroll, because the focus engine runs its own focus-scroll animator
//  that races a per-frame CADisplayLink driver. This is how long that driven
//  settle takes and how it eases.
//
//  Centralised so the home and detail focus-scroll ride one knob and can't
//  drift apart on duration OR curve.
//
//  Scope is ONLY the focus-scroll re-center. Keep unrelated timings out of
//  here, e.g. the carousel expand morph
//  (PreviewCarouselState.expandAnimationDuration), the backdrop crossfade, and
//  the detail enter/exit slide (BelowFoldCollectionView.slideToDetailsTop /
//  slideToHeroRest), which is its own one-shot transition.
//

import Foundation

enum FocusScrollMotion {
    /// Default duration, in seconds, of the driven vertical focus-scroll settle.
    static let settleDuration: CFTimeInterval = 0.6

    /// Eased progress for the focus-scroll settle. Cubic ease-out: fast start,
    /// decelerating to a gentle stop. `t` is linear progress in 0...1.
    static func ease(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }
}
