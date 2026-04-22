//
//  MusicPlaylistView.swift
//  Rivulet
//
//  Playlist detail view showing tracks with play/shuffle actions.
//  Matches album detail layout with artwork left, track list right.
//

import SwiftUI

struct MusicPlaylistView: View {
    let playlist: PlexMetadata
    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var tracks: [MusicTrack] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
            } else if let error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(error)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                contentView
            }
        }
        .task {
            await loadTracks()
        }
    }

    // MARK: - Content

    private var contentView: some View {
        HStack(alignment: .top, spacing: 50) {
            // Left: Playlist info
            playlistInfo
                .frame(width: 340)
                .padding(.top, 60)

            // Right: Track list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.ref) { index, track in
                        let isCurrent = musicQueue.currentTrack?.ref == track.ref

                        Button {
                            musicQueue.playAlbum(tracks: tracks, startingAt: index)
                        } label: {
                            HStack(spacing: 16) {
                                // Track number or playing indicator
                                if isCurrent {
                                    PlaybackIndicator(
                                        isPlaying: musicQueue.playbackState == .playing,
                                        size: .small
                                    )
                                    .frame(width: 28)
                                } else {
                                    Text("\(index + 1)")
                                        .font(.system(size: 18).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.4))
                                        .frame(width: 28)
                                }

                                // Track info
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title)
                                        .font(.system(size: 22, weight: isCurrent ? .semibold : .regular))
                                        .foregroundStyle(isCurrent ? .white : .white.opacity(0.9))
                                        .lineLimit(1)

                                    Text(track.artistName ?? track.albumTitle ?? "")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white.opacity(0.5))
                                        .lineLimit(1)
                                }

                                Spacer()

                                // Duration
                                Text(formatDuration(track.duration))
                                    .font(.system(size: 18).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 20)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                musicQueue.addNext(track: track)
                            } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }

                            Button {
                                musicQueue.addToEnd(track: track)
                            } label: {
                                Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward")
                            }
                        }

                        if index < tracks.count - 1 {
                            Divider()
                                .background(.white.opacity(0.06))
                                .padding(.leading, 64)
                        }
                    }
                }
                .padding(.vertical, 60)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 80)
    }

    // MARK: - Playlist Info

    private var playlistInfo: some View {
        VStack(spacing: 20) {
            // Artwork
            playlistArtView
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            // Title
            VStack(spacing: 8) {
                Text(playlist.title ?? "Playlist")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if !tracks.isEmpty {
                    Text("\(tracks.count) tracks \u{00B7} \(totalDuration)")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                }

                if let summary = playlist.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
            }

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    musicQueue.playAlbum(tracks: tracks)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color.white.opacity(0.18))

                Button {
                    var shuffled = tracks
                    shuffled.shuffle()
                    musicQueue.playAlbum(tracks: shuffled)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color.white.opacity(0.14))
            }
        }
    }

    // MARK: - Artwork

    private var playlistArtView: some View {
        Group {
            if let url = playlistArtURL {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        compositeArtPlaceholder
                    }
                }
            } else if tracks.count >= 4 {
                compositeArt
            } else {
                compositeArtPlaceholder
            }
        }
    }

    private var compositeArt: some View {
        let artTracks = Array(tracks.prefix(4))
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
            ForEach(artTracks, id: \.ref) { track in
                if let url = artURL(for: track) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Rectangle().fill(Color(white: 0.15))
                        }
                    }
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
                } else {
                    Rectangle().fill(Color(white: 0.15))
                        .aspectRatio(1, contentMode: .fill)
                }
            }
        }
    }

    private var compositeArtPlaceholder: some View {
        Rectangle()
            .fill(Color(white: 0.12))
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.system(size: 60, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }

    // MARK: - Helpers

    private var playlistArtURL: URL? {
        guard let thumb = playlist.thumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private func artURL(for track: MusicTrack) -> URL? {
        track.artwork.poster
    }

    private var totalDuration: String {
        let totalSeconds = Int(tracks.map(\.duration).reduce(0, +))
        let totalMinutes = totalSeconds / 60
        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            return "\(hours) hr \(mins) min"
        }
        return "\(totalMinutes) min"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    private func loadTracks() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = playlist.ratingKey else {
            error = "Unable to load playlist"
            isLoading = false
            return
        }

        do {
            let raw = try await PlexNetworkManager.shared.getChildren(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            )
            let machineID = PlexAuthManager.shared.selectedServer?.machineIdentifier ?? "unknown"
            let providerID = "plex:\(machineID)"
            tracks = raw.filter { $0.type == "track" }.map {
                PlexMusicMapper.track($0, providerID: providerID, serverURL: serverURL, authToken: token)
            }
            isLoading = false
        } catch {
            self.error = "Failed to load tracks"
            isLoading = false
        }
    }
}
