//
//  PlexMusicMapper.swift
//  Rivulet
//
//  Maps PlexMetadata -> agnostic music types. Stateless pure functions.
//  Mirrors PlexMediaMapper's conventions.
//

import Foundation

enum PlexMusicMapper {

    // MARK: - User state

    static func userState(_ meta: PlexMetadata) -> MusicUserState {
        // Plex userRating is 0-10; normalize to 0.0-5.0 for the music layer.
        // isFavorite is true whenever any rating has been set (>0).
        let rating: Double? = meta.userRating.map { $0 / 2.0 }
        return MusicUserState(
            isFavorite: (meta.userRating ?? 0) > 0,
            userRating: rating,
            playCount: meta.viewCount ?? 0,
            lastPlayedAt: meta.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    // MARK: - Artwork

    private static func artwork(_ meta: PlexMetadata, serverURL: String, authToken: String) -> MediaArtwork {
        MediaArtwork(
            poster: PlexMediaMapper.artworkURL(meta.thumb ?? meta.bestThumb, serverURL: serverURL, authToken: authToken),
            backdrop: PlexMediaMapper.artworkURL(meta.bestArt, serverURL: serverURL, authToken: authToken),
            thumbnail: PlexMediaMapper.artworkURL(meta.thumb, serverURL: serverURL, authToken: authToken),
            logo: nil
        )
    }

    // MARK: - Artist

    static func artist(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicArtist {
        MusicArtist(
            ref: MediaItemRef(providerID: providerID, itemID: meta.ratingKey ?? ""),
            name: meta.title ?? "",
            sortName: nil,
            artwork: artwork(meta, serverURL: serverURL, authToken: authToken),
            genres: meta.Genre?.compactMap(\.tag) ?? [],
            yearRange: nil,
            userState: userState(meta)
        )
    }

    // MARK: - Album

    static func album(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicAlbum {
        let artistRef: MediaItemRef? = meta.parentRatingKey.map {
            MediaItemRef(providerID: providerID, itemID: $0)
        }
        return MusicAlbum(
            ref: MediaItemRef(providerID: providerID, itemID: meta.ratingKey ?? ""),
            title: meta.title ?? "",
            sortTitle: nil,
            artistRef: artistRef,
            artistName: meta.parentTitle,
            year: meta.year,
            artwork: artwork(meta, serverURL: serverURL, authToken: authToken),
            trackCount: meta.leafCount,
            totalDuration: meta.duration.map { TimeInterval($0) / 1000 },
            genres: meta.Genre?.compactMap(\.tag) ?? [],
            userState: userState(meta)
        )
    }

    // MARK: - Track

    static func track(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicTrack {
        let albumRef: MediaItemRef? = meta.parentRatingKey.map {
            MediaItemRef(providerID: providerID, itemID: $0)
        }
        let artistRef: MediaItemRef? = meta.grandparentRatingKey.map {
            MediaItemRef(providerID: providerID, itemID: $0)
        }
        let durationMs = meta.duration ?? 0
        // Pick the first audio stream's codec + bitrate if available.
        let firstAudio: PlexStream? = (meta.Media ?? []).first?.Part?.first?.Stream?
            .first(where: { $0.streamType == 2 })
        return MusicTrack(
            ref: MediaItemRef(providerID: providerID, itemID: meta.ratingKey ?? ""),
            title: meta.title ?? "",
            albumRef: albumRef,
            albumTitle: meta.parentTitle,
            artistRef: artistRef,
            artistName: meta.grandparentTitle,
            trackNumber: meta.index,
            discNumber: meta.parentIndex,
            duration: TimeInterval(durationMs) / 1000,
            audioCodec: firstAudio?.codec,
            bitrate: firstAudio?.bitrate,
            sampleRate: firstAudio?.samplingRate,
            artwork: artwork(meta, serverURL: serverURL, authToken: authToken),
            userState: userState(meta)
        )
    }

    // MARK: - Dispatch

    /// Routes a generic PlexMetadata to the appropriate MusicItem case.
    /// Returns nil for non-music types so callers can filter mixed lists.
    static func item(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicItem? {
        switch meta.type {
        case "artist":
            return .artist(artist(meta, providerID: providerID, serverURL: serverURL, authToken: authToken))
        case "album":
            return .album(album(meta, providerID: providerID, serverURL: serverURL, authToken: authToken))
        case "track":
            return .track(track(meta, providerID: providerID, serverURL: serverURL, authToken: authToken))
        default:
            return nil
        }
    }

    // MARK: - Details

    static func artistDetail(
        _ meta: PlexMetadata,
        albums: [PlexMetadata],
        topTracks: [PlexMetadata],
        similarArtists: [PlexMetadata],
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicArtistDetail {
        MusicArtistDetail(
            artist: artist(meta, providerID: providerID, serverURL: serverURL, authToken: authToken),
            bio: meta.summary,
            genres: meta.Genre?.compactMap(\.tag) ?? [],
            albums: albums.map {
                album($0, providerID: providerID, serverURL: serverURL, authToken: authToken)
            },
            topTracks: topTracks.map {
                track($0, providerID: providerID, serverURL: serverURL, authToken: authToken)
            },
            similarArtists: similarArtists.map {
                artist($0, providerID: providerID, serverURL: serverURL, authToken: authToken)
            }
        )
    }

    static func albumDetail(
        _ meta: PlexMetadata,
        tracks tracksList: [PlexMetadata],
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicAlbumDetail {
        let contributors: [MediaPerson] = (meta.Role ?? []).map { role in
            MediaPerson(
                id: role.id,
                name: role.tag ?? "",
                role: role.role,
                imageURL: PlexMediaMapper.artworkURL(role.thumb, serverURL: serverURL, authToken: authToken)
            )
        }
        return MusicAlbumDetail(
            album: album(meta, providerID: providerID, serverURL: serverURL, authToken: authToken),
            tracks: tracksList.map {
                track($0, providerID: providerID, serverURL: serverURL, authToken: authToken)
            },
            genres: meta.Genre?.compactMap(\.tag) ?? [],
            contributors: contributors
        )
    }

    static func trackDetail(
        _ meta: PlexMetadata,
        lyrics: String?,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MusicTrackDetail {
        MusicTrackDetail(
            track: track(meta, providerID: providerID, serverURL: serverURL, authToken: authToken),
            lyrics: lyrics
        )
    }
}
