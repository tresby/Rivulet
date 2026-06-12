//
//  PlexProvider.swift
//  Rivulet
//
//  Plex implementation of MediaProvider. Wraps PlexNetworkManager and the
//  existing Plex* singletons; maps PlexMetadata -> agnostic types via
//  PlexMediaMapper at every boundary.
//

import Foundation

final class PlexProvider: MediaProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .plex
    nonisolated let displayName: String
    private(set) var connectionState: ConnectionState = .connected

    let serverURL: String
    let authToken: String
    let networkManager: PlexNetworkManager
    let dataStore: PlexDataStore
    let watchlistAPI: PlexWatchlistAPI

    init(
        machineIdentifier: String,
        displayName: String,
        serverURL: String,
        authToken: String,
        networkManager: PlexNetworkManager = .shared,
        dataStore: PlexDataStore = .shared,
        watchlistAPI: PlexWatchlistAPI = PlexWatchlistAPI()
    ) {
        self.id = "plex:\(machineIdentifier)"
        self.displayName = displayName
        self.serverURL = serverURL
        self.authToken = authToken
        self.networkManager = networkManager
        self.dataStore = dataStore
        self.watchlistAPI = watchlistAPI
    }

    // MARK: - Browse

    func libraries() async throws -> [MediaLibrary] {
        try await plexCall {
            let plexLibs = try await networkManager.getLibraries(
                serverURL: serverURL, authToken: authToken
            )
            return plexLibs.map { PlexMediaMapper.library($0, providerID: id) }
        }
    }

    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        try await plexCall {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL, authToken: authToken,
                sectionId: library.id,
                start: page.offset,
                size: page.limit,
                sort: plexSortString(for: sort)
            )
            let mapped = result.items.map {
                PlexMediaMapper.item($0, providerID: id, serverURL: serverURL, authToken: authToken)
            }
            let total = result.totalSize ?? mapped.count
            let next: Page? = (page.offset + page.limit < total)
                ? Page(offset: page.offset + page.limit, limit: page.limit) : nil
            return PagedResult(items: mapped, total: total, nextPage: next)
        }
    }

    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] {
        try await plexCall {
            let kids = try await networkManager.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
            return kids.map {
                PlexMediaMapper.item($0, providerID: id, serverURL: serverURL, authToken: authToken)
            }
        }
    }

    func search(_ query: String) async throws -> [MediaItem] {
        // PlexNetworkManager doesn't expose a dedicated search method as of Wave 1.
        // Plex search routes through /hubs/search via custom request shapes;
        // wiring it here without a network-layer helper would duplicate that
        // logic. Throwing rather than returning empty so callers can
        // distinguish "search not implemented" from "no results."
        // Post-Wave-1 task adds a search method to PlexNetworkManager and
        // wires it through.
        throw MediaProviderError.backendSpecific(
            underlying: "Plex search not implemented in Wave 1"
        )
    }

    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        try await plexCall {
            let meta = try await networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
            return PlexMediaMapper.detail(
                meta, providerID: id,
                serverURL: serverURL, authToken: authToken
            )
        }
    }

    func contentAdvisory(for ref: MediaItemRef) async throws -> ContentAdvisory? {
        // The item carries no external guid in the agnostic model, so fetch the
        // metadata (which has Guid + type + the LOCAL partial CSM), then resolve
        // the full advisory from Plex Discover. Fall back to the local partial.
        var meta = try await networkManager.getFullMetadata(
            serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
        )
        // Common Sense Media is SHOW-level: episodes/seasons carry none and often
        // lack the show's external guids. Resolve to the parent show.
        if let showKey = (meta.type == "episode" ? meta.grandparentRatingKey
                          : (meta.type == "season" ? meta.parentRatingKey : nil)) {
            meta = try await networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: showKey)
        }
        let localPartial = meta.CommonSenseMedia?.first.map(PlexMediaMapper.contentAdvisory(from:))
        let guids = (meta.Guid ?? []).compactMap { $0.id }
        guard let guid = guids.first(where: { $0.hasPrefix("tmdb://") })
            ?? guids.first(where: { $0.hasPrefix("imdb://") })
            ?? guids.first else { return localPartial }
        let full = await PlexContentAdvisoryService()
            .advisory(forGuid: guid, isMovie: meta.type == "movie", accountToken: authToken)
        return full ?? localPartial
    }

    func collectionItems(matching collectionName: String, in library: MediaLibrary) async throws -> [MediaItem] {
        // PlexNetworkManager.getCollectionItems takes sectionId + collectionId;
        // the existing detail view's Collection footer is populated indirectly
        // by Plex embedding collection items in the show/movie's metadata
        // response. Resolving collectionName -> collectionId in a clean async
        // call requires a network helper that doesn't exist yet — out of
        // scope for Wave 1.
        //
        // TODO(post-wave-1): add /library/sections/{id}/collections?title= query
        // helper to PlexNetworkManager and wire it through here.
        return []
    }

    func relatedItems(for itemRef: MediaItemRef) async throws -> [MediaItem] {
        try await plexCall {
            let related = try await networkManager.getRelatedItems(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
            return related.map {
                PlexMediaMapper.item($0, providerID: id,
                                    serverURL: serverURL, authToken: authToken)
            }
        }
    }

    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] {
        try await plexCall {
            let episodes = try await networkManager.getAllLeaves(
                serverURL: serverURL, authToken: authToken, ratingKey: showRef.itemID
            )
            return episodes.map {
                PlexMediaMapper.item($0, providerID: id,
                                    serverURL: serverURL, authToken: authToken)
            }
        }
    }

    // MARK: - Home rails

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await plexCall {
            // getContinueWatching returns a single PlexHub? whose Metadata is the items.
            let hub = try await networkManager.getContinueWatching(
                serverURL: serverURL, authToken: authToken, count: limit
            )
            let metadata = hub?.Metadata ?? []
            return metadata.map {
                PlexMediaMapper.item($0, providerID: id,
                                    serverURL: serverURL, authToken: authToken)
            }
        }
    }

    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        try await plexCall {
            let items = try await networkManager.getRecentlyAdded(
                serverURL: serverURL, authToken: authToken, limit: limit
            )
            return items.map {
                PlexMediaMapper.item($0, providerID: id,
                                    serverURL: serverURL, authToken: authToken)
            }
        }
    }

    /// Plex-native curated hubs. HomeComposer calls this via type-check;
    /// other providers compose hubs from primitives.
    func hubs() async throws -> [MediaHub] {
        try await plexCall {
            let plexHubs = try await networkManager.getHubs(
                serverURL: serverURL, authToken: authToken
            )
            return plexHubs.map {
                PlexMediaMapper.hub($0, providerID: id,
                                   serverURL: serverURL, authToken: authToken)
            }
        }
    }

    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        try await plexCall {
            let plexHubs = try await networkManager.getLibraryHubs(
                serverURL: serverURL, authToken: authToken, sectionId: library.id
            )
            return plexHubs.map {
                PlexMediaMapper.hub($0, providerID: id,
                                   serverURL: serverURL, authToken: authToken)
            }
        }
    }

    // MARK: - Playback

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?) async throws -> StreamInfo {
        let detail = try await fullDetail(for: itemRef)
        let chosen: MediaSource
        if let sourceID, let match = detail.mediaSources.first(where: { $0.id == sourceID }) {
            chosen = match
        } else if let first = detail.mediaSources.first {
            chosen = first
        } else {
            throw MediaProviderError.notFound
        }
        return StreamInfo(source: chosen, playSessionID: nil, trackInfoAvailable: true)
    }

    func progressReporter(for itemRef: MediaItemRef, playSessionID: String?) -> any ProgressReporter {
        PlexTimelineReporter(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: itemRef.itemID,
            networkManager: networkManager
        )
    }

    // MARK: - Per-item track selection

    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {
        guard let streamID = Int(trackID) else {
            throw MediaProviderError.backendSpecific(underlying: "audio trackID must be numeric for Plex (got \(trackID))")
        }
        let partID = try await resolvePartID(sourceID: sourceID, ratingKey: itemRef.itemID)
        await networkManager.setSelectedAudioStream(
            serverURL: serverURL,
            authToken: authToken,
            partId: partID,
            audioStreamID: streamID
        )
    }

    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {
        // `nil` means "off"; Plex encodes that as 0.
        let streamID: Int
        if let trackID {
            guard let parsed = Int(trackID) else {
                throw MediaProviderError.backendSpecific(underlying: "subtitle trackID must be numeric for Plex (got \(trackID))")
            }
            streamID = parsed
        } else {
            streamID = 0
        }
        let partID = try await resolvePartID(sourceID: sourceID, ratingKey: itemRef.itemID)
        await networkManager.setSelectedSubtitleStream(
            serverURL: serverURL,
            authToken: authToken,
            partId: partID,
            subtitleStreamID: streamID
        )
    }

    /// Plex's per-user-per-part PUT endpoint takes the Plex `Part.id`, but our
    /// agnostic `MediaSource.id` carries `Media.id`. Round-trip the ratingKey
    /// to the network manager so we can pick the matching Media + first Part.
    private func resolvePartID(sourceID: String, ratingKey: String) async throws -> Int {
        let metadata = try await plexCall {
            try await networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: ratingKey
            )
        }
        let media: PlexMedia? = {
            if let id = Int(sourceID), let match = metadata.Media?.first(where: { $0.id == id }) {
                return match
            }
            return metadata.Media?.first
        }()
        guard let media, let part = media.Part?.first else {
            throw MediaProviderError.notFound
        }
        return part.id
    }

    // MARK: - Watch state

    func markPlayed(_ itemRef: MediaItemRef) async throws {
        try await plexCall {
            try await networkManager.markWatched(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
        }
    }

    func markUnplayed(_ itemRef: MediaItemRef) async throws {
        try await plexCall {
            try await networkManager.markUnwatched(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
        }
    }

    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        try await plexCall {
            try await networkManager.reportProgress(
                serverURL: serverURL, authToken: authToken,
                ratingKey: itemRef.itemID, timeMs: Int(position * 1000), state: "playing"
            )
        }
    }

    // MARK: - Watchlist

    var supportsWatchlist: Bool { true }

    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool {
        // The shared PlexWatchlistService maintains an observable cache of
        // watchlist GUIDs. For TMDB-rooted refs (e.g. from Discover) we can
        // answer directly. For Plex-rooted refs (library items) we'd need to
        // resolve the item's tmdb GUID first — left for Phase 3 watchlist
        // wiring once it has the MediaItem in hand.
        await MainActor.run {
            if ref.providerID == TMDBMediaMapper.providerID,
               let (tmdbId, _) = TMDBMediaMapper.decodeItemID(ref.itemID) {
                return PlexWatchlistService.shared.contains(tmdbId: tmdbId)
            }
            return false
        }
    }

    func addToWatchlist(_ ref: MediaItemRef) async throws {
        // TODO(phase-3-watchlist): resolve the item's tmdb:// guid (via
        // LibraryGUIDIndex for Plex refs, direct from ref for TMDB refs) and
        // call PlexWatchlistService.shared.add(guid:item:). Phase 3's
        // detail-view watchlist toggle and Discover-row context menu have
        // the MediaItem (with title/year/posterURL) needed to build the
        // PlexWatchlistItem stub.
        throw MediaProviderError.backendSpecific(
            underlying: "Use PlexWatchlistService.shared.add for now; provider passthrough wired in Phase 3"
        )
    }

    func removeFromWatchlist(_ ref: MediaItemRef) async throws {
        // TODO(phase-3-watchlist): mirror addToWatchlist's plumbing.
        throw MediaProviderError.backendSpecific(
            underlying: "Use PlexWatchlistService.shared.remove for now; provider passthrough wired in Phase 3"
        )
    }

    // MARK: - Helpers

    private func plexSortString(for sort: SortOption) -> String? {
        switch sort {
        case .titleAsc: return "titleSort:asc"
        case .titleDesc: return "titleSort:desc"
        case .releaseDateDesc: return "originallyAvailableAt:desc"
        case .addedAtDesc: return "addedAt:desc"
        case .ratingDesc: return "rating:desc"
        }
    }
}
