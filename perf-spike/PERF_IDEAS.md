# Perf + caching ideas surfaced during the UIKit Home parity work

Running notes. Each item: what I observed, the hypothesis, and a
suggested action. Not prescriptive — discuss before implementing the
bigger ones.

---

## 1. Image cache: 2-tier with explicit downsample on the disk side

**Observation**: `ImageCacheManager.shared.image(for:)` returns the raw
`UIImage` from disk/network. The same decoded image is then assigned to
`UIImageView`s of very different display sizes:
- 260×390 poster cell
- 392×280 Continue Watching cell
- Full-bleed backdrop (1920×1080+)

Plex serves these at the source resolution (often 1000×1500 for posters,
1920×1080 for backdrops). A 1500-px poster decoded into a 260-pt
imageView wastes ~5x the memory of a downsampled version, and CG
re-samples it on every draw.

**Hypothesis**: storing pre-downsampled variants on disk (one per
canonical display size) + decoding into a `CGImageSourceCreateThumbnail`
sized to display dimensions on read would cut per-cell memory ~5-10x
and reduce per-cell decode time. The `imageFullSize(for:)` path used by
the hero backdrop stays on the original.

**Suggested action**: add a `image(for: url, targetSize: CGSize)` API on
`ImageCacheManager`. Variants cached separately. Falls through to a
full-size fetch + downsample. Smoke-test first — Instruments
"Allocations" template will show the savings directly.

---

## 2. PosterCell uses `TVPosterView.image = UIImage` — eager decode

**Observation**: `TVPosterView.image` is a stored `UIImage`. Setting it
triggers immediate decode if the image is JPEG/PNG. On scroll, we
recycle cells, kicking off decodes mid-frame.

**Hypothesis**: prepping a decoded `CGImage` off the main thread (via
`UIGraphicsImageRenderer.image { ... }` to force decode) before
assigning to the imageView would offload that work and avoid scroll
hitches. `ImageCacheManager` may already do this; worth checking.

**Suggested action**: trace one cold-launch with the Time Profiler
filtered to `UIImage`-decode. If `UIImage._decode` shows up on the main
thread during scroll → implement off-main pre-decode. If not, skip.

---

## 3. Cell prefetching

**Observation**: `UICollectionView` has a `UICollectionViewDataSourcePrefetching`
protocol that fires `prefetchItemsAt:` before cells are dequeued. We
don't implement it.

**Hypothesis**: cells N-3..N-1 about to scroll into view could
pre-fetch their images so the cell-display is image-ready instead of
empty → image-fade-in. Particularly noticeable on the orthogonal
scroll inside each row.

**Suggested action**: implement `prefetchItemsAt:` for `PosterCell` /
`ContinueWatchingCell` / `WatchlistPosterCell`. Should kick off the same
`ImageCacheManager.shared.image(for:)` task that `configure` does, but
without binding to a cell.

This is also load-more's natural hook for batch-5 pagination (see
audit 7.10) — combine both.

---

## 4. Hero backdrop: keep upgrading vs. cancel

**Observation**: `HeroBackdropView` cancels the in-flight load when
`currentURL` changes (slide advance). Good. But the **previous image's
`previousImageView`** holds a strong reference for 0.22s + 50ms. Three
quick slide advances = three images held in memory.

**Hypothesis**: in practice the user can't advance fast enough for this
to matter, but worth noting. If we did add a timer-driven hero rotation
later, this would compound.

**Suggested action**: none for now. Document and revisit if a
hero-rotation feature lands.

---

## 5. Diffable snapshot: animatingDifferences = false everywhere

**Observation**: every `applySnapshot` call uses `animatingDifferences: false`.
That's correct on first load + on every published-change tick. But it
means a watchlist add (a single-item delta) snaps in without any animation
where the SwiftUI version uses `withAnimation` implicitly via state
changes.

**Hypothesis**: nice-to-have, low priority. Could `animatingDifferences: true`
for snapshot deltas that come from `watchlistService` changes, leaving
the data-store-refresh path on `false` since those land in bulk.

**Suggested action**: defer until polish phase. Easy to add later.

---

## 6. Recommendations: redundant snapshot apply on toggle

**Observation**: when `enablePersonalizedRecommendations` flips off, my
`observeUserDefaults` zeros `recommendations` then calls `applySnapshot`.
But `computeSections` already excludes the section when the flag is off.
So we're applying a snapshot where the recommendations section
disappears — one Diffable diff pass.

**Hypothesis**: fine, this is what Diffable is designed for. Not a bug.
Just noting that the path runs.

---

## 7. CW cell: `setNeedsLayout` on every configure for progress fill

**Observation**: `ContinueWatchingCell.configure` calls `setNeedsLayout`
and `layoutSubviews` removes/recreates the progress-fill width constraint
every time.

**Hypothesis**: constraint churn is slow vs. just updating a `frame`.
With ~10 visible CW cells, this happens 10x per scroll tick.

**Suggested action**: when I rewrite this cell in batch 1, drop the
constraint dance and just `progressFill.frame.size.width = total * progress`
in `layoutSubviews`. Cleaner + faster.

---

## 8. Hero overlay: shadow / blur layer reuse across cells

**Observation**: `HeroBackdropView` has `CAGradientLayer`s for the scrims
configured once at init. That's correct. But `HeroOverlayCell` (which
holds `HeroOverlayView`) is re-configured on every snapshot apply —
which re-applies the full slide content. The slide swap path is
animated and lazy; good.

No action.

---

## 9. UICollectionView focus engine vs. nested orthogonal scroll

**Observation**: `orthogonalScrollingBehavior = .continuous` per row.
The focus engine has to walk through each row's child collection view
to find a focusable cell. On screens with many rows this becomes
linear in row count for every focus update.

**Hypothesis**: with 5-10 rows it's irrelevant. With 30 rows on the
Library screen it could matter.

**Suggested action**: revisit when Library lands. Probably fine.

---

## 10. Hero `clearLogo` resolution: fetch on every focus

**Observation**: when the hero advances, the new slide's logo is
fetched via `ImageCacheManager.shared.image(for: logoURL)`. First time
for each item, this is a network round-trip.

**Hypothesis**: pre-fetching the logos of items 1..N at the moment the
hero items array is set would warm the cache and make subsequent slide
advances instant.

**Suggested action**: in `HeroOverlayView.configure`, kick off
non-awaited tasks for each item's clearLogo so they populate the
cache while the user is reading the first slide. Cost: N background
network requests once on first hero render. Benefit: zero perceived
latency on hero advance.

---

## 11. Watchlist row builds MediaItems on every tap

**Observation**: `openWatchlistPreview` does `buildWatchlistMediaItems`
which fan-outs 20 GUID-index lookups in parallel. That's actually fast
(GUID index is in-memory) but it still runs every tap.

**Hypothesis**: cache the built `[MediaItem]` until the watchlist
changes.

**Suggested action**: low priority. Caching adds complexity for what's
already a sub-100ms operation. Skip unless we see it in traces.

---

## 12. `applyPendingPreviewRestoreIfNeeded` runs scrollToItem then focus update

**Observation**: returning from preview, we scroll the cell into view
then call `setNeedsFocusUpdate` + `updateFocusIfNeeded`. On a scroll
view that's mid-animation this can clash with in-flight scrolls.

**Hypothesis**: not a perf issue, but a behaviour one — user might see
a small jump.

**Suggested action**: pin scroll first (non-animated, like I already do),
then defer focus update by one runloop. Already done. Verify with
manual testing.
