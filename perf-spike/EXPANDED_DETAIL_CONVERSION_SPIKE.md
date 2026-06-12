# Expanded-Detail SwiftUI → UIKit Conversion Spike

Research spike to de-risk ~90% of converting the SwiftUI `MediaDetailView` (3748 lines)
expanded-detail surface to UIKit on `perf-tvuikit-spike`. Produced 2026-06-02 by a
5-agent parallel research pass (conversion inventory; focus engine; below-fold
architecture; per-cell effects + context menus; state/data/navigation), each grounded
in the codebase + Apple docs/WWDC and building on the already-verified
`UIKIT_FOUNDATIONS.md` §1–§6. Confidence levels and sources are inline.

Read this BEFORE starting the integration phase (the part that needs Plex/runtime).

---

## 0. The big picture

### What's already done

- **Carousel-stable preview + hero chrome** — converted, visually locked by the user.
  `MediaDetailChromeView` renders logo/genre/description/quality/cast/action-row.
- **Below-fold container** — `ExpandedDetailContainerView` owns the single-clock scroll
  choreography (blur/reserve/logo on `scrollProgress`), the episode-peek cascade, and the
  expand morph (`setExpanded` widens the clip + elongates thumbs, riding the morph
  animator). **Its sections are inert grey placeholders.**
- **Real cells** — `EpisodeCell`, `SeasonPillView`, `CastCell` ported (compile); `PosterCell`
  exists and is reused for related/collection.
- **Data loader** — `BelowFoldContentLoader.load(for:detail:)` ports the seasons/episodes/
  cast/related fetch into one value.

### The keystone gap

**The loader and all four cells exist but are NEVER CALLED.** The container shows grey
boxes. Wiring the loader → real cells is the single missing connection that makes the
surface real and unblocks visual verification of everything else. Everything below is in
service of doing that wiring correctly.

### The central architecture fork (decide before integrating)

The research split on one load-bearing question: **should the expanded below-fold be
FOCUS-DRIVEN or PRESS-DRIVEN?**

