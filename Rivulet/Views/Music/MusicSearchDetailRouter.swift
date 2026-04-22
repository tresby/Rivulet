//
//  MusicSearchDetailRouter.swift
//  Rivulet
//
//  Routes a Plex-typed music metadata item (from search or home hubs) to
//  the correct agnostic music detail view. Converts the PlexMetadata to
//  the agnostic music type via PlexMusicMapper, then pushes the matching
//  MusicArtistDetailView / MusicAlbumDetailView. Tracks are played directly
//  via MusicQueue (no detail view) and so are intercepted at the tap site,
//  not here.
//

import SwiftUI

struct MusicSearchDetailRouter: View {
    enum Kind {
        case artist
        case album
    }

    let plexMeta: PlexMetadata
    let kind: Kind

    @Environment(MusicProviderRegistry.self) private var registry
    @ObservedObject private var authManager = PlexAuthManager.shared

    var body: some View {
        // The router takes a PlexMetadata and uses PlexMusicMapper — it only
        // makes sense for a Plex-backed primary provider. Guard explicitly so
        // a future non-Plex primary produces an obvious failure rather than
        // silently mapping with wrong credentials.
        if let provider = registry.primaryProvider,
           provider.kind == .plex,
           let serverURL = authManager.selectedServerURL,
           let token = authManager.selectedServerToken {
            switch kind {
            case .artist:
                let artist = PlexMusicMapper.artist(
                    plexMeta,
                    providerID: provider.id,
                    serverURL: serverURL,
                    authToken: token
                )
                MusicArtistDetailView(artist: artist)
            case .album:
                let album = PlexMusicMapper.album(
                    plexMeta,
                    providerID: provider.id,
                    serverURL: serverURL,
                    authToken: token
                )
                MusicAlbumDetailView(album: album)
            }
        } else {
            Text("No music provider available")
                .foregroundStyle(.secondary)
        }
    }
}
