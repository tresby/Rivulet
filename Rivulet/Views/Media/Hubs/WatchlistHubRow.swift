//
//  WatchlistHubRow.swift
//  Rivulet
//
//  Renders the user's Plex Watchlist as a horizontal row on Home. Mirrors the
//  visual style of MediaRow / MediaPosterCard so it blends with other hubs.
//

import SwiftUI
import os.log

private let watchlistRowLog = Logger(subsystem: "com.rivulet.app", category: "WatchlistHubRow")

struct WatchlistHubRow: View {
    @ObservedObject var watchlist: PlexWatchlistService

    /// Called when the user taps a tile to open the carousel preview. When
    /// nil, tap falls back to the legacy per-kind handlers below.
    var onPreviewRequested: ((PreviewRequest) -> Void)?
    /// Legacy direct-select fallbacks — library-matched vs. TMDB-only.
    /// Only invoked when `onPreviewRequested` is nil.
    let onSelectPlex: (PlexMetadata) -> Void
    let onSelectTMDB: (TMDBListItem) -> Void
    var onRowFocused: (() -> Void)?

    @Environment(\.uiScale) private var scale

    private var titleSize: CGFloat { ScaledDimensions.sectionTitleSize * scale }
    private var horizontalPadding: CGFloat { ScaledDimensions.rowHorizontalPadding }
    private var itemSpacing: CGFloat { ScaledDimensions.rowItemSpacing * scale }

    private let rowID = "home.watchlist"

    @FocusState private var focusedItemId: String?

    var body: some View {
        if watchlist.watchlistItems.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Watchlist")
                    .font(.system(size: titleSize, weight: .bold))
                    .padding(.horizontal, horizontalPadding)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: itemSpacing) {
                        ForEach(Array(watchlist.watchlistItems.prefix(20).enumerated()), id: \.element.id) { index, item in
                            Button {
                                tap(item: item, index: index)
                            } label: {
                                WatchlistTile(item: item)
                            }
                            .buttonStyle(CardButtonStyle())
                            .focused($focusedItemId, equals: item.id)
                            .previewSourceAnchor(rowID: rowID, itemID: item.id)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 32)
                }
                .scrollClipDisabled()
            }
            .focusSection()
            .defaultFocus($focusedItemId, watchlist.watchlistItems.first?.id)
            .onChange(of: focusedItemId) { oldValue, newValue in
                if oldValue == nil && newValue != nil {
                    onRowFocused?()
                }
            }
        }
    }

    /// On tap: if a preview handler is wired, open the carousel with all
    /// watchlist items as MediaItems. Library-matched entries are still TMDB-
    /// ref'd in the carousel because the row *is* a TMDB/watchlist view;
    /// MediaDetailView's action row adapts to the ref's providerID.
    private func tap(item: PlexWatchlistItem, index: Int) {
        guard let onPreviewRequested else {
            Task { await legacySelect(item) }
            return
        }
        let allItems = watchlist.watchlistItems.prefix(20)
        let mediaItems: [MediaItem] = allItems.compactMap { mediaItem(from: $0) }
        guard !mediaItems.isEmpty,
              let validIndex = mediaItems.firstIndex(where: { $0.ref.itemID == mediaItemID(for: item) }) else {
            Task { await legacySelect(item) }
            return
        }
        onPreviewRequested(
            PreviewRequest(
                items: mediaItems,
                selectedIndex: validIndex,
                sourceRowID: rowID,
                sourceItemID: item.id
            )
        )
        _ = index // reserved for future use (e.g. row scrolling); kept for API shape
    }

    /// Build a MediaItem from a watchlist entry via TMDBMediaMapper. Returns
    /// nil when the watchlist item lacks a TMDB id (shouldn't happen for
    /// well-formed watchlist rows; filter out to keep the carousel well-indexed).
    private func mediaItem(from item: PlexWatchlistItem) -> MediaItem? {
        guard let tmdbId = item.tmdbId else { return nil }
        let mediaType: TMDBMediaType = item.type == .movie ? .movie : .tv
        let stub = TMDBListItem(
            id: tmdbId,
            title: item.title,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: item.year.map { "\($0)" },
            voteAverage: nil,
            mediaType: mediaType
        )
        // The stub lacks poster/backdrop paths, but TMDBMediaMapper handles
        // nil artwork gracefully. MediaDetailView's metadataSource branch
        // will fetch the richer detail on expand.
        var built = TMDBMediaMapper.item(stub)
        if let poster = item.posterURL {
            // Splice in the poster URL the watchlist service already cached.
            built = MediaItem(
                ref: built.ref,
                kind: built.kind,
                title: built.title,
                sortTitle: built.sortTitle,
                overview: built.overview,
                year: built.year,
                runtime: built.runtime,
                parentRef: built.parentRef,
                grandparentRef: built.grandparentRef,
                episodeNumber: built.episodeNumber,
                seasonNumber: built.seasonNumber,
                childProgress: built.childProgress,
                userState: built.userState,
                artwork: MediaArtwork(
                    poster: poster,
                    backdrop: built.artwork.backdrop,
                    thumbnail: poster,
                    logo: built.artwork.logo
                ),
                parentArtwork: built.parentArtwork,
                grandparentArtwork: built.grandparentArtwork
            )
        }
        return built
    }

    private func mediaItemID(for item: PlexWatchlistItem) -> String {
        item.tmdbId.map(String.init) ?? item.id
    }

    /// Pre-carousel behavior: library-matched items go straight to
    /// MediaDetailView via onSelectPlex; TMDB-only items go via onSelectTMDB.
    /// Retained as a fallback in case a caller doesn't supply
    /// `onPreviewRequested`.
    private func legacySelect(_ item: PlexWatchlistItem) async {
        guard let tmdbId = item.tmdbId else {
            watchlistRowLog.warning("[Select] no tmdbId on \(item.title, privacy: .public), guids=\(item.guids.joined(separator: ","), privacy: .public)")
            return
        }
        let mediaType: TMDBMediaType = item.type == .movie ? .movie : .tv
        if let match = await LibraryGUIDIndex.shared.lookup(tmdbId: tmdbId, type: mediaType) {
            onSelectPlex(match)
            return
        }
        let stub = TMDBListItem(
            id: tmdbId,
            title: item.title,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: item.year.map { "\($0)" },
            voteAverage: nil,
            mediaType: mediaType
        )
        onSelectTMDB(stub)
    }
}

private struct WatchlistTile: View {
    let item: PlexWatchlistItem

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }

    var body: some View {
        poster
            .frame(width: posterWidth, height: posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hoverEffect(.highlight)
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
    }

    @ViewBuilder
    private var poster: some View {
        if let url = item.posterURL {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color(white: 0.15))
                        .overlay { ProgressView().tint(.white.opacity(0.3)) }
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.18), Color(white: 0.12)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay {
                Image(systemName: item.type == .movie ? "film" : "tv")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }
}
