//
//  MusicProvider.swift
//  Rivulet
//
//  Sibling to MediaProvider for the music surface. Music-only backends
//  (Navidrome, Subsonic) and music-capable general backends (Plex,
//  Jellyfin) conform. Reuses the video-agnostic MediaItemRef, MediaLibrary,
//  SortOption, Page, PagedResult, StreamInfo, MediaProviderKind, ConnectionState.
//

import Foundation

protocol MusicProvider: Sendable, Identifiable {
    var id: String { get }                       // same shape as MediaProvider: "plex:<machineID>"
    var kind: MediaProviderKind { get }
    var displayName: String { get }
    var connectionState: ConnectionState { get }

    // MARK: - Browse
    func musicLibraries() async throws -> [MediaLibrary]
    func artists(in library: MediaLibrary,
                 sort: SortOption,
                 page: Page) async throws -> PagedResult<MusicArtist>
    func albums(in library: MediaLibrary,
                sort: SortOption,
                page: Page) async throws -> PagedResult<MusicAlbum>
    func search(_ query: String) async throws -> [MusicItem]

    // MARK: - Hierarchy
    func albums(for artistRef: MediaItemRef) async throws -> [MusicAlbum]
    func tracks(for albumRef: MediaItemRef) async throws -> [MusicTrack]
    func allTracks(for artistRef: MediaItemRef) async throws -> [MusicTrack]

    // MARK: - Detail
    func artistDetail(for ref: MediaItemRef) async throws -> MusicArtistDetail
    func albumDetail(for ref: MediaItemRef) async throws -> MusicAlbumDetail
    func trackDetail(for ref: MediaItemRef) async throws -> MusicTrackDetail

    // MARK: - Home rails
    func recentlyAddedAlbums(limit: Int) async throws -> [MusicAlbum]
    func recentlyPlayed(limit: Int) async throws -> [MusicItem]

    // MARK: - Playback
    func resolveStream(for trackRef: MediaItemRef) async throws -> StreamInfo

    // MARK: - State
    func setRating(_ rating: Double?, for ref: MediaItemRef) async throws
    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws
}
