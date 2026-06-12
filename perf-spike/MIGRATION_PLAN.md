# Rivulet UIKit/TVUIKit Migration Plan

**Branch**: `perf-tvuikit-spike`
**Status**: phase 1 in progress. UIKit Plex Home feature parity
reached on 2026-05-15 (commit `392f46c`), second-pass audit fixes
applied same day (commit `6ce12b4`), reusable cell vocabulary
moved to `Media/UIKit/Cells/` ready for Library to consume
(commit `4c1411a`). Pending user A/B verification on physical
device before the SwiftUI fallback is deleted. See the
file-level checklist at the bottom for current state.

This is the per-screen migration map. It exists so we can ship
incrementally without a multi-month "rewrite the whole app" project,
and so we don't waste effort migrating screens where SwiftUI is
already the right tool.

---

## TL;DR

**Migrate now (high-value)**: PlexHomeView (finish), PlexLibraryView,
DiscoverView, PlexSearchView. They share the cell vocabulary built in
the spike (`PosterCell`, `ContinueWatchingCell`, `HeroCell`,
`HubHeaderView`, `PlexHomeViewController` skeleton).

**Migrate as a coordinated rebuild (medium-term)**: MediaDetailView +
PreviewOverlayHost. They're effectively one surface; piecemeal
migration will fight you.

**Migrate if Live TV usage justifies it (separate vertical)**:
GuideLayoutView, LiveTVPlayerView. EPG grid alone may yield the largest
absolute perf win in the app.

