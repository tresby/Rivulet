# UIKit Expanded Detail + Shared Chrome Design

**Status:** design — supersedes the original `perf-spike/DETAIL_DESIGN.md` for the iterations after carousel-stable
**Started:** 2026-05-28, end of session
**Branch:** `perf-tvuikit-spike` (51 commits ahead of main at design time, tip `bc127a9`)

## Goal

Take the working UIKit carousel-stable chrome and extend it to support the **expanded detail surface**, **without re-doing the chrome layout work**. The carousel-stable card and the expanded-detail VC must share the same chrome rendering code so a layout fix in one is automatically a fix in the other.

## Non-goal

Visual changes to the carousel-stable look. The current cell layout in `PreviewCardView` matches SwiftUI ground truth at the structural level (logo / genre / description / quality / action row / cast). Polish lives in a later pass.

## Architecture

```
                       ┌──────────────────────┐
                       │ MediaDetailChromeView│  ← shared UIView
                       │                      │     containing:
                       │  ┌────────────────┐  │       logo
                       │  │ metadataBlock  │  │       genre row
                       │  │ (760pt max)    │  │       description
                       │  └────────────────┘  │       quality row
                       │  ┌────────────────┐  │     and:
                       │  │ actionAndCast  │  │       action row
                       │  │ (full width)   │  │       cast
                       │  └────────────────┘  │
                       └──────────────────────┘
                              ↑           ↑
                              │           │
                  embedded in │           │ embedded in
                              │           │
              ┌───────────────┴──┐   ┌────┴──────────────────────┐
              │ PreviewCardView  │   │ MediaDetailViewController │
              │ (carousel cell)  │   │ (fullscreen detail)       │
              │                  │   │                           │
              │ + backdrop       │   │ + backdrop                │
              │ + vignette       │   │ + vignette                │
              │ + corner clip    │   │ + no corner clip          │
              │ + 118pt insets   │   │ + 140pt insets (expanded) │
              │                  │   │ + below-fold sections     │
              └──────────────────┘   └───────────────────────────┘
```

### MediaDetailChromeView surface

```swift
final class MediaDetailChromeView: UIView {
    var item: MediaItem? { didSet { applyItem() } }
    var detail: MediaItemDetail? { didSet { applyDetail() } }

    /// Layout mode — narrows insets, swaps action-row interactivity.
    var mode: Mode = .carouselStable
    enum Mode {
        case carouselStable   // disabled action row, 118pt host insets
        case expandedDetail   // enabled action row, 140pt host insets
    }

    /// Driven by the parent for the cascade fade-in. UIView.animate
    /// blocks the parent owns directly — the chrome view exposes the
    /// vignette container alpha + action+metadata block alpha as
    /// separate animatable properties so the parent can stagger them.
    var chromeAlpha: CGFloat { get set }       // logo+metadata+quality+actionRow
    var vignetteAlpha: CGFloat { get set }     // gradient layers

    /// Action callbacks the host wires up. In carouselStable mode the
    /// buttons are disabled and these are unused (focus engine can't
    /// reach them). In expandedDetail mode the host wires them to the
    /// playback flow, watchlist service, etc.
    var onPlay: (() -> Void)?
    var onToggleWatched: (() -> Void)?
    var onToggleWatchlist: (() -> Void)?
    var onShowFullDescription: (() -> Void)?
}
```

### How the two embedders use it

**`PreviewCardView` (carousel cell):**
- Embeds chrome anchored bottom-leading at the card's `-118pt` from leading edge, bottom 220pt up from the card bottom (shelf peek reserve).
- Sets `chromeView.mode = .carouselStable`. Action row is interaction-disabled.
- `setIsCurrent(_:animated:)` drives `chromeAlpha` + `vignetteAlpha` via the existing cascade timer logic.
- `prepareForReuse` clears `chromeView.item = nil`.

**`MediaDetailViewController` (fullscreen detail):**
- Embeds chrome anchored bottom-leading at `-140pt` from leading edge (matches SwiftUI `heroOverlayHorizontalInset` for expanded mode), bottom 220pt up from the screen bottom.
- Sets `chromeView.mode = .expandedDetail`. Action row is focus-enabled and tap-wired.
- No cascade — chrome is visible immediately on viewDidAppear (the cascade only matters during the carousel paging UX).
- Below-fold sections (`UICollectionView`) sit below the hero in the same scroll view, with `shelfPeek = 220` reserve poking up at the hero's bottom edge.

## Implementation iterations

Each lands as one commit. Build between each; visually verify against SwiftUI reference screenshots in `~/Desktop/swift_*.png`.

### Iter A: extract `MediaDetailChromeView`

Lift everything in `PreviewCardView` that's not backdrop / vignette / corner clip into a new `Rivulet/Views/Media/MediaDetail/UIKit/MediaDetailChromeView.swift`. Includes:
- `chromeStack` + `metadataBlock` + `logoSlotView` + `titleLogoImageView` + `titleFallbackLabel`
- `genreRow`, `descriptionLabel`, `qualityRow`
- `actionAndCastRow`, `actionButtonsStack`, `castLabel`
- All `applyItem` / `applyDetail` / `rebuildGenreRow` / `rebuildQualityRow` / `rebuildActionButtons` logic
- All caption-label / badge / button factories (`makeCaptionLabel`, `makePlayPill`, `makeCircleButton`, `makeContentRatingBadge`, `makeQualityBadge`)
- Detail fetch (`loadDetail`)

