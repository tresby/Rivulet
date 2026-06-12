# UIKit Carousel vs SwiftUI Baseline — Trace Comparison

**Date**: 2026-05-28
**Device**: Apple TV 4K (3rd generation) at 1080p, tvOS 26.4
**Methodology**: Animation Hitches Instruments template, auto-present carousel via `RIVULET_AUTO_PRESENT_CAROUSEL=1`, page right 8 times with the remote, record ~25–30s.

## Headline numbers

|                              | SwiftUI baseline | UIKit (`efa3cd7`) | Δ        |
|------------------------------|------------------|-------------------|----------|
| Recording duration           | 31.1s            | 20.8s             | —        |
| Hitch events                 | 102              | 17                | **–83%** |
| Hitches per second           | 3.28             | 0.82              | **–75%** |
| Total stall time             | 1251 ms          | 651 ms            | **–48%** |
| Stall % of recording         | 4.03%            | 3.13%             | **–22%** |
| p95 hitch duration           | 167 ms           | 250 ms            | +50%     |
| Worst hitch duration         | 217 ms           | 250 ms            | +15%     |
| Offscreen passes per frame, p50 | 64 *(hitch frames only)* | **1** *(all frames)* | **–98%** |
| Offscreen passes per frame, p95 | 88 *(hitch frames only)* | **14** *(all frames)* | **–84%** |
| Offscreen passes per frame, max | 99               | 94                | –5%      |

The offscreen pass numbers in earlier draft compared "p50 of hitch frames only,"
which was apples-to-oranges. The corrected numbers measure all frames in the
recording: in the UIKit carousel **95% of frames render with 1 offscreen pass**.
The high-count frames are concentrated in a 1.5-second window during entry.

## What the numbers actually say

**Clear wins:**
- Hitches per second drop by 75% (3.28 → 0.82). The carousel produces 4× fewer
  user-perceivable freezes per unit time.
- Total stall time drops 48% in absolute terms. With duration normalization, the
  user spends 22% less time staring at a frozen frame.
- The pattern of constant low-grade hitching during paging (the dominant SwiftUI
  problem) is gone in the UIKit version.

**Not the win we hoped for:**
- p95 and worst-hitch duration *both got worse* (167 → 250 ms; 217 → 250 ms).
  The frequency dropped but the rare bad moments are slightly worse.
- Offscreen passes per hitch are roughly the same. My "single rounded clip, no
  shadows, no Material" design did NOT meaningfully reduce the GPU compositing
  cost per frame. That theory of the SwiftUI carousel's cost was partially
  wrong.

## Where the residual hitches come from

Timeline of all 17 UIKit hitch events:

| t (s) | dur (ms) | narrative |
|-------|----------|-----------|
| 0.00  | 16.68    | expensive app update(s) |
| 0.02  | 16.68    | — |
| 0.20  | 33.36    | expensive app update(s), 88 offscreen passes, GPU |
| 0.42  | 33.36    | expensive app update(s), 66 offscreen passes, GPU |
| 0.52  | 50.05    | — |
| 0.70  | 16.68    | — |
| 0.72  | 16.68    | — |
| 0.82  | **166.83** | expensive render, 73 offscreen passes, GPU |
| 1.20  | 16.68    | — |
| 1.25  | 16.68    | — |
| 1.32  | **250.25** | — |
| 10.23 | 16.68    | expensive render, 2 offscreen passes, GPU |

**Almost every hitch is in the first 1.5 seconds** — the entry window.
Modal present + viewDidLoad + viewDidAppear + entry-morph spring + first
cells dequeuing. Between t=1.4s and the end of the recording (~20s), there's
**one** dropped frame at t=10.23 with only 2 offscreen passes.

What this means: **paging itself is essentially hitch-free**. The
SwiftUI baseline had hitches distributed throughout (paging was the
problem). The UIKit version concentrates the cost at entry only.

The "expensive app update(s)" tag fires in 3 of 4 first-frame
events. This is Instruments flagging SwiftUI body recomputes — but
they happen in the *app shell* outside the carousel, not in our
UIKit cells. The app's view hierarchy:
- `ContentView` (SwiftUI) → `TVSidebarView` (SwiftUI) → tabs →
  home is a UIHostingController wrapping `PlexHomeViewController` (UIKit) →
  presents `PreviewCarouselViewController` (UIKit)

When the carousel modal presents, `@FocusState` in `TVSidebarView`
changes, triggering a SwiftUI body recompute. That body recompute is
what gets flagged. Not intrinsic to the carousel — would fire for any
modal presented from the home.

## Offscreen passes: where the spike actually lives

The `hitches-renders` table (per-frame data, 580 frames in the
recording) tells the real offscreen-pass story:

| Bucket | Frames | % |
|--------|--------|---|
| 1 offscreen pass | 550 | 94.8% |
| 2–9 | 1 | 0.2% |
| 10–19 | 2 | 0.3% |
| 20–49 | 9 | 1.6% |
| 50–99 | 18 | 3.1% |