- **Focus-driven (recommended):** the below-fold becomes a real focusable
  `UICollectionView` (compositional, orthogonal-scrolling sections). The tvOS focus engine
  moves focus across episodes/cast/related, **auto-scrolls to keep the focused item
  visible**, and `remembersLastFocusedIndexPath` restores position — all for free. Cost: it
  must coexist with the deliberately **focusless** carousel (which uses the §2 invisible
  anchor + `.menu` gesture so Menu routes correctly). Reconciliation is viable (keep the
  `.menu` gesture on an ancestor VC; state-gate the collection's focusability) but needs
  three empirical confirmations on the sim (see §7).
- **Press-driven (fallback):** keep the whole modal press-routed (`canFocusItemAt = false`
  everywhere, single anchor). Drive each cell's `setFocused` from a container-tracked
  selected-index; hand-route Down/Up/Left/Right/Select among cells in `pressesBegan`. Cost:
  re-implements by hand (selection, scroll-to-selected, highlight, section-boundary
  crossing) everything the focus engine does natively — substantial, error-prone code.

**Recommendation: focus-driven**, because the below-fold is fundamentally a focus grid
(you focus individual episode/cast/poster cards), and hand-rolling focus navigation across
dozens of dynamic variable-width cells is the larger long-term liability. The carousel
stays focusless; the below-fold collection becomes focusable only in the expanded state.
The press-driven model is the documented fallback if focus arbitration proves intractable
on-device. **This is the one decision to confirm with the user + verify first on the sim.**

---

## 1. Below-fold architecture (high confidence)

Make the below-fold a second **`UICollectionView` + `UICollectionViewCompositionalLayout`**,
one orthogonal horizontal section per shelf, living inside `ExpandedDetailContainerView`,
revealed **after** the expand morph completes. Copy `PlexHomeViewController`'s proven
layout/data-source patterns almost verbatim (same codebase, perf-validated).

**Sections** (driven by item kind, mirroring `belowFoldPage`):

| Section | Kinds | Cell | Item size | Header |
|---|---|---|---|---|
| seasonPills | show/episode | `SeasonPillView`-in-cell | est. width × 40 | none |
| episodes | show/season/episode | `EpisodeCell` | 340 × ~300 | "Episodes" (season-detail only) |
| related | all | `PosterCell` (reuse) | 260 × 390 | "Related" |
| collection | movie | `PosterCell` | 260 × 390 | collection name |
| castCrew | all | `CastCell`-in-cell | 160 × 260 | "Cast & Crew" |

Each section: `.orthogonalScrollingBehavior = .continuous`, absolute item sizes,
`interGroupSpacing = 24`, `contentInsets = (top: 32, leading: 48, bottom: 32, trailing:
48)`, a `.top` boundary supplementary header (reuse `HubHeaderView`).
`UICollectionViewDiffableDataSource<BelowFoldSection, BelowFoldItem>` keyed like home.

### Driving `scrollProgress` — the load-bearing wire (high confidence, in-repo precedent)

**Verified:** with compositional layout the OUTER collection's `scrollViewDidScroll` fires
per-frame for vertical (section-to-section) scroll, INCLUDING focus-driven auto-scroll on
tvOS. Only the orthogonal *horizontal* rows are siphoned to private inner scrollers that
don't call the delegate — irrelevant to `scrollProgress`. `PlexHomeViewController.scrollViewDidScroll`
already drives hero parallax this exact way in production.

So the **choreography code does not change; only its input source does:**

```swift
func scrollViewDidScroll(_ sv: UIScrollView) {
    guard sv === belowFoldCollectionView else { return }
    let off = max(0, sv.contentOffset.y + sv.adjustedContentInset.top)
    detailContainer.driveScrollProgress(fromCollectionOffset: off)   // reuse apply() math
    if off > ExpandedDetailContainerView.reserveDistance { state.markDetailsStable() }
    else if off <= 1 { state.returnToExpandedHero() }
}
```

`driveScrollProgress` sets `scrollOffset = off` and runs the existing fade-outs
(`smallTitleLogo.alpha`, `seasonsHeader.alpha`, `onScrollProgress?` → blur + chrome fade),
WITHOUT `contentView.transform` or the `episodesTopConstraint` growth. The **158pt header
reserve becomes the first section's top content inset** (so the hero fades over a fixed
reserve as the collection scrolls under it — cleaner than animating the constraint).

### Peek ↔ collection coexistence (medium-high confidence)

**Keep the placeholder peek as-is for carousel-stable + the expand morph; cross-fade the
real collection in AFTER the morph completes. Do NOT put the collection on the morph clock.**
Per §6, a `UICollectionView` cannot ride the `UIViewPropertyAnimator` (its cells lay out via
their own machinery) — forcing it onto the morph reintroduces the `apply()`-owns-the-frame
class of bug. The peek (4 centered thumbs, `setExpanded` clip-widen/elongate) is purpose-built
to ride the single animator and is verified working. Lifecycle:

1. carousel-stable / expanding: placeholder peek rides the morph (`setExpanded`); collection `isHidden`.
2. morph completion (`finishExpand`, where `setNeedsFocusUpdate` already fires): position the
   collection so its episodes row lands on the peek thumbs, cross-fade peek→collection ~0.2s
   (post-morph → §6 not violated), then push focus into the collection.
3. detailsStable: collection's `scrollViewDidScroll` owns `scrollProgress`; peek hidden.
4. collapse: reverse — hide collection, restore peek, `reset()`, morph `setExpanded(false)`.

### Variable height (high confidence)

Drop the fixed `belowFoldHeight = 700`. The collection owns its `contentSize` and clamps its
own scroll; you only READ `contentOffset.y`. `maxScrollOffset` survives only for the peek's
transform path. `detailsRest` (the Down target) is **replaced by a focus move**: Down points
`preferredFocusEnvironments` at the collection + `setNeedsFocusUpdate`; the focus engine
auto-scrolls; `markDetailsStable()` fires when offset crosses 158.

### `belowFoldLoaded` fade gate (high confidence)

