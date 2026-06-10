//
//  PlexWatchlistItem.swift
//  Rivulet
//
//  Lightweight display model for items on a user's Plex Watchlist.
//

import Foundation

nonisolated struct PlexWatchlistItem: Identifiable, Hashable, Codable, Sendable {
    nonisolated enum WatchlistType: String, Codable, Sendable {
        case movie
        case show
    }

    let id: String          // Plex discover ratingKey or first GUID
    let title: String
    let year: Int?
    let type: WatchlistType
    let posterURL: URL?
    let guids: [String]     // tmdb://, imdb://, tvdb://

    var primaryGUID: String? { guids.first }

    var tmdbId: Int? {
        for g in guids where g.hasPrefix("tmdb://") {
            if let id = Int(g.dropFirst("tmdb://".count)) { return id }
        }
        return nil
    }
}
