//
//  MediaItemDetail.swift
//  Rivulet
//
//  Superset returned from provider.fullDetail(for:). MediaDetailView gates
//  its below-fold on detail arrival. Embeds the list-level MediaItem so
//  detail consumers don't need both types passed in.
//

import Foundation

struct MediaItemDetail: Sendable {
    let item: MediaItem

    let tagline: String?
    let genres: [String]
    let studios: [String]
    let cast: [MediaPerson]
    let directors: [MediaPerson]
    let writers: [MediaPerson]
    let chapters: [MediaChapter]
    let mediaSources: [MediaSource]
    let trailerURL: URL?
    let contentRating: String?
    var regionOfOrigin: String? = nil   // e.g. "United Kingdom" (Plex Country), if present
    let rating: Double?              // normalized 0–10

    // Wave 1 additions for the detail view
    let nextEpisode: MediaItem?      // shows only — Plex `OnDeck`, Jellyfin `/Shows/NextUp`
    let collections: [String]        // collection names this item is tagged with

    /// Trailers + extras (behind-the-scenes, featurettes, …). Provider-agnostic.
    /// Defaulted so existing constructors that don't supply it still compile.
    /// `playbackKey` is the provider's handle for playing the extra later.
    var extras: [Extra] = []

    /// Content advisory (Common Sense Media on Plex). Holds the local partial
    /// (age rating) first; replaced by the full Discover data when it arrives.
    /// Defaulted so existing constructors compile unchanged.
    var contentAdvisory: ContentAdvisory? = nil

    struct Extra: Sendable, Identifiable, Hashable {
        let id: String
        let title: String
        let thumbnailURL: URL?
        let duration: TimeInterval?   // seconds
        let playbackKey: String?      // provider-specific (Plex extra key / ratingKey)
        var isTrailer: Bool = false   // trailer vs other extra (behind the scenes, etc.)
    }
}