Keep `collection.alpha = 0` until the async load (parallel seasons/episodes/related +
thumbnail prewarm) completes for the current generation (gate with `PreviewLoadGate` token
in `PreviewContext.swift` so a fast pager invalidates stale loads). On completion:
`apply(snapshot, animatingDifferences: false)` then `UIView.animate(0.35, .curveEaseOut) {
alpha = 1 }`, deferred past any in-flight morph.

---

## 2. Focus model (recommended path; high confidence on the pieces)

| SwiftUI | UIKit (verified) |
|---|---|
| one `ScrollView` + `onScrollGeometryChange` | `UICollectionView`; `scrollViewDidScroll` → `scrollProgress` (§1) |
| `.focusSection()` per row | each compositional section is its own focus group; optional `focusGroupIdentifier` |
| `.remembersFocus` (FocusMemory) | `collectionView.remembersLastFocusedIndexPath = true` (engine-native, no flash) |
| `proxy.scrollTo(season, anchor:.center/.leading)` | `scrollToItem(at:at:.left, animated:)` — the BLESSED manual-scroll case (pill select only) |
| `onChange(focusedEpisodeId)` → sync pill | `collectionView(_:didUpdateFocusIn:)` → map next index to season → restyle pills |
| `.onMoveCommand(.up)` → return to Play | `UIFocusGuide` at top of collection, `preferredFocusEnvironments = [playButton]`, `isEnabled` only when expanded |
| Down into below-fold | focus engine bridges it if geometrically adjacent; else a `UIFocusGuide` over the hero gap |
| `selectionFollowsFocus` | **leave FALSE** — highlight on focus, commit on press (Play/Info are presses) |

- **Do NOT call `setNeedsFocusUpdate()` mid-morph** (§6); call it in the morph completion.
- **`scrollToItem` only for programmatic jumps** (pill→first episode, restore-to-top), never
  to "follow focus" (the engine already does, concurrent calls fight).
- **`remembersLastFocusedIndexPath` loses memory on section reload** — use `reconfigureItems`
  (not `reload`) for watched-status patches (§4) so focus survives.
- Keep **season-pill "selected" state separate from focus** — add `SeasonPillView.setSelected`
  (white-0.2 fill + border) distinct from `setFocused` (white fill, black text).

### Does adding focus break the §2 Menu pattern? (medium-high; verify on sim)

Not inherently — **provided the Menu handler lives on an ancestor** (a
`UITapGestureRecognizer(allowedPressTypes:[.menu])` on the VC's view) rather than depending
on the focusless anchor being the only target. With real focusable cells, Select/Play/Info
route to the focused cell naturally; the invisible anchor's role shrinks to "what focus rests
on in carousel-stable." The `.menu` gesture spans both states and preserves the existing
back-step ladder. **The one thing to verify first on the sim:** that the VC-level `.menu`
gesture still fires (back-steps) when an `EpisodeCell` is focused, rather than the focused
cell's chain consuming Menu. If starved, fall back to overriding `pressesBegan` on the
enclosing VC.

---

## 3. Per-cell effects + context menus (high confidence; strong in-repo precedents)

**Host decision first:** promote `EpisodeCell`/`CastCell`/`SeasonPillView` from bare
`UIView`s to `UICollectionViewCell`s before wiring focus + menus — the clean paths below all
assume cell hosting (and `PosterCell` already is one).

1. **Focus scale + border** — override `didUpdateFocus(in:with:)`, detect self-or-descendant
   focus (`context.nextFocusedView?.isDescendant(of: self)`), wrap mutations in
   `coordinator.addCoordinatedAnimations { }` (the §5 rule; `PosterCell.didUpdateFocus` lines
   153-163 already do this). EpisodeCard = whole-cell 1.05 scale + 4pt white thumb border
   (animate `borderWidth` inside the coordinated block — a bare set fires a mismatched
   implicit CA animation, §6). **Reset `transform`/`borderWidth` in `prepareForReuse`** (the
   known `addCoordinatedAnimations` fast-scroll stuck-scale bug). Don't use `TVPosterView`/
   `TVCardView` for the episode card (it brings Apple parallax/glow the SwiftUI explicitly
   disables) — but DO use `TVPosterView` for the Related `PosterCell` (it already does; that's
   the verified `.hoverEffect(.highlight)` equivalent — NOT `UIHoverStyle`, which is an iPad
   pointer API).
2. **Spoiler blur** — gate on `hideSpoilersForUnwatched && !isWatched` (mirror `blurForSpoilers`).
   Episode THUMBNAIL blur(18): **bake a `CIGaussianBlur` bitmap once when the image loads**
   (off-main, `affineClamp` first to avoid transparent edges), swap sharp↔blurred image to
   toggle — avoids N live effect views during scroll. Text summary blur(6/8): a small
   `UIVisualEffectView(.regular)` over the description region is fine (few cards visible).
   **Tear down/re-add effect views in `prepareForReuse`**; never alpha-fade a
   `UIVisualEffectView` (artifacts) — scrub a paused `UIViewPropertyAnimator.fractionComplete`.
3. **Watched tag — FIX THE MISMATCH:** the ported `WatchedCornerTagView` draws a blue
   triangular wedge; the SwiftUI `WatchedCornerTag` is a dark-0.55 `UnevenRoundedRectangle`
   (bottom-leading corner only, radius 8) with a centered white checkmark. **Delete the wedge;
   lift `PosterCell`'s `CornerTagBackgroundView`/`PosterWatchedBadge` (lines 360-524, already
   built to mirror the SwiftUI shape) into a shared file** and use it with
   `cornerTagInnerRadius = 8`.
