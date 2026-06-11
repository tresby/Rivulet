//
//  CachedHomeHub.swift
//  Rivulet
//
//  Lightweight, Codable projection of a single home/library hub row, carrying
//  the flat `MediaItem` instead of the heavyweight `PlexMetadata`. Stage 1 of
//  the MediaItem-native home migration (see
//  `perf-spike/MEDIAITEM_HOME_PLAN.md`): the home currently materializes ~116
//  65-field `PlexMetadata` structs at launch. This struct is the on-disk +
//  in-memory shape the home will eventually render from, mirroring 1:1 the row
//  set `PlexHomeViewController.computeSections()` produces today.
//
//  ADDITIVE ONLY in Stage 1: nothing consumes this projection yet. It is
//  produced by `PlexDataStore.projectHomeItems()` / `projectLibraryItems()` and
//  cached by `CacheManager.cacheHomeItems` / `cacheLibraryItems`, alongside (not
//  replacing) the existing `[PlexHub]` hub cache.
//
//  Field meanings track `HomeSectionData` / `HomeSectionID` so a later stage can
//  rebuild identical sections from the projection:
//    - `id`              — the `HomeSectionID.raw` string of the row.
//    - `title`           — the row header title.
//    - `isContinueWatching` — drives the CW cell + CW tile metrics.
//    - `hubKey`          — Plex hub key, used for row pagination.
//    - `hubIdentifier`   — Plex hub identifier.
//    - `totalSize`       — Plex's total item count for the "X of Y" indicator.
//    - `items`           — the row's items as flat `MediaItem`s.
//

import Foundation

nonisolated struct CachedHomeHub: Codable, Sendable {
    var id: String
    var title: String
    var isContinueWatching: Bool
    var hubKey: String?
    var hubIdentifier: String?
    var totalSize: Int?
    var items: [MediaItem]
}

/// An ordered list of home/library hub rows — the full projection for one
/// surface (the home, or a single library page).
typealias CachedHomeRail = [CachedHomeHub]
