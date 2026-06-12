# B: MediaItem-native home rendering — staged plan (2026-06-10)

Root cause: the home materializes ~116 `PlexMetadata` (65-field nested structs) at
launch and processes each synchronously (decode ~2.5-7s + construct ~3.7s + copy +
computeSections + applySnapshot + map to MediaItem). SwiftUI was fast because it was
lazy; UIKit realizes far more up front. Fix: render shelves from the flat ~15-field
`MediaItem`; materialize `PlexMetadata` only at detail/playback.

Key discovery: surfaces are ALREADY MediaItem-native —
- PosterCell/ContinueWatchingCell/WatchlistPosterCell have `configure(item: MediaItem)`.
- `presentPreview` already maps to `[MediaItem]`; `PreviewCarouselViewController`
  resolves `MediaItem.ref.itemID` → PlexMetadata lazily at play (the escape hatch).
- `HeroOverlayCell.configure(withMediaItems:)` + `MediaItemSlideView` exist (unused).
- `MediaProvider`/`PlexProvider` already return MediaItem.

Architecture: KEEP `dataStore.hubs: [PlexHub]` (optimistic updates/polling/Top Shelf
need it). ADD a derived, cached `[MediaItem]` projection (`PlexMediaMapper.item()`)
that the home consumes. Conversion runs on the network-refresh path (off launch).

## Stages
- **0** Make `MediaItem`, `MediaArtwork`, `MediaUserState` (and `MediaHub` if used) `Codable` (nonisolated). Prereq, no behavior change.
- **1** Cache model `CachedHomeHub { id,title,isContinueWatching,hubKey,hubIdentifier,totalSize, items:[MediaItem] }`; `CacheManager.cacheHomeItems/getCachedHomeItems` (+ library variants); `dataStore.homeItems`/`homeItemsVersion` + `projectHubsToItems()` called after every hubs/CW assignment + cacheHomeItems. No UI yet.
- **2 (LAUNCH WIN)** `HomeSectionData.plexItems:[PlexMetadata]` → `items:[MediaItem]`; computeSections/computeLibrarySections source from `homeItems`; mergedItems/pagination dedupe by `ref.itemID`; cell provider passes `section.items` (MediaItem overloads exist); applySnapshot IDs use `ref.itemID`; ambient/context-menu/focus-restore/preview/grid switch to MediaItem.
- **3 (LAUNCH WIN)** `loadHubsIfNeeded` reads `getCachedHomeItems()` FIRST (fast paint), removes heavy `[PlexHub]` decode from the critical path; deferred network refresh re-projects + re-caches. Migration: if MediaItem cache empty but PlexHub cache exists, project once. HIGHEST RISK — device-verify Release.
- **4** Hero + CW direct-play on MediaItem; `heroItems:[MediaItem]`; `configure(withMediaItems:)`; resolve PlexMetadata by ratingKey for the player VM (carousel pattern). Music + player VM genuinely need PlexMetadata (lazy resolve).
- **5** Remove dead `configure(item: PlexMetadata)` cell overloads (grep-guarded). Keep PlexMediaMapper.item, dataStore.hubs, lazy getFullMetadata.

Highest-risk coupling: Stage 3 launch-cache paint ordering (no heavy decode before
first paint; no double-paint between homeItemsVersion and hubsVersion; cold-launch +
post-update migration paths). Verify on-device Release.

Full plan detail: this session's Plan-agent output.
