//
//  PlexHubCacheSlim.swift
//  Rivulet
//
//  Slim decode types for the hub/list CACHE. Decoding the full PlexMetadata
//  (65 fields) is catastrophically slow — a device probe measured 4ms to
//  decode a 3-field projection of the same 330KB bytes vs ~6500ms for the
//  full struct. The cost is SUPER-LINEAR in field count (the well-known Swift
//  large-`Codable` quadratic), so stripping nested arrays alone wasn't enough.
//
//  These types decode ONLY the ~25 fields the home shelves render, keyed
//  identically to PlexMetadata so they decode from ANY cached hub file (old
//  fat caches included — extra keys are ignored). The full PlexMetadata is
//  fetched on demand at detail/playback. `toMetadata()` rehydrates a
//  PlexMetadata (scalar fields + clearLogo image) for the existing row code.
//

import Foundation

nonisolated struct SlimCachedHub: Decodable {
    var key: String?
    var title: String?
    var type: String?
    var hubIdentifier: String?
    var size: Int?
    var more: Bool?
    var hubKey: String?
    var Metadata: [SlimCachedItem]?

    func toHub() -> PlexHub {
        PlexHub(
            hubIdentifier: hubIdentifier,
            title: title,
            type: type,
            hubKey: hubKey,
            key: key,
            more: more,
            size: size,
            Metadata: Metadata?.map { $0.toMetadata() }
        )
    }
}

nonisolated struct SlimCachedItem: Decodable {
    var ratingKey: String?
    var key: String?
    var guid: String?
    var type: String?
    var title: String?
    var summary: String?
    var contentRating: String?
    var year: Int?
    var originallyAvailableAt: String?
    var thumb: String?
    var art: String?
    var duration: Int?
    var index: Int?
    var addedAt: Int?
    var parentRatingKey: String?
    var parentTitle: String?
    var parentThumb: String?
    var parentIndex: Int?
    var grandparentRatingKey: String?
    var grandparentTitle: String?
    var grandparentThumb: String?
    var grandparentArt: String?
    var leafCount: Int?
    var viewedLeafCount: Int?
    var viewCount: Int?
    var viewOffset: Int?
    var lastViewedAt: Int?
    var userRating: Double?
    /// Kept so Continue Watching / hero clearLogo still resolves (clearLogoPath
    /// reads the Image array). Small (a handful of entries).
    var Image: [PlexImage]?

    func toMetadata() -> PlexMetadata {
        var m = PlexMetadata(
            ratingKey: ratingKey,
            key: key,
            guid: guid,
            type: type,
            title: title,
            contentRating: contentRating,
            summary: summary,
            year: year,
            thumb: thumb,
            art: art,
            duration: duration,
            originallyAvailableAt: originallyAvailableAt,
            addedAt: addedAt,
            parentRatingKey: parentRatingKey,
            parentTitle: parentTitle,
            parentIndex: parentIndex,
            parentThumb: parentThumb,
            grandparentRatingKey: grandparentRatingKey,
            grandparentTitle: grandparentTitle,
            grandparentThumb: grandparentThumb,
            grandparentArt: grandparentArt,
            index: index,
            leafCount: leafCount,
            viewedLeafCount: viewedLeafCount,
            viewCount: viewCount,
            viewOffset: viewOffset,
            lastViewedAt: lastViewedAt,
            userRating: userRating
        )
        m.Image = Image
        return m
    }
}
