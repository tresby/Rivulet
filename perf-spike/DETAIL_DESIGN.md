# UIKit Media Detail + Preview Carousel Rewrite

**Status**: design. Implementation follows immediately.

**Goal**: replace the SwiftUI `MediaDetailView` + `PreviewOverlayHost`
duo with a UIKit/TVUIKit equivalent that is **visually identical** but
faster. This is the single largest perf bet in the migration; if UIKit
wins here, the migration's ROI is decided.

**Non-goal**: improving the architecture beyond what's required for
parity + perf. The SwiftUI surface has known smells (one view doing
three jobs, deep cascade chains, a 17-parameter init); we clone the
behavior 1:1 and refactor later if perf testing surfaces a need. No
architectural prettification on top of platform port.

Authoritative behavior reference: `perf-spike/DETAIL_AUDIT.md`. Every
visible behavior, animation parameter, focus rule, and performance
workaround in the SwiftUI source is enumerated there.

---

## Architecture summary

Two new view controllers + a flat set of native UIKit views.

### `PreviewCarouselViewController` (replaces `PreviewOverlayHost`)

Hosts the carousel state machine + 3 visible card slots (n-1, n, n+1).
Each slot hosts a `MediaDetailViewController` child in
`.previewCarousel` mode. The selected slot's controller flips to
`.expandedDetail` and animates to fullscreen on expand. Black backdrop,
no scrim. Menu-button intercept (replaces
`PreviewContainerViewController`'s intercept).

State machine `.entryMorph → .carouselStable → .expandingHero →
.expandedHero → .detailsStable → .exiting`, ported verbatim from
`PreviewContext.swift`. `motionLocked` flag preserved. Monotonic
`metadataGate` counter (`PreviewLoadGate`) ported to a property-wrapper
type for the same cancellation semantics.

Morphs (entry, expand, collapse) implemented with
`UIViewPropertyAnimator` chains. The animators are stored on the host
VC so they can be paused / reversed if a new gesture arrives
mid-animation. Cascade fades (vignette fade-in, metadata fade-in,
settle-flag flip) use `async`/`await` with `Task.sleep` + cancellation
checks against `metadataGate`, matching the SwiftUI structure
function-for-function.

### `MediaDetailViewController` (replaces `MediaDetailView`)

Single VC supporting both pushed-navigation and carousel-embedded modes
via `MediaDetailPresentationMode { .previewCarousel, .expandedDetail }`
property. Internally a `UICollectionView` with compositional layout.

Section layout (top-to-bottom, single ScrollView axis):

| # | Section | Cell | Notes |
|---|---|---|---|
| 0 | Hero | `DetailHeroCell` (full screen height) | backdrop + scrims + slide content + action row |
| 1 | Seasons | `SeasonPillCell` (horizontal orthogonal) | shows + episodes only |
| 2 | Episodes | `EpisodeCell` (horizontal orthogonal) | shows + episodes only (unified list across seasons) |
| 3 | Related | `PosterCell` (horizontal orthogonal) | when `recommendedItems` non-empty |
| 4 | Collection | `PosterCell` (horizontal orthogonal) | when `collectionItems` non-empty |
| 5 | Cast | `CastCell` (horizontal orthogonal) | when cast or directors non-empty |
| 6 | BelowFoldTitle | `BelowFoldTitleCell` (overlay) | renders as a section header on section 1 with reserved height = `158 * scrollProgress` |

Scroll-driven UI state (mirrors SwiftUI exactly):
- `scrollProgress` (0..1) calculated in `scrollViewDidScroll`.
- Hero text VStack `alpha = 1 - scrollProgress`.
- Action row stays at full alpha for focus-reachability.
- Section-1 top inset = `158 * scrollProgress` to make room for the title-logo.
- BelowFoldTitle alpha = `(offset - 30) / 90` clamped.
- Material blur scrim on the hero scrim layer mounts only when `scrollProgress > 0.01` (parity with SwiftUI; `UIVisualEffectView` is the same perf cliff on tvOS regardless of host framework).
- `markDetailsStable()` fires at offset > 10 if in `.expandedDetail` mode and `previewAnimationSettled == true`.

### Data lifecycle

`MediaDetailViewController` owns its data tasks. Properties:

- `isCurrent: Bool` (set by carousel host on the selected slot; always true for pushed) — gates whether detail data loads.
- `previewAnimationSettled: Bool` (set by carousel host after the entry/paging cascade finishes; always true for pushed) — gates the data cascade.
- `enableDetailDataLoading: Bool` (alias for `isCurrent` in carousel mode, true in pushed mode).

When both gates are true: `loadDetailData()` fires (parallel async-let fan: collection + recommendations, OR seasons + episodes + nextUp depending on kind). Mirrors SwiftUI `loadDetailData` at `MediaDetailView.swift:2146`.

Below-fold thumbnail prefetch fires before `belowFoldLoaded = true` flip so `ImageCacheManager` returns synchronous cache hits on the first frame of the below-fold reveal. Same pattern as SwiftUI.

Logo-latching (`hasDisplayedHeroLogoImage`, `retainedLogoURL`) replicated as cell state inside `DetailHeroCell`.

### Reuse from prior Home work

- `HeroBackdropView` (parallax + crossfade) reused for the hero backdrop.
- `MediaProgressInfoBar` is NOT reused here — the detail's action row uses native pill / circle buttons we'll subclass.
- `HeroPillButton` / `HeroCircleButton` reused as the base classes for the detail's action buttons. `HeroPlayPillButton` is a new subclass that adds an inline progress overlay layer.
- `ImageCacheManager`, `CachedAsyncImage`'s underlying paths — unchanged.
- `PerfSignpost` — instrumented at the same beats as the SwiftUI version (`detailLoadStart`, `detailLoadComplete`, `belowFoldLoaded`, `previewAnimationSettled` flip) so Instruments traces compare apples-to-apples.

---

## File layout

```
Rivulet/Views/Media/MediaDetail/UIKit/
  MediaDetailViewController.swift
  Cells/
    DetailHeroCell.swift
    DetailHeroMetadataStackView.swift
    DetailHeroActionRowView.swift
    HeroPlayPillButton.swift
    EpisodeCell.swift
    SeasonPillCell.swift
    CastCell.swift
    BelowFoldTitleCell.swift
  Support/
    DetailSectionLayoutBuilder.swift
    DetailDataLoader.swift
    DetailFocusCoordinator.swift

Rivulet/Views/Media/PreviewCarousel/UIKit/
  PreviewCarouselViewController.swift
  PreviewCarouselState.swift
  PreviewMorphAnimator.swift
```

`PreviewContext.swift` (state machine + load gate types) stays —
they're shared between the SwiftUI and UIKit implementations during
transition.

`HeroBackdropView`, `PosterCell`, `ContinueWatchingCell`,
`HubHeaderView`, `MediaProgressInfoBar` move out of `PlexHome/UIKit/`
into `Media/UIKit/Cells/` (already done — see commit `4c1411a`).

---

## State machine port

`PreviewStateMachine` in `PreviewContext.swift:73-147` is already a
plain struct. Reused as-is. The UIKit host owns it as a `var` and
mutates it inside `UIViewPropertyAnimator` `addAnimations` blocks for
phase changes that need to coincide with the morph (entry, expand,
collapse).

`PreviewLoadGate` is also reused as-is.

`PreviewFocusArea` enum kept; only `.carousel` is used in practice
(per audit).

---

## Animation parameters

All durations and curves match the SwiftUI source verbatim (see audit
section 5).

Entry morph: `UISpringTimingParameters(dampingRatio: 0.88,
initialVelocity: .zero)` for a `UIViewPropertyAnimator(duration: 0.45,
timingParameters: spring)`. tvOS's spring-timing-parameters
approximate SwiftUI's `spring(response: 0.45, dampingFraction: 0.88)`.

Paging: `UICubicTimingParameters(controlPoint1: (0.40, 0.02),
controlPoint2: (0.18, 1.0))`, duration 0.78s. Drives card x-translation
AND per-card inner-image parallax from the same animator's
`fractionComplete` observer so they stay in lockstep (mirrors
SwiftUI's single `pagingProgress` source-of-truth).

Expand / collapse: `UIViewPropertyAnimator(duration: 0.35,
curve: .easeInOut)`.

Cascade fades (vignette, metadata, settled-flag): plain `UIView.animate
(withDuration:)` from inside `async` cascade functions that
`Task.sleep` between steps. Cancellation via gate counter checks
between awaits.

---

## Carousel geometry

`PreviewCarouselViewController` defines geometry constants matching
audit section 2.1 verbatim:
- `topInset = 52`
- `cornerRadius = 28`
- `centeredHorizontalInset = 88`
- `sideCardGap = 14`
- `carouselParallaxFactor = 0.70`

Three slot UIViews (`leftSlot`, `centerSlot`, `rightSlot`). Each hosts
a child `MediaDetailViewController`. On `selectedIndex` change, the
slot views' `transform.tx` animates such that:
- centerSlot moves to the new selected index's carouselFrame.x
- the other two slots become left and right peeks

After paging completes, the slot views are renamed (the old leftSlot
becomes the new centerSlot etc.) and the trailing-edge slot gets
configured with the next neighbor's item. No view tear-down /
re-creation per page.

Z-order matches audit section 2.1: center always on top.

---

## Focus + menu button

`MediaDetailViewController.preferredFocusEnvironments` returns the
action row when in `.expandedDetail`. Default focus inside the action
row goes to the Play button (the `HeroPlayPillButton`).

Below-fold sections: focus restoration via
`UICollectionView.remembersLastFocusedIndexPath = true` (already
proved on the Home).

Menu button:
- `PreviewCarouselViewController.pressesBegan` intercepts `.menu`,
  invokes a `menuPressed()` method.
- `menuPressed()` first checks the active child's
  `previewMenuInterceptHandler` (a delegate protocol) — gives the
  detail VC a chance to consume the press for internal unwind
  (e.g., scroll-to-top, clear focused episode).
- If not consumed, runs `state.exitAction()` → either dismiss or
  collapse to carousel.

---

## Sub-item navigation

When the user taps a related/collection item, an episode card, or a
cast member's "More from this person", we need to navigate to a new
detail.

**Carousel mode**: dismiss the current preview, present a new
`PreviewCarouselViewController` at the new item. Same as SwiftUI's
`onSubItemNavigation` callback pattern.

**Pushed mode**: push a new `MediaDetailViewController` onto whatever
nav stack contains the current one. Implementation: route through a
delegate the host (the SwiftUI bridge that pushed us) implements.

---

## Imperative player presentation

Inherited from SwiftUI: player VCs are presented by walking
`UIApplication.connectedScenes` to find the topmost VC and calling
`present(_:animated:)`. We keep that pattern verbatim — it's the only
way the player container can intercept Menu correctly. See
`MediaDetailView.swift:2107-2114`.

---

## Implementation phases

Committed per iteration, each iteration building + smoke-testing on
the sim before the next.

1. **Skeleton**: types + state machine + carousel host VC + detail VC
   shell (registers compositional layout, dequeues empty cells).
2. **Hero cell**: backdrop, scrims, metadata stack, action row.
   Renders correctly when populated with a sample `MediaItem`.
3. **Below-fold sections**: seasons / episodes / related / collection /
   cast. Each section laid out + cells dequeueing.
4. **Data loading + cascade**: `loadDetailData` parallel async fans,
   `previewAnimationSettled` gating, below-fold thumbnail prefetch.
5. **Carousel morphs**: entry from source tile → carouselFrame;
   carousel paging (3-slot positioning); expand → fullFrame.
6. **Focus + menu + navigation**: action row default focus,
   restoration, menu intercept chain, sub-item nav callbacks.
7. **Integration**: replace `PreviewOverlayHost` call sites
   (PlexHomeView still uses the SwiftUI version for now; the UIKit
   home swaps to the new `PreviewCarouselViewController`).
8. **Perf measurement**: run `Scripts/perf_compare.sh` against both
   SwiftUI and UIKit detail+preview paths.

Each iteration is its own commit. Behind a feature flag if needed (we
already have the `homeImplementation` AppStorage pattern; could add
`detailImplementation` similarly).

---

## Risks + open questions

- **`UIViewPropertyAnimator` + tvOS focus**: known to be flaky.
  Mitigation: drive focus updates *outside* animator blocks — the
  animator handles geometry, focus updates happen in the cascade's
  `await` sleep between blocks.
- **`HeroBackdropView` Ken Burns vs scroll parallax stacking**: home
  has scroll-driven backdrop offset; detail adds Ken Burns
  (`kenBurnsOffset` 0→50 over 15s repeatForever). Need both
  transforms composed. Implementation: a child `UIView` inside
  `HeroBackdropView` carries the Ken Burns transform; the outer view
  carries the scroll parallax.
- **Logo-latching across paging**: `hasDisplayedHeroLogoImage` per
  cell — but cells get reused. Solution: the latch is *per-item*
  (keyed by ratingKey), stored in a controller-level dict, not
  per-cell.
- **Carousel slot recycling**: when paging right beyond the loaded
  window, the leftSlot's controller needs to be reconfigured to the
  new n-1 item. We don't tear down + re-create the controller —
  `MediaDetailViewController.configure(with: MediaItem, mode:)`
  reuses the same controller instance.
- **Pushed-mode hosting**: the existing SwiftUI nav stack pushes a
  `UIViewControllerRepresentable` wrapper. Need to make sure
  `MediaDetailViewController` works correctly as a child of a SwiftUI
  `NavigationStack`. (Should be fine — same pattern as the Home.)

---

## Success criteria

1. **Visual parity**: every animation, fade, scale, color, and layout
   matches the SwiftUI version.
2. **Functional parity**: all action buttons, focus moves, menu
   handling, sub-item nav, sheet presentations work identically.
3. **Perf win**: on physical Apple TV 4K (3rd gen), the UIKit detail
   surface shows measurable improvement over the SwiftUI version on
   at least one metric per the perf-agent threshold (median delta >
   2× stddev AND > 15%). Target metrics: cold-launch-into-detail,
   carousel paging hitch time, scroll-down-in-detail hitch time,
   RSS at steady state.

---

## What I'm NOT doing

- **Multi-source agnostic refactor**. Detail continues to mix
  `PlexMetadata` and `MediaItem` exactly like SwiftUI does. Refactor
  is its own project.
- **Action row icon changes** or any visual tweaks "while we're in
  there." Strict parity.
- **Live TV detail surface**. Out of scope; that's a separate vertical.
- **DetailCardCarousel** (the older carousel in
  `DetailCardCarousel.swift`). Used by `PlexLibraryView` and
  `PlexSearchView`; will be addressed when those screens get
  migrated.
- **`MediaItemAgnosticRow`** (used by the related/collection rows in
  the SwiftUI detail). We'll either replicate it as a UIKit poster
  row or have the host VC inline a `PosterCell`-backed orthogonal
  section. Decided during implementation.
