//
//  MusicArtistDetailView.swift
//  Rivulet
//
//  Artist detail page tuned to the Apple Music tvOS hierarchy.
//

import SwiftUI

struct MusicArtistDetailView: View {
    let artist: MusicArtist

    @Environment(MusicProviderRegistry.self) private var registry
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var detail: MusicArtistDetail?
    @State private var isLoading = true
    @State private var isPlayingAll = false
    @State private var isShuffling = false
    @State private var selectedAlbum: MusicAlbum?

    private let gridColumns = Array(
        repeating: GridItem(.fixed(188), spacing: 28, alignment: .top),
        count: 4
    )

    private var provider: (any MusicProvider)? {
        registry.provider(for: artist.ref.providerID)
    }

    private var artistPhotoURL: URL? { artist.artwork.poster }

    private var albums: [MusicAlbum] { detail?.albums ?? [] }

    private var sortedAlbums: [MusicAlbum] {
        albums.sorted { ($0.sortTitle ?? $0.title) < ($1.sortTitle ?? $1.title) }
    }

    var body: some View {
        ZStack {
            backgroundView

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 34) {
                    headerSection
                    actionRow

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if sortedAlbums.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 34) {
                            ForEach(sortedAlbums) { album in
                                MusicPosterCard(item: .album(album), style: .square) {
                                    selectedAlbum = album
                                }
                                .musicItemContextMenu(item: .album(album), style: .album)
                            }
                        }
                    }

                    if let bio = detail?.bio, !bio.isEmpty {
                        aboutSection(bio)
                    }
                }
                .padding(.horizontal, 72)
                .padding(.top, 56)
                .padding(.bottom, 64)
            }
        }
        .navigationDestination(item: $selectedAlbum) { album in
            MusicAlbumDetailView(album: album)
        }
        .task {
            await loadDetail()
        }
    }

    private var backgroundView: some View {
        LinearGradient(
            colors: [
                Color(red: 0.17, green: 0.2, blue: 0.24),
                Color(red: 0.1, green: 0.11, blue: 0.14),
                Color.black
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.14)
        }
        .ignoresSafeArea()
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 24) {
            artistPortrait

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(.system(size: 31, weight: .bold))
                    .lineLimit(2)

                if !albums.isEmpty {
                    Text("\(albums.count) albums")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 32)
        }
    }

    private var artistPortrait: some View {
        CachedAsyncImage(url: artistPhotoURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty, .failure:
                Circle()
                    .fill(.regularMaterial)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 32, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
            @unknown default:
                EmptyView()
            }
        }
        .frame(width: 112, height: 112)
        .clipShape(Circle())
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await playAll(shuffled: false) }
            } label: {
                Label(isPlayingAll ? "Loading" : "Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.white.opacity(0.18))
            .disabled(isPlayingAll || isShuffling)

            Button {
                Task { await playAll(shuffled: true) }
            } label: {
                Label(isShuffling ? "Loading" : "Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.white.opacity(0.14))
            .disabled(isPlayingAll || isShuffling)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("No albums found")
                .font(.system(size: 20, weight: .medium))
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func aboutSection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About")
                .font(.system(size: 21, weight: .semibold))

            Text(summary)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .lineLimit(6)
        }
        .padding(.top, 6)
    }

    private func loadDetail() async {
        guard let provider = provider else { isLoading = false; return }
        do {
            detail = try await provider.artistDetail(for: artist.ref)
        } catch {
            print("MusicArtistDetailView: Failed to load detail: \(error)")
        }
        isLoading = false
    }

    private func playAll(shuffled: Bool) async {
        guard let provider = provider else { return }
        if shuffled { isShuffling = true } else { isPlayingAll = true }
        defer {
            isPlayingAll = false
            isShuffling = false
        }
        do {
            var tracks = try await provider.allTracks(for: artist.ref)
            if shuffled { tracks.shuffle() }
            if !tracks.isEmpty {
                musicQueue.playAlbum(tracks: tracks, startingAt: 0)
            }
        } catch {
            print("MusicArtistDetailView: playAll failed: \(error)")
        }
    }
}
