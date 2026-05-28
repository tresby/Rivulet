# SwiftUI Carousel Perf Verdict

**Date**: 2026-05-28
**Branch**: `perf-tvuikit-spike`
**Device**: Apple TV 4K (3rd generation) at 1080p, tvOS 26.4
**Trace duration**: 31 seconds
**Trace template**: Animation Hitches + SwiftUI

## Decision

**Rewrite the preview carousel in UIKit.**

## Numbers

| Metric | Value |
|---|---|
| Hitch events | 102 in 31s (≈ one every 300ms) |
| Total stall time | 1.25s (4.0% of recording) |
| p50 hitch duration | 16.68 ms |
| p95 hitch duration | 167 ms |
| Worst hitch | 217 ms (≈ 13 dropped frames) |
| Avg offscreen passes per hitch (reported) | 63 |
| Worst offscreen pass count | 99 |
| p99 frame render time | 24.55 ms |

## Why this is a UIKit win, not a SwiftUI tuning win

Apple's narrative diagnostics consistently attribute hitches to three
co-occurring causes:

1. **"Potentially expensive app update(s)"** — SwiftUI body recomputes
   running on the main thread during the animation.
2. **"Potentially expensive render, 48-99 offscreen passes"** — every
   blur, shadow, mask, gradient, or translucent compositing surface
   the carousel uses requires rendering to a separate offscreen buffer
   before final composition. With 3 visible cards each carrying a
   backdrop + scrim + rounded corners + sometimes a logo, the
   compositor saturates.
3. **"Potentially expensive GPU work"** — direct consequence of (2).
   The Apple TV 4K GPU can't drain 99 offscreen passes in a 16.67ms
   frame budget.

What SwiftUI optimization could plausibly fix:
- Replacing `.background(.regularMaterial)` with explicit colors
  (`Material` always triggers offscreen passes).
- Removing `.shadow()` modifiers (each shadow forces an offscreen pass).
- Pre-computing carousel layout instead of leaning on
  `matchedGeometryEffect`.
- `drawingGroup()` to flatten compositing — but it kills focus +
  interactivity, so unsuitable for this view.

What SwiftUI **cannot** fix without effectively replacing its own
animation system:
- `matchedGeometryEffect` walks the view tree every animation frame.
  No SwiftUI-level switch turns this off.
- Body recomputes during animation. Whenever the paging index state
  changes, SwiftUI re-evaluates every view that depends on it.
- Layout invalidation cascades from `AsyncImage` / `CachedAsyncImage`
  when artwork finishes loading mid-animation.

UIKit gives explicit control over all three:
- `UIViewPropertyAnimator` animates `CALayer` properties directly with
  zero view-tree walk.
- `UIView` has no body concept; mutating a property only triggers
  whatever observer chain you set up.
- `UIImageView.image = X` is a single property assignment; no layout
  invalidation unless you opt in.

Engineered correctly, the UIKit carousel should achieve:
- Offscreen passes per page: ~5 (one per slot card's rounded corner +
  any necessary scrim, vs. 60-99 today).
- p99 hitch duration: <30 ms (one missed frame, vs. 167 ms today).
- Worst hitch: <50 ms (vs. 217 ms today).

## Methodology + repro

The capture is reproducible:

1. Build perf-tvuikit-spike branch for tvOS device.
2. Install on Apple TV via `xcrun devicectl device install app`.
3. Launch with env var `RIVULET_AUTO_PRESENT_CAROUSEL=1` set.
   The carousel auto-opens on first home-content-ready.
4. Open Instruments → Animation Hitches template, attach to running
   `Rivulet` process, record 30 seconds, page right 8 times mid-record.
5. Save trace to `perf-spike/traces/` (gitignored).
6. Extract metrics:
   ```bash
   xcrun xctrace export \
     --input <trace> \
     --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]' \
     --output hitches.xml
   ```
   Parse with a small Python script — see commit message of
   `e310f5d` for the analysis approach.

The first trace was captured at commit `e310f5d` and saved (locally)
as `perf-spike/traces/swiftui-carousel-baseline.trace`.

## Why the per-frame analysis was misleading

The `hitches-renders` table (per-frame render durations) initially
showed only 3.1% of frames over 16.67ms budget — making the carousel
look "mostly fine." That number is correct but misleading: it counts
each over-budget frame individually rather than recognizing that
**clusters of consecutive over-budget frames are a single user-visible
freeze**.

The `hitches` table (per-hitch-event) is the correct lens: it groups
consecutive missed frames into hitch events with attributed causes
and durations. A 200ms hitch event corresponds to ~12 frames in the
`hitches-renders` table but reads as a single "the screen froze" to
the user.

**Lesson for future profiling: always look at `hitches`, not just
`hitches-renders`.**