4. **Context menus** — `UIContextMenuConfiguration` works on tvOS (trigger = long-press Select
   while the cell is focused; `point:` is meaningless). **Don't hand-roll per-cell
   interactions** — implement `collectionView(_:contextMenuConfigurationForItemsAt:point:)` on
   the detail VC and call the same `buildContextMenu` builder `PlexHomeViewController` already
   ships (lines 1666-1823: Watch from Beginning / Mark Watched-Unwatched / Go to Season / Go
   to Show / More Info / Refresh). Extract that builder into a shared helper. Default targeted
   preview (return `previewProvider: nil`) lifts the cell's own snapshot — faithful + cheapest.
5. **EpisodeCard two-button structure** — Option A (faithful): two focusable subviews
   (thumbnail=Play, description=Info) in the cell; `cell.preferredFocusEnvironments =
   [thumbnail]` so entering lands on Play (= `prefersDefaultFocus`); cell-level
   `didUpdateFocus` applies the unit 1.05 scale. Option B (simpler): single focusable cell,
   Select=Play, Info via the context menu — drops the description-button affordance + its
   color-invert state. **Flag this as a product call to the user** (B ships faster; A is
   faithful).

---

## 4. State / data / navigation (high confidence)

1. **`@AppStorage` → KVO on `UserDefaults`** (documented KVO-compliant). Prefer block-based
   `observe(_:options:changeHandler:)` (auto-invalidates) over manual add/removeObserver. On
   `hideSpoilersForUnwatched` change, reconfigure visible episode cells' spoiler state (pure
   render prop, no data reload). Read `useApplePlayer`/`promptResumeOrRestart` imperatively at
   action time.
2. **Watched propagation** — container observes `.episodeWatchedStatusChanged`
   (block-based, token removed in `deinit`; **must outlive pushed children** since the child
   episode-detail posts it). Port `applyEpisodeWatchedStatusUpdate` verbatim (pure `MediaItem`),
   patch the backing array, then `snapshot.reconfigureItems([id]); apply(animatingDifferences:
   false)` — `reconfigure` reruns the provider on the SAME cell instance (focus preserved);
   never `reload`.
