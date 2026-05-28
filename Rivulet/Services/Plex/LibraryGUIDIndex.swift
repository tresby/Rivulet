//
//  LibraryGUIDIndex.swift
//  Rivulet
//
//  In-memory index of library items keyed by external GUIDs (TMDB/IMDB/TVDB).
//  Used by Discover and Watchlist surfaces to answer "do I own this?" in O(1).
//

import Foundation

extension Notification.Name {
    /// Posted on the main thread after `LibraryGUIDIndex.shared.replace(with:)`
    /// completes. Views observing this can re-run library-match queries.
    static let libraryGUIDIndexDidUpdate = Notification.Name("LibraryGUIDIndexDidUpdate")
}

actor LibraryGUIDIndex {
    static let shared = LibraryGUIDIndex()

    private struct TypedKey: Hashable {
        let type: PlexItemType
        let key: String
    }

    enum PlexItemType: Hashable {
        case movie
        case show
    }

    private var byTypedTmdbId: [TypedKey: PlexMetadata] = [:]
    private var byGuid: [String: PlexMetadata] = [:]

    func replace(with items: [PlexMetadata]) {
        byTypedTmdbId.removeAll(keepingCapacity: true)
        byGuid.removeAll(keepingCapacity: true)

        for item in items {
            ingest(item)
        }

        let typedCount = byTypedTmdbId.count
        let guidCount = byGuid.count
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .libraryGUIDIndexDidUpdate,
                object: nil,
                userInfo: ["typedTmdbCount": typedCount, "guidCount": guidCount]
            )
        }
    }

    var isEmpty: Bool {
        byGuid.isEmpty
    }

    func lookup(tmdbId: Int, type: TMDBMediaType) -> PlexMetadata? {
        let plexType: PlexItemType = (type == .movie) ? .movie : .show
        return byTypedTmdbId[TypedKey(type: plexType, key: "\(tmdbId)")]
    }

    func lookup(guid: String) -> PlexMetadata? {
        byGuid[guid]
    }

    func contains(guid: String) -> Bool {
        byGuid[guid] != nil
    }

    // MARK: - Ingestion

    private func ingest(_ item: PlexMetadata) {
        let plexType: PlexItemType
        switch item.type {
        case "movie": plexType = .movie
        case "show": plexType = .show
        default: return
        }

        let externalGuids = (item.Guid ?? []).compactMap { $0.id }
        for raw in externalGuids {
            byGuid[raw] = item

            if let tmdbId = Self.tmdbId(from: raw) {
                byTypedTmdbId[TypedKey(type: plexType, key: "\(tmdbId)")] = item
            }
        }
    }

    private static func tmdbId(from guid: String) -> Int? {
        guard guid.hasPrefix("tmdb://") else { return nil }
        let raw = guid.dropFirst("tmdb://".count)
        return Int(raw)
    }
}
