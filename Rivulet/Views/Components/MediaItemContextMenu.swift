//
//  MediaItemContextMenu.swift
//  Rivulet
//
//  Context menu for media items with common actions
//

import SwiftUI

// MARK: - Context Menu Source

/// Identifies where the context menu was triggered from
enum MediaItemContextSource {
    case continueWatching
    case library
    case other
}

// MARK: - Context Menu Actions

/// Callback type for context menu actions that may require data refresh
typealias MediaItemRefreshCallback = () async -> Void

/// Callback type for navigation actions (synchronous)
typealias MediaItemNavigationCallback = () -> Void

// MARK: - Context Menu Modifier

/// A view modifier that adds a context menu to media items with common Plex actions
struct MediaItemContextMenu: ViewModifier {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let source: MediaItemContextSource
    var onRefreshNeeded: MediaItemRefreshCallback?
    var onShowInfo: MediaItemNavigationCallback?
    var onGoToSeason: MediaItemNavigationCallback?
    var onGoToShow: MediaItemNavigationCallback?
    var onShufflePlay: MediaItemNavigationCallback?

    @State private var isPerformingAction = false

    private let networkManager = PlexNetworkManager.shared
    private let dataStore = PlexDataStore.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            // Watch from Beginning
            Button {
                performAction(optimisticWatched: false) {
                    try await networkManager.markUnwatched(
                        serverURL: serverURL,
                        authToken: authToken,
                        ratingKey: item.ratingKey ?? ""
                    )
                }
            } label: {
                Label("Watch from Beginning", systemImage: "play.fill")
            }

            Divider()

            // Mark as Watched
            if item.viewCount == nil || item.viewCount == 0 || item.watchProgress != nil {
                Button {
                    performAction(optimisticWatched: true) {
                        try await networkManager.markWatched(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Mark as Watched", systemImage: "eye.fill")
                }
            }

            // Mark as Unwatched (only show if already watched)
            if let viewCount = item.viewCount, viewCount > 0 {
                Button {
                    performAction(optimisticWatched: false) {
                        try await networkManager.markUnwatched(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Mark as Unwatched", systemImage: "eye.slash.fill")
                }
            }

            // Remove from Continue Watching (only in continue watching section)
            if source == .continueWatching {
                Button(role: .destructive) {
                    performAction {
                        try await networkManager.removeFromContinueWatching(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Remove from Continue Watching", systemImage: "xmark.circle.fill")
                }
            }

            // Go to Season/Show (only for episodes)
            if item.type == "episode" {
                if let onGoToSeason = onGoToSeason, item.parentRatingKey != nil {
                    Button {
                        onGoToSeason()
                    } label: {
                        Label("Go to Season", systemImage: "list.number")
                    }
                }

                if let onGoToShow = onGoToShow, item.grandparentRatingKey != nil {
                    Button {
                        onGoToShow()
                    } label: {
                        Label("Go to Show", systemImage: "tv")
                    }
                }
            }

            // Shuffle Play (for shows and seasons)
            if item.type == "show" || item.type == "season" {
                if let onShufflePlay {
                    Button {
                        onShufflePlay()
                    } label: {
                        Label("Shuffle Play", systemImage: "shuffle")
                    }
                }
            }

            Divider()

            // More Info (navigate to detail view)
            if let onShowInfo = onShowInfo {
                Button {
                    onShowInfo()
                } label: {
                    Label("More Info", systemImage: "info.circle")
                }
            }

            // Refresh Metadata
            Button {
                performAction {
                    try await networkManager.refreshMetadata(
                        serverURL: serverURL,
                        authToken: authToken,
                        ratingKey: item.ratingKey ?? ""
                    )
                }
            } label: {
                Label("Refresh Metadata", systemImage: "arrow.clockwise")
            }
        }
    }

    private func performAction(optimisticWatched: Bool? = nil, _ action: @escaping () async throws -> Void) {
        guard !isPerformingAction else { return }
        isPerformingAction = true

        Task {
            do {
                try await action()
                // Apply optimistic update immediately for instant UI feedback
                if let watched = optimisticWatched, let ratingKey = item.ratingKey {
                    await MainActor.run {
                        dataStore.updateItemWatchStatus(ratingKey: ratingKey, watched: watched)
                    }
                }
                // Also refresh from server for consistency
                await onRefreshNeeded?()
            } catch {
                print("Context menu action failed: \(error)")
            }
            isPerformingAction = false
        }
    }
}

// MARK: - View Extension

extension View {
    /// Adds a context menu with common Plex media actions
    func mediaItemContextMenu(
        item: PlexMetadata,
        serverURL: String,
        authToken: String,
        source: MediaItemContextSource = .other,
        onRefreshNeeded: MediaItemRefreshCallback? = nil,
        onShowInfo: MediaItemNavigationCallback? = nil,
        onGoToSeason: MediaItemNavigationCallback? = nil,
        onGoToShow: MediaItemNavigationCallback? = nil,
        onShufflePlay: MediaItemNavigationCallback? = nil
    ) -> some View {
        modifier(MediaItemContextMenu(
            item: item,
            serverURL: serverURL,
            authToken: authToken,
            source: source,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo,
            onGoToSeason: onGoToSeason,
            onGoToShow: onGoToShow,
            onShufflePlay: onShufflePlay
        ))
    }

    /// MediaItem-based overload. Adapts the agnostic MediaItem to the Plex-typed
    /// context menu by resolving the ratingKey from the item's ref and deriving
    /// watch state from MediaUserState.
    func mediaItemContextMenu(
        mediaItem: MediaItem,
        serverURL: String,
        authToken: String,
        source: MediaItemContextSource = .other,
        onRefreshNeeded: MediaItemRefreshCallback? = nil,
        onShowInfo: MediaItemNavigationCallback? = nil,
        onGoToSeason: MediaItemNavigationCallback? = nil,
        onGoToShow: MediaItemNavigationCallback? = nil,
        onShufflePlay: MediaItemNavigationCallback? = nil
    ) -> some View {
        // Build a minimal PlexMetadata shell so the existing PlexMetadata-typed
        // context menu modifier can reuse its Plex network calls.
        // Post-wave-1: replace with a MediaItem-native context menu modifier.
        var shell = PlexMetadata()
        shell.ratingKey = mediaItem.ref.itemID
        shell.type = mediaItem.kind == .episode ? "episode"
                   : mediaItem.kind == .show ? "show"
                   : mediaItem.kind == .season ? "season"
                   : "movie"
        shell.viewCount = mediaItem.userState.isPlayed ? 1 : (mediaItem.isInProgress ? 0 : nil)
        shell.viewOffset = mediaItem.userState.viewOffset > 0 ? Int(mediaItem.userState.viewOffset * 1000) : nil
        shell.parentRatingKey = mediaItem.parentRef?.itemID
        shell.grandparentRatingKey = mediaItem.grandparentRef?.itemID
        return modifier(MediaItemContextMenu(
            item: shell,
            serverURL: serverURL,
            authToken: authToken,
            source: source,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo,
            onGoToSeason: onGoToSeason,
            onGoToShow: onGoToShow,
            onShufflePlay: onShufflePlay
        ))
    }
}
