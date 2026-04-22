//
//  DiscoverRow.swift
//  Rivulet
//
//  Horizontal row of DiscoverTiles. Mirrors MediaRow's layout, padding,
//  spacing, focus, and onPress behavior so Discover blends with Home/Library.
//
//  Each tile has a long-press context menu: if the item is in library, Play
//  appears alongside Add/Remove Watchlist; otherwise only Add/Remove Watchlist.
//

import SwiftUI

struct DiscoverRow: View {
    let rowID: String
    let title: String
    let items: [TMDBListItem]
    let isInLibrary: (TMDBListItem) -> Bool
    let isOnWatchlist: (TMDBListItem) -> Bool
    /// Legacy direct-select fallback (used when no preview handler is wired).
    let onSelect: (TMDBListItem) -> Void
    /// Called when the user taps a tile to open the carousel preview. When
    /// nil, tap falls back to `onSelect`.
    let onPreviewRequested: ((PreviewRequest) -> Void)?
    /// Async-resolves a TMDB item to the matched `PlexMetadata` for
    /// context-menu playback. Returns nil for non-library items.
    let libraryMatch: (TMDBListItem) async -> PlexMetadata?

    @Environment(\.uiScale) private var scale

    private var titleSize: CGFloat { ScaledDimensions.sectionTitleSize * scale }
    private var horizontalPadding: CGFloat { ScaledDimensions.rowHorizontalPadding }
    private var itemSpacing: CGFloat { ScaledDimensions.rowItemSpacing * scale }

    @FocusState private var focusedItemId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: itemSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            if let onPreviewRequested {
                                let mediaItems = items.map { TMDBMediaMapper.item($0) }
                                onPreviewRequested(
                                    PreviewRequest(
                                        items: mediaItems,
                                        selectedIndex: index,
                                        sourceRowID: rowID,
                                        sourceItemID: String(item.id)
                                    )
                                )
                            } else {
                                onSelect(item)
                            }
                        } label: {
                            DiscoverTile(
                                item: item,
                                isInLibrary: isInLibrary(item),
                                isOnWatchlist: isOnWatchlist(item)
                            )
                        }
                        .buttonStyle(CardButtonStyle())
                        .focused($focusedItemId, equals: String(item.id))
                        .previewSourceAnchor(rowID: rowID, itemID: String(item.id))
                        .tmdbContextMenu(
                            item: item,
                            isInLibrary: isInLibrary(item),
                            libraryMatch: libraryMatch,
                            onInfo: { onSelect(item) }
                        )
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 32)
            }
            .scrollClipDisabled()
        }
        .focusSection()
        .defaultFocus($focusedItemId, items.first.map { String($0.id) })
    }
}