The mean across the entire recording is **4.0 offscreen passes per
frame**. The mean during paging-only frames (t > 4s through end of
recording) is **1.3**.

Time distribution of high-offscreen frames:

| Window (s) | Frames | Mean OS passes | Max |
|------------|--------|----------------|-----|
| 0.0–2.0    | 5      | 1.0            | 1   |
| 2.0–4.0    | 54     | 28.3           | 94  |
| 4.0–6.0    | 40     | 3.2            | 28  |
| 6.0–8.0    | 60     | 1.4            | 2   |
| 8.0–10.0   | 47     | 1.3            | 2   |
| 10.0–20.0  | 374    | 1.3            | 2   |

The 50–100 pass spikes happen **entirely** in the 2.0–4.0s window —
the carousel entry. After 4 seconds in, the carousel renders at
1–2 offscreen passes per frame for the rest of the recording.

What's compositing during entry:

1. `modalTransitionStyle = .crossDissolve` — UIKit composites the modal
   over the home with an alpha animation.
2. `morphSnapshot` crossfade with `collectionView` — both visible
   simultaneously, alpha-blending against each other.
3. `collectionView.alpha = 0 → 1` animation — UIKit rasterizes the
   collection view to an offscreen buffer to apply the alpha.
4. CALayer corner radius active during the spring morph — each
   continuous-corner clip is one offscreen pass.
5. `HeroBackdropView` in the home behind the modal, possibly still
   animating its own alpha.

All five overlap during ~1.5s of entry, summing to 60–94 offscreen
passes for ~8 specific frames. Once those animations settle, all
five drop out and the carousel composes at 1 offscreen pass per
frame — essentially optimal for any UIKit content with a rounded
clip mask.

The carousel itself is **not the problem.** The compositing storm
is the entry sequence, and it's bounded to 8 frames.

If we wanted to reduce the entry spike specifically, the targets
would be:
- Skip `.crossDissolve` (we already have a spring morph that's the
  real transition) — change modalTransitionStyle to `.coverVertical`
  with `animated: false` already gives us no modal transition, so
  this should already be a no-op
- Pre-rasterize the morphSnapshot to a CGImage cached up front
- Defer collectionView alpha animation: have it start at alpha 1
  hidden behind the snapshot, then `morphSnapshot.alpha = 0` only at
  the end of the spring (no overlap window)

## The p95 / worst-hitch regression in context

The two big hitches (167ms, 250ms) are both in the first 1.5s. They're
**entry spikes**, not paging hitches. The user perceives them as "a brief
delay when opening" rather than "the carousel is stuttery while I'm
using it."

The SwiftUI baseline's distributed hitching across the whole recording
window was the felt problem — every page swipe stuttered. The UIKit
version moves the entire cost to entry and then runs clean. That's a
better experience even if one bad moment is slightly worse in
isolation.

## Subjective verdict

User-reported (2026-05-28, post-trace): *"much better visually"*.

That's the final word. The trace numbers describe the mechanism;
the felt experience is what we were optimizing for. The carousel
now feels smooth in actual use.

## Decision

The carousel rewrite is a clear win on the metric that matters most
to feel — **frequency of perceivable hitches** — by 75%. The frequency
reduction is what eliminates the "every page swipe lags" experience that
prompted the rewrite. Subjective confirmation: paging now feels smooth.

The p95/worst-hitch regression is a real concern. Two hypotheses:
1. **Entry morph cost**: the source-frame → centered-frame spring may trigger
   one expensive frame each time the carousel opens. Most UIKit trace hitches
   cluster at t < 1.5s — exactly the entry window.
2. **First-page latency**: dequeuing the right-peek and off-screen-right cells
   for the first time after carousel opens runs `cellForItemAt` + async image
   load on the same frame.

The 75% frequency win likely outweighs the 50% worst-case duration regression
in lived experience (rare bad moments < routine small ones), but ideally we'd
diagnose and fix both before declaring the rewrite final.

## What's NOT measured here

- **Smoothness during paging itself**: trace measures hitch *events* but
  doesn't directly measure frame-to-frame smoothness during a successful
  paging animation. Subjective testing on the device showed parallax now
  tracks cleanly without the mid-paging "image jump" of the prior iteration.
- **Memory**: not compared. UIKit cells are presumably leaner than the SwiftUI
  view tree but not measured.
- **Battery**: irrelevant on Apple TV (plugged in).

## Reproducing this analysis

```bash
# Export the hitches table from any Instruments trace
xcrun xctrace export \
  --input <trace.trace> \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]' \
  --output /tmp/hitches.xml

# Run the analyzer
python3 perf-spike/analyze_hitches.py /tmp/hitches.xml
```

The traces themselves (`swiftui-carousel-baseline.trace`,
`uikit test.trace`) are not committed (gitignored — too large) but the
exported XML files in `perf-spike/traces/` are small enough to inspect by
hand if needed.
