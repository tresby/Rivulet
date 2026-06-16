//
//  AetherSubtitleCue.swift
//  Rivulet
//
//  Rivulet-side subtitle cue bridged from AetherEngine.SubtitleCue.
//
//  AetherEngine's SubtitleCue cannot be named inside the Rivulet module:
//  AetherEngine is both the module and a class, so `AetherEngine.SubtitleCue`
//  parses as a nested-type lookup on the class and fails, while the
//  unqualified `SubtitleCue` resolves to Rivulet's own text-only RPlayer cue
//  type. So AetherPlayer converts Aether's cues into this type at the engine
//  boundary (inside a closure where the element type is inferred). Unlike
//  Rivulet's `SubtitleCue`, this carries BOTH text and bitmap (PGS/DVB)
//  bodies, matching AetherEngine and preserving bitmap subtitle support.
//

import CoreGraphics

/// A subtitle cue ready for the Aether host overlay to paint.
struct AetherSubtitleCue: Identifiable {
    let id: Int
    let startTime: Double
    let endTime: Double
    let body: Body

    /// Text dialogue, or a positioned bitmap (PGS / DVB / DVD).
    enum Body {
        case text(String)
        /// `position` is the bitmap's origin+size in [0, 1] of the source
        /// video frame; the overlay multiplies by the on-screen video rect.
        case image(cgImage: CGImage, position: CGRect)
    }
}