`PreviewCardView` shrinks to:
- backdropImageView + stage size logic
- vignetteContainer + gradient layers
- chromeView (instance of `MediaDetailChromeView`)
- `apply(_:)` for layout attrs (parallax + alpha)
- `setIsCurrent(_:animated:)` — animates `vignetteContainer.alpha` and `chromeView.chromeAlpha`

**Verify:** rebuild, deploy, open carousel — should look identical to current state.

### Iter B: `MediaDetailViewController` shell with chrome embedded

The existing skeleton at `Rivulet/Views/Media/MediaDetail/UIKit/MediaDetailViewController.swift` is empty. Replace with:
- backdropImageView (full screen, no clip)
- vignetteContainer (same gradient layers; full screen)
- chromeView (instance of `MediaDetailChromeView`, mode `.expandedDetail`)
- No paging, no morph — this is presented via `navigationController?.pushViewController`
- onPlay/onToggleWatched/etc. callbacks stubbed (print to console) — real wiring comes in iter D

**Verify:** add a temporary "expand" trigger in the carousel (long-press the center cell, or override the Select key) that pushes `MediaDetailViewController(item:)`. Confirm chrome renders at fullscreen with 140pt insets, vignette visible, action row enabled.

### Iter C: expand morph

When the user presses Select on the centered carousel card:
1. Capture the carousel card's current frame in window coordinates
2. Push `MediaDetailViewController` with a transition that morphs from that frame to fullscreen
3. The push uses a custom `UIViewControllerAnimatedTransitioning` that animates:
   - The detail VC's backdrop alpha 0→1
   - The detail VC's chrome view's frame from card-frame coords to fullscreen-frame coords
   - The card's chrome alpha 1→0 to match the dissolve
4. Reverse on pop (back to carousel)

Spring matches SwiftUI: response 0.45, dampingRatio 0.88 (same as the carousel entry spring).

**Verify:** smooth morph in both directions; no flicker at boundary; chrome doesn't reflow during morph (because `MediaDetailChromeView` doesn't know it's being animated — its constraints are stable; the host animates its frame).

### Iter D: real action wiring

Stub callbacks become real:
- `onPlay` — present `UniversalPlayerViewController` (the existing route through `ContentRouter`)
- `onToggleWatched` — call `PlexNetworkManager.shared.markWatched(...)` or similar
- `onToggleWatchlist` — call `PlexWatchlistService.shared.add/remove(...)`
- `onShowFullDescription` — present a sheet with the full overview text

The Play pill's progress bar and right-side time become accurate from `item.userState.viewOffset` / runtime.

**Verify:** Play button on a known item launches playback. Watched toggle persists. Watchlist add works for both Plex-library and Discover items.

### Iter E: below-fold sections

Add a `UICollectionView` to `MediaDetailViewController` below the hero, with sections for:
- **Related** (movies/shows): `PosterCell` reuse from the home VC
- **Cast** (people): new `CastCell` — circular avatar + name + role
- **Seasons** (shows only): `SeasonCell`
- **Episodes** (per season): `EpisodeCell`

`shelfPeek = 220` (movies) / 160 (TV) reserves space at the bottom of the hero where the first below-fold row peeks. Scroll progress drives the hero chrome fade-out as in SwiftUI (line 847 `.opacity(1 - scrollProgress)`).

**Verify:** scroll smoothness, focus navigation up from below-fold returns focus to the hero action row (matches SwiftUI line 854-859 `.onMoveCommand`).

### Iter F: cleanup

- Delete the SwiftUI `MediaDetailView` once UIKit detail is the default and tested
- Flip `PreviewImplPreference` default permanently to `.uikit`
- Audit `MediaDetailView.swift` for any non-detail code that needs to be preserved elsewhere
- Update CLAUDE.md project structure section
- Write the migration's net diff stats and capture a final perf trace

## Reference data

- SwiftUI source: `Rivulet/Views/Media/MediaDetailView.swift` (3,748 lines as of 2026-05-28)
- Carousel host source: `Rivulet/Views/Media/PreviewOverlayHost.swift` (905 lines)
- All SwiftUI constants documented in `~/.claude/projects/-Users-bain-git-Swift-Projects-Rivulet/memory/uikit_carousel_migration.md` "Key constants" table
- SwiftUI reference screenshots (carousel-stable): `~/Desktop/swift_elio.png`, `~/Desktop/swift_jack.png`
- Current UIKit state: `~/Desktop/uikit_elio.png`, `~/Desktop/uikit_jack.png` — for visual diff before each iteration

## Out of scope (still)

- Expanded-detail's blurred-summary mode (Plex's "spoiler hide" UX)
- Episode picker bottom sheet
- Watched-show progress bar
- Trailer playback button
- "Up Next" caption row in carousel mode
- Per-season focus restoration on return from episode detail

These all exist in SwiftUI and need porting eventually, but post-iter F.