**Keep in SwiftUI (don't migrate)**: Settings (entire tree), Music
(entire tree), Sidebars, ContentView, ChannelListView. Combined ~7500
LoC of low-traffic, low-animation code where SwiftUI is at its best.

**Total scope estimate**: 6-10 weeks of focused work for the
"migrate now" + "coordinated rebuild" tiers. Live TV adds 2-3 weeks
on top if pursued.

---

## Per-screen assessment

### Summary table

| # | Screen | LoC | Visual | Focus | Score | Recommendation |
|---|---|---:|---|---|---:|---|
| 1 | PlexHomeView | 1,501 + 912 spike | high | medium | 4 (remaining) | finish UIKit migration first |
| 2 | PlexLibraryView | 1,678 | high | medium-high | 7 | migrate next, reuses Home cells |
| 3 | DiscoverView | 405 | high | medium | 5 | migrate after Library |
| 4 | PlexSearchView | 621 | low-medium | medium | 4 | migrate after Discover |
| 5 | MediaDetailView | 3,430 | very high | high | 9-10 | rebuild, do not port |
| 6 | PreviewOverlayHost | 890 | very high | high | 9 | rebuild as part of Detail |
| 7 | GuideLayoutView | 620 | high | high | 8 | migrate (Live TV vertical) |
| 8 | LiveTVPlayerView | 1,275 + VM + slot | high | high | 8 | migrate (Live TV vertical) |
| 9 | ChannelListView | 270 | low | low | 2 | keep SwiftUI |
| 10 | MusicHomeView | 958 | medium | medium | 5 | keep SwiftUI |
| 11 | MusicAlbumDetailView | 347 | low-medium | low | 2 | keep SwiftUI |
| 12 | MusicArtistDetailView | 218 | low | low | 2 | keep SwiftUI |
| 13 | MusicNowPlayingView | 319 | medium | low | 3 | keep SwiftUI |
| 14 | MusicPlaylistView | 293 | low | low | 2 | keep SwiftUI |
| 15 | SettingsView (+10 sub-files) | 4,529 total | low | low | 3 | keep SwiftUI |
| 16 | TVSidebarView | 777 | low | medium-high | 5 | keep SwiftUI |
| 17 | SidebarView + ContentView | 152 + 288 | trivial | trivial | 1 | keep SwiftUI |

Score legend: 1 = trivial, 10 = multi-week project. Bigger score
means more migration work, NOT more perf benefit.

---

## Migration tier 1: high-value browse surfaces

These four share cell types and the compositional-layout skeleton
already in the spike. Each migration costs less than the last.

### 1. PlexHomeView — finish what the spike started

**Status**: 912 LoC of UIKit done in spike (`PlexHome/UIKit/`),
gated by AppStorage toggle. Both impls render real Plex data.

**Remaining work**:
- Hero parallax (Ken Burns + receding-on-scroll)
- Preview-cover entry-morph integration (`PreviewContainerViewController`
  hand-off — currently the SwiftUI version triggers the modal)
- Resume-or-restart confirmation sheet
- Personalized recommendations row
- Watchlist hub row (TMDB-typed)
- `FocusMemory` restoration when returning from a pushed detail
- Remove the AppStorage toggle once UIKit is the only impl

**Estimate**: 1 week. Deliverable: deletes
`Rivulet/Views/Media/PlexHomeView.swift`, removes the `PlexHomeRoot`
router, ships UIKit as the only Home.

**Sub-views to migrate alongside**: `MediaPosterCard`,
`ContinueWatchingCard`, `Hero/*`, `Hubs/WatchlistHubRow`,
`PreviewContainerViewController` (already UIKit, may need adjustments).

### 2. PlexLibraryView — second after Home

**Why next**: largest single SwiftUI surface after Detail (1,678
LoC). Adaptive `LazyVGrid`, hero, hubs, sort menus, prefetch,
parallax, resume-or-restart, focus restoration. Music vs video
dual layout. **Reuses `PosterCell`, `ContinueWatchingCell`,
`HubHeaderView`** from `Rivulet/Views/Media/UIKit/Cells/`
(already moved out of `PlexHome/UIKit/` for this purpose in
commit `4c1411a`). The hero plumbing (`HeroBackdropView` +
`HeroOverlayCell`) currently lives in `PlexHome/UIKit/`; if
Library needs the same parallax backdrop, lift them into the
shared dir at that point — premature now since their composition
inside the controller is what makes the parallax work.

**Architecture**: same `UICollectionView` + compositional layout.
Sections: hero, hub rows, then a single grid section with
`.fractionalWidth(0.2)` items for the main library. Pagination
hooks into the data source's `prefetchItemsAt`.

**Risk**: hero parallax is shared with Home — Home's is done,
Library inherits via the lifted views once that's needed. Sort
menu uses SwiftUI `Menu` which has known tvOS focus quirks;
UIKit `UIMenu` is more reliable.

**Estimate**: 1.5 weeks.

### 3. DiscoverView — clone the Home pattern

**Why**: architecturally identical to Home (parallax backdrop, hero
overlay, N section rows + watchlist toast + preview cover). Reads
TMDB-curated sections instead of Plex hubs. The `DiscoverHeroBackdrop`
+ `DiscoverHeroOverlay` already pulled out as separate components,
which makes porting clean.

**Architecture**: clone `PlexHomeViewController`, swap the section
data source for `DiscoverViewModel`. Watchlist toast = a
`UIVisualEffectView` slid in from the bottom with `UIView.animate`.

**Estimate**: 1 week.

### 4. PlexSearchView — last in tier 1

**Why**: `Searchable` field, debounced search (350ms), recent-searches
persistence, results in `LazyVStack`. Reuses `PosterCell` for results
display. Two `@FocusState` zones (search field, recent rows) → UIKit
becomes a `UISearchController` + collection view.

**Estimate**: 0.5 weeks.

---

## Migration tier 2: coordinated rebuild

### 5+6. MediaDetailView + PreviewOverlayHost — rebuild, don't port

**Combined scope**: 4,320 LoC of SwiftUI. They're conceptually one
surface — preview overlay cards embed `MediaDetailView` in
`previewCarousel` mode, expand into `expandedDetail` mode via
state machine. Trying to port them separately means maintaining
two copies of `MediaDetailView` (SwiftUI for the embedded carousel
preview, UIKit for the navigation-pushed detail) for the duration
of the migration. That's worse than a clean rebuild.

**Why rebuild rather than port**:
- MediaDetailView has 10 in-file structs, two-phase reveal
  cascade, scroll-driven backdrop blur, in-place item swap,
  `previewAnimationSettled` gating to defer cascade work — all
  mechanisms invented to dodge SwiftUI's perf cliffs. UIKit
  doesn't need any of them.
- PreviewOverlayHost's `PreviewStateMachine`
  (entryMorph → carouselStable → expandingHero → expandedHero →
  detailsStable → exiting) is 6 states of bespoke animation
  scheduling. UIKit `UIViewPropertyAnimator` + `UIPageViewController`
  expresses this much more cleanly.

**Architecture (rebuild)**:
- `MediaDetailViewController` — `UICollectionView` with sections:
  hero, action buttons, season picker, episodes (or recommended for
  movies), cast, collection, related/recommended.
- `PreviewOverlayController` — `UIPageViewController` for the
  carousel, with explicit `UIViewPropertyAnimator`s for entry-morph
  and expand-to-detail. Embeds `MediaDetailViewController` as the
  expanded child.

**Estimate**: 2-3 weeks for the pair, done in parallel.

**Risk**: the highest-complexity migration in the plan. Defer until
tier 1 is done so the team has UIKit muscle.

---

## Migration tier 3: Live TV (separate vertical, optional)

### 7. GuideLayoutView (EPG)

**Why migrate**: EPG grids (channels × time) are the textbook
UICollectionView-with-custom-layout problem and the textbook
SwiftUI focus nightmare. The spike's perf wins on Home (which is a
list) will likely be **dwarfed** by the wins on a 2D focus grid.

