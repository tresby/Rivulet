//
//  AetherSubtitleRenditionInfo.swift
//  Rivulet
//
//  Rivulet-side subtitle rendition descriptor bridged from
//  AetherEngine.SubtitleRendition.
//
//  AetherEngine's SubtitleRendition cannot be named inside the Rivulet module:
//  AetherEngine is both the module and a class, so `AetherEngine.SubtitleRendition`
//  parses as a nested-type lookup on the class and fails (same collision as
//  AetherEngine.SubtitleCue -- see AetherSubtitleCue.swift). AetherPlayer
//  converts each rendition into this type at the engine boundary (inside a
//  closure where the element type is inferred from the publisher). Hosts
//  match this against an AVMediaSelectionOption to recover the engine track
//  index to pass to engine.selectSubtitleTrack(index:).
//

/// A subtitle rendition advertised in the generated HLS master playlist
/// so AVKit's native picker lists it. Bridged from AetherEngine.SubtitleRendition.
struct AetherSubtitleRenditionInfo: Equatable {
    /// Path-safe identifier used in the master playlist ("sub<trackIndex>").
    let renditionID: String
    /// Display name shown in the AVKit picker.
    let name: String
    /// ISO language code (e.g. "en", "fr"); "und" when the source has none.
    let language: String
    /// The AetherEngine subtitle AVStream index this rendition represents.
    /// Pass directly to `AetherPlayer.selectSubtitleTrack(id:)`.
    let trackIndex: Int
}