3. **Season pill → episode list** — two distinct SwiftUI paths: the unified-list (shows) only
   **scrolls** (`scrollToItem(at:.left, animated:)` to the season's first episode; no data
   swap), with a reverse sync restyling the pill as you cross a season boundary. The
   season-detail path re-fetches and **crossfades** — match it with `UIView.transition(with:
   collection, duration: 0.35, options: .transitionCrossDissolve) { apply(animatingDifferences:
   false) }` (diffable's built-in animation is moves, not a crossfade).
4. **`displayedItem` in-place swap** (Related/Collection tap replaces the whole detail, no
   push) — add `reconfigure(for: newItem)`: bump a `reloadToken`, clear below-fold state, reset
   scroll to hero, set `chromeView.item = newItem`, re-point the VC-owned backdrop artwork,
   re-run `BelowFoldContentLoader`, rebuild sections, cross-fade 0.35. Keep an
   `originalItem`/`displayedItem` pair so collapse restores the original. Gate on stable phases
   (never during the morph, §6).
5. **Navigation / presentation:**
   - episode → episode-detail: `PreviewContainerViewController.dismissPreview(completion:)` then
     host push (the verified `preview_overlay_dismiss_pattern`; **must use `dismissPreview`, not
     `dismiss(animated:)`** — the latter's completion is unreliable under `.overFullScreen`).
   - player: resolve `MediaItem → PlexMetadata` (full metadata for DV/HDR), read
     `useApplePlayer`, present `PlayerContainerViewController`(RPlayer) or
     `NativePlayerViewController`(AVPlayer) ON TOP of the preview (full-screen takeover, not a
     nav push).
   - resume-or-restart: `UIAlertController(.alert)` (tvOS has no `.actionSheet`), 3 actions,
     gated on `promptResumeOrRestart`.
   - trailer / track / summary sheets: wrap the existing SwiftUI views in
     `UIHostingController` and present (`fullScreenCover`/`.sheet` equivalents).
   - **next-up episode** (Play label "Continue S2E5"): port `loadNextUpEpisode` 4-tier fallback
     (pure logic); enable/disable the Play pill on `nextUpEpisode != nil`. The SwiftUI
     focus-re-assert hack is unnecessary in the press model (no engine races a disabled button).

---

## 5. Master conversion inventory + prioritized risks

**Biggest risks, in order:**

1. **Focus model for the below-fold (the §0 fork).** Decide focus-driven vs press-driven; it
   dictates the collection, scroll-follows-focus, restoration, and the §2 Menu reconciliation.
2. **Container architecture** — fixed-700 transform-scroll → real collection with variable
   content (§1). `detailsRest=420`/`belowFoldHeight=700` are placeholder-tuned and will break.
3. **Wiring `BelowFoldContentLoader` → real cells (keystone).** Mechanically moderate, gated by #1/#2.
4. **Action-row interactivity + the full 8-button set** (Play/Resume+next-up+resume-dialog,
   Shuffle, Watched+animation+notifications, Trailer, Audio/Subs pickers+persistence,
   Watchlist) + focus-driven pill expansion. Only 4 inert visual buttons exist today.
5. **`displayedItem` in-place swap** (§4.4) — no current UIKit analog.
6. **Sub-item navigation** through the dismiss+push dance; **collection items omitted** from
   the loader (needs Plex sectionId/collectionId plumbing the agnostic API lacks).
7. **Invisible-until-it-breaks state plumbing:** watched-propagation round-trip, season→episode
   crossfade, scroll-to-target episode, spoiler blur (hero + thumbnail), pre-play track
   persistence chaining, the `WatchedCornerTag` visual mismatch, recommendations source drift
   (loader uses `relatedItems`; SwiftUI uses `PersonalizedRecommendationService`).

**Also easy to miss:** hero episode/movie description variants (S2E5 header-split) + hero
spoiler blur; the `belowFoldLoaded` whole-page fade gate; `parentShowLogo/Summary` fallback
for episode/season heroes; `NSUserActivity` Siri indexing; thumbnail prefetch.

**Work-surface files:** `ExpandedDetailContainerView.swift` (host the collection + loader +
focus), `BelowFoldContentLoader.swift` (wire it; add collections), `MediaDetailChromeView.swift`
(action interactivity + episode/movie hero variants + spoiler blur), the `Cells/*` (→ cells,
focus, two-button split, context menus, spoiler blur, watched-tag fix), `PreviewCarouselViewController.swift`
(reconcile focusless modal with below-fold focus; wire action/nav callbacks). Reuse from
`PlexHomeViewController.swift` (compositional layout, supplementaryViewProvider, left-edge
focus guard, context-menu builder) and `PosterCell.swift` (focus coordinator, watched badge).

---

## 6. Implementation sequence (when Plex is back)

1. **Confirm the §0 fork** (focus-driven recommended) + verify the 3 sim checks in §7 with a
   throwaway focusable cell before committing.
2. **Promote cells to `UICollectionViewCell`** + fix the watched-tag (lift `CornerTagBackgroundView`).
3. **Build the below-fold compositional collection** (copy PlexHome), data source, headers —
   render real episodes/cast/related from `BelowFoldContentLoader` (the keystone wire), still
   inside the container, peek→collection swap on expand.
4. **Wire `scrollViewDidScroll` → `driveScrollProgress`**; retire the transform scroll for the
   expanded state; reserve-as-inset.
5. **Focus**: remembersLastFocusedIndexPath, the Up/Down guides, pill-select scroll, the
   didUpdateFocus → season-pill sync, the Menu-gesture-on-ancestor confirmation.
6. **Per-cell effects**: didUpdateFocus scale/border, spoiler blur, context menus, two-button
   episode (decide A/B with user).
7. **Action row interactivity** + the 8-button set + next-up + resume dialog + player present.
8. **State plumbing**: AppStorage KVO, watched propagation, season crossfade, `displayedItem`
   swap, sub-item nav, sheets.
9. **Tune** detailsRest-equivalent / reserve inset / fade timings on-device.

---

## 7. Open questions to verify on the sim (first three gate the §0 fork)

1. **Menu delivery with a focused cell** — does the VC `.menu` gesture still back-step when an
   `EpisodeCell` is focused? (If not → `pressesBegan` override.) **HIGHEST priority.**
2. **Up returns to the hero, not the carousel cells** — focus arbitration between the focusless
   carousel and the focusable below-fold (port PlexHome's left-edge `shouldUpdateFocusIn` guard).
3. **Carousel-stable ↔ expanded focusability flip** — toggling the collection's focusability
   cleanly removes it from the hierarchy in carousel-stable (anchor stays sole target) without
   fighting the morph.
4. **Peek→collection seam** — does the live episodes row land pixel-aligned with the placeholder
   peek so the 0.2s cross-fade reads as one strip? (Else match thumb width during fade, or
   hard-swap on first scroll frame.)
5. **Down-press → focus handoff scroll feel** — does focus into the first cell auto-scroll
   smoothly enough to drive `scrollProgress` without a jump/overshoot past the 158 reserve?
6. **`remembersLastFocusedIndexPath` survives the watched-status `reconfigureItems`.**
7. **`adjustedContentInset` + the 158 reserve** — `contentOffset.y + adjustedContentInset.top`
   = 0 at rest and crosses 158 when the hero finishes fading (`contentInsetAdjustmentBehavior
   = .never`, as PlexHome uses).

---

## Sources

WWDC 2016/210 (Focus Interactions), 215, 216; Apple docs: `UICollectionViewCompositionalLayout`,
`NSCollectionLayoutSection.orthogonalScrollingBehavior`, `boundarySupplementaryItems`,
`UICollectionViewDiffableDataSource.reconfigureItems`, `remembersLastFocusedIndexPath`,
`selectionFollowsFocus`, `UIFocusGuide`/`preferredFocusEnvironments`, `setNeedsFocusUpdate`,
`scrollToItem(at:at:animated:)`, `UIFocusAnimationCoordinator.addCoordinatedAnimations`,
`UIContextMenuConfiguration`/`contextMenuConfigurationForItemsAt`, `UIVisualEffectView`,
`UserDefaults` KVO, `UIView.transition(with:)`, `UIAlertController` (tvOS `.alert` only). In-repo
precedents: `PlexHomeViewController` (compositional layout, scroll-driven parallax, context-menu
builder, focus guards), `PosterCell` (focus coordinator, watched badge), `UIKIT_FOUNDATIONS.md`
§1–§6. Plus the SwiftUI ground truth `MediaDetailView.swift` / `CastMemberCard.swift` /
`MediaPosterCard.swift`.