**Architecture**: `UICollectionView` with a custom
`UICollectionViewLayout` subclass for the EPG grid. Channel rows are
sticky on the leading edge; time slots scroll horizontally. UIKit
focus engine handles 2D nav natively — no custom focus guides needed.

**Estimate**: 1.5 weeks.

### 8. LiveTVPlayerView (multi-stream)

**Why migrate after Guide**: shares the `RivuletPlayer` slot pattern
with Guide's PIP. 1-4 simultaneous streams in a manually-laid-out
grid is much cleaner with raw UIView frames.

**Estimate**: 1.5 weeks.

**Live TV total**: 3 weeks. Only worth it if Live TV usage data
shows it's a primary use case.

---

## Keep in SwiftUI (do not migrate)

These are listed for completeness — explicitly out of scope.

### ChannelListView (270 LoC)
Simple grid + search. SwiftUI is fine.

### Music tree (~2,135 LoC across 5 detail/home views + components)
- MusicHomeView, MusicAlbumDetailView, MusicArtistDetailView,
  MusicNowPlayingView, MusicPlaylistView, plus components
- Apple-Music-style layouts SwiftUI handles well
- Low animation density
- Probably not high enough traffic to justify migration cost

### Settings tree (~4,529 LoC across 11 files)
- Forms-heavy, single-column lists
- No animations, low focus complexity
- UIKit equivalent would be 3× the code (manual layout, table view
  cells, etc.) for negligible perf gain

### Sidebars (~929 LoC)
- TVSidebarView wraps the system `TabView(.sidebarAdaptable)` —
  the canonical tvOS pattern. Reimplementing in UIKit means
  reimplementing tvOS's sidebar adaptation manually
- SidebarView (macOS/iOS only) and ContentView (thin shell) are
  trivial and out of scope

---

## Cell vocabulary (already built in spike)

These are reusable across tier 1 (Home, Library, Discover, Search):

```
Rivulet/Views/Media/PlexHome/UIKit/
  PlexHomeViewController.swift   -- skeleton: UICollectionView +
                                    UICollectionViewCompositionalLayout
  PosterCell.swift               -- TVPosterView wrapper
                                    (260×390, all-purpose poster)
  ContinueWatchingCell.swift     -- TVCardView wrapper
                                    (392×280 landscape with progress)
  HeroCell.swift                 -- placeholder (needs hero work)
  HubHeaderView.swift            -- section header label
```

Tier 1 migrations should refactor these out of `PlexHome/UIKit/` into a
shared `Rivulet/Views/Media/UIKit/Cells/` directory once Library is
the second consumer.

---

## Suggested migration sequence + timeline

**Phase 1 (3 weeks)**: tier 1 browse surfaces.
- Week 1: finish Home, ship as default, delete SwiftUI version
- Week 2: Library
- Week 3: Discover + Search

**Phase 2 (2-3 weeks)**: tier 2 detail rebuild.
- Combined MediaDetailView + PreviewOverlayHost rebuild

**Phase 3 (optional, 3 weeks)**: tier 3 Live TV.
- Decide based on Live TV usage telemetry

**Total**: 5-6 weeks (phases 1+2), or 8-9 weeks (all three phases).

After phase 2 the app is ~95% UIKit on the user-visible browse
surfaces. The remaining SwiftUI is concentrated in Settings, Music,
Player overlays — all places SwiftUI does fine.

---

## Risks and unknowns

1. **Hero parallax in UIKit**: ~~SwiftUI version uses~~
   ~~`onScrollGeometryChange` to drive a transform. UIKit equivalent~~
   ~~is `UIScrollViewDelegate.scrollViewDidScroll`. Straightforward~~
   ~~but I haven't built it in the spike yet.~~
   **Resolved (2026-05-15)** in commit `392f46c`. Built as
   `HeroBackdropView` (fixed full-bleed UIView sibling of the
   collection view) translated via `scrollViewDidScroll` with the
   same `1.3x + min(72, 0.72x)` formula as SwiftUI. The hero
   *overlay* (logo/metadata/buttons/dots) is hosted via SwiftUI
   `UIHostingController` inside a section-0 cell — pragmatic
   reuse of `HeroOverlayContent` (100% visual surface, no perf
   wins from a UIKit rewrite). Confirmed via spike subagent that
   the SwiftUI source has **no Ken Burns animation** (despite the
   user-prompt phrasing suggesting otherwise); only the scroll
   parallax + 0.22s opacity crossfade on URL change are real.

2. **`PreviewContainerViewController` (already UIKit)**: hosts SwiftUI
   `MediaDetailView`. When we rebuild MediaDetailView in UIKit, this
   container needs to host the new UIKit MediaDetailViewController
   instead. Plumbing change, low risk.

3. **`MediaProviderRegistry` vs UIKit**: registry types are
   `@Environment` SwiftUI-flavored. UIKit needs them via property
   injection or singleton access. Should be a 30-minute refactor.

4. **`FocusMemory` in UIKit**: ~~the SwiftUI helper relies on~~
   ~~`@FocusState` bindings. UIKit equivalent: store the~~
   ~~`IndexPath` of the last-focused cell per row and override~~
   ~~`indexPathForPreferredFocusedView(in:)`.~~
   **Resolved (2026-05-15)**. Turns out PlexHomeView doesn't
   actually use `FocusMemory` — that helper is only used inside
   `MediaDetailView` (seasons/episodes). PlexHomeView uses native
   `.focusSection()` per row plus a `restorePreviewFocusTarget`
   binding for preview-dismiss handoff. The UIKit equivalent
   ended up being `UICollectionView.remembersLastFocusedIndexPath
   = true` (free, native focus-engine behavior) plus a
   `pendingPreviewRestore: PreviewSourceTarget?` + a
   `preferredFocusEnvironments` override that points the focus
   engine at the source cell after the preview dismisses.

5. **Music sub-views from MediaDetailView**: detail's "More from
   this Album" / "More from this Artist" links push into the Music
   tree. If Music stays SwiftUI and Detail goes UIKit, the push
   becomes UIKit → UIHostingController(MusicXxxView). Already
   demonstrated to work in the spike.

6. **What if perf wins don't generalize**: Detail and Preview will
   probably show **larger** wins than Home (they're more
   animation-heavy). But this hasn't been measured. Build a Detail
   spike first if confidence is required before committing.

---

## File-level migration checklist

Tracked as TODOs to be ticked off:

- [~] **Home** — feature parity reached, A/B verification pending
  - [x] Hero parallax (HeroBackdropView + scroll-driven transform)
  - [x] Preview-cover entry-morph integration (via PreviewContainerViewController)
  - [x] Resume-or-restart sheet (UIAlertController(.actionSheet))
  - [x] Personalized recommendations row
  - [x] Watchlist hub row (+ async GUIDIndex lookup like WatchlistHubRow)
  - [x] Focus restoration (pendingPreviewRestore + preferredFocusEnvironments)
  - [x] Focus forwarding from hero cell to SwiftUI buttons inside
  - [x] nestedNavState.isNested updates so sidebar tab bar hides on push
  - [x] AppStorage observation (showHomeHero, enablePersonalizedRecommendations)
  - [x] Move reusable cells (PosterCell / ContinueWatchingCell / HubHeaderView /
        WatchlistPosterCell) to `Rivulet/Views/Media/UIKit/Cells/`
  - [ ] Delete `PlexHomeView.swift` (after user A/B confirms parity on device)
  - [ ] Delete `PlexHomeRoot.swift` (same gate)
  - [ ] Flip `homeImplementation` default from `swiftui` to `uikit` (same gate)
- [ ] **Library** (1.5 wks)
  - [ ] `PlexLibraryViewController`
  - [ ] Pagination via `prefetchItemsAt`
  - [ ] Hero (shared with Home)
  - [ ] Sort menu via `UIMenu`
  - [ ] Music vs video dual layout
- [ ] **Discover** (1 wk)
  - [ ] `DiscoverViewController` (clone Home skeleton)
  - [ ] TMDB section data source
  - [ ] Watchlist toast as `UIVisualEffectView`
- [ ] **Search** (0.5 wks)
  - [ ] `PlexSearchViewController` with `UISearchController`
  - [ ] Recent searches as a header section
- [ ] **Detail + Preview rebuild** (2-3 wks)
  - [ ] `MediaDetailViewController` skeleton
  - [ ] Hero with backdrop + Ken Burns
  - [ ] Action buttons (Play / Resume / Watched / Trailer / Watchlist)
  - [ ] Season picker
  - [ ] Episodes section (uses dual-focus pattern from earlier spike)
  - [ ] Cast row
  - [ ] Recommended / Collection sections
  - [ ] `PreviewOverlayController` (UIPageViewController)
  - [ ] Entry-morph + expand-to-detail animations
  - [ ] Update all callers (`PlexHomeView`, `PlexLibraryView`,
        `DiscoverView`, etc.) to push the UIKit detail instead
- [ ] **Live TV (optional)**
  - [ ] `GuideLayoutController` with custom EPG layout
  - [ ] `LiveTVPlayerController` for multi-stream

---

## Decision point

Today's perf-spike data justifies committing to phase 1 (browse
surfaces) without further investigation. Whether to commit to
phase 2 and beyond depends on whether the team wants to keep
investing in the platform-native quality direction or stop after
the highest-value wins.

My recommendation: commit to phases 1+2. Phase 1 is proven-easy and
high-impact. Phase 2 is the actual bottleneck (Detail and Preview
are where users spend the most time in browse mode) and the
rebuild — while expensive — eliminates a class of SwiftUI workarounds
the codebase has accumulated. Defer phase 3 (Live TV) pending usage
data.
