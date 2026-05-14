# Plex Home: SwiftUI vs UIKit/TVUIKit Perf Spike

Branch: `perf-tvuikit-spike` (off `main`).

## Goal

Measure whether reimplementing `PlexHomeView` in UIKit/TVUIKit delivers
enough perf improvement (memory, launch time, scroll FPS, focus latency)
to justify a broader migration away from SwiftUI for the heaviest
browse surfaces.

## Architecture

Both implementations live in the same app, gated by a runtime toggle:

- `homeImplementation` AppStorage key (default: `swiftui`)
- Settings → Appearance → "Home: UIKit/TVUIKit (perf spike)" flips it
- Or: `defaults write com.gstudios.rivulet homeImplementation -string {swiftui|uikit}`

Both versions:
- Read the same `PlexDataStore.shared`
- Render the same hubs (Continue Watching + Recently Added per home library)
- Load images via the same `ImageCacheManager`
- Emit identically-named signposts under subsystem `com.rivulet.perf`,
  tagged `impl=swiftui|uikit`

UIKit version (`Rivulet/Views/Media/PlexHome/UIKit/`):
- `PlexHomeViewController` — single `UICollectionView` with
  `UICollectionViewCompositionalLayout`, one section per hub,
  `.continuous` orthogonalScrollingBehavior
- `PosterCell` — wraps `TVPosterView` (260x390, native focus motion)
- `ContinueWatchingCell` — wraps `TVCardView` (392x280, image + title +
  progress bar)
- `HubHeaderView` — section header label

Hero is intentionally not yet wired in either UIKit or in the
measurement runs (`showHomeHero=false` is the test posture). Hero is a
known-expensive piece of the SwiftUI version; including it would make
the SwiftUI side look worse without proving the row-rendering hypothesis.

## Running the comparison

```bash
# Pre-reqs: simulator booted, app installed, signed into Plex
SIM_UDID=B7CDD74D-BA0C-4CDB-8038-8D6FCAB7764F bash Scripts/perf_compare.sh uikit 10
SIM_UDID=B7CDD74D-BA0C-4CDB-8038-8D6FCAB7764F bash Scripts/perf_compare.sh swiftui 10
cat perf_results.csv
```

Output columns:
- `impl` — swiftui or uikit
- `trial` — 1..N
- `launch_to_first_frame_ms` — wall time from `xcrun simctl launch` to
  the first `[Perf:HomeFirstFrameOnScreen]` log line. Both impls fire
  this from a comparable point: SwiftUI from the
  `.task(id: "perf-first-frame")` on contentView (which only runs once
  data is loaded), UIKit from `viewDidAppear` (which fires after the
  collection view has laid out).
- `rss_at_5s_mb` — resident set size 5 seconds after launch
- `rss_at_30s_mb` — RSS at 30 seconds (steady state, idle)

## Findings

### Real device — Apple TV 4K (3rd gen), Master Bedroom (n≥4 each)

See `device_n5_initial.csv`. Numbers are medians.

| Metric | SwiftUI | UIKit | Δ |
|---|---|---|---|
| Launch → first frame (ms) | 67 | 26 | **UIKit 60% faster** |
| RSS @ 5s (MB) | 57.38 | 54.42 | UIKit 5% lower |
| RSS @ 30s (MB) | 73.83 | 53.47 | **UIKit 28% lower** |
| First-5s hitch ms total | 1523 | 530 | **UIKit 65% lower** |
| First-5s hitch count | 19 | 10 | **UIKit 47% fewer** |

**Decisive in favor of UIKit on every meaningful metric.** Per the
perf-agent threshold (median delta > 2x stddev AND > 15%), all
metrics except the 5s RSS snapshot (where SwiftUI hadn't stabilized)
clear the bar.

The hitch delta is the most user-perceptible: 1.5 seconds of frame
time lost to hitches in the first 5 seconds for SwiftUI vs 0.5
seconds for UIKit. This is what users feel as "the home screen
stutters on launch."

The launch number is somewhat noisy because of warm-vs-cold
SpringBoard state (cold-cold gives ~800ms, warm reuses cached views
and gives ~30-70ms). What's consistent: UIKit is always equal-or-
faster, never slower.

### Simulator (n=5, comparison baseline)

See `n5_with_hitches_simulator.csv`. Numbers are medians.

| Metric | SwiftUI | UIKit | Δ |
|---|---|---|---|
| Launch → first frame (ms) | 1094 | 945 | UIKit 14% faster |
| RSS @ 5s (MB) | 103.03 | 76.72 | UIKit 26% lower |
| RSS @ 30s (MB) | 103.07 | 76.02 | UIKit 26% lower |
| First-5s hitch ms | 710 | 188 | UIKit 73% lower |
| First-5s hitches | 12 | 5 | UIKit 58% fewer |

Real device confirms the simulator's directional findings and shows
the deltas are NOT a simulator artefact. Memory delta is similar;
hitch delta is even more dramatic on real hardware.

## Verdict

**Migrate.** The numbers justify it.

UIKit/TVUIKit delivers:
- ~28% lower memory at steady state (~20 MB saved)
- ~65% lower frame-hitch time during launch (1 second of "smoothness"
  per launch)
- ~47% fewer hitches in the first 5 seconds

Costs (not measured here, but worth flagging):
- Multi-week migration of MediaDetailView, library views, discover,
  preview overlay, etc.
- Some SwiftUI conveniences lost (declarative layout, easy
  animations, `@Observable`/`@AppStorage` ergonomics)
- TVUIKit is publicly thin — much of the work is plain UIKit + custom
  cells

Recommended migration path:
1. Episode card row (the original blocker on PR #127) — small,
   contained, validates the pattern in production code
2. Plex Home — bigger but the highest-traffic surface and where this
   spike's measurements apply directly
3. PlexLibrary grid — same compositional layout pattern
4. MediaDetailView — most complex; tackle last after the others
   prove out the patterns and the team has built UIKit muscle

SwiftUI stays for: Settings, Player overlays, smaller leaf views
that don't have focus-heavy carousels or large lists.

Caveats:
- **Simulator only.** Per agent guidance, simulator perf is 5-15x faster
  than physical Apple TV 4K (3rd gen). Directionality (UIKit lower) is
  expected to hold; magnitudes likely amplify on real hardware.
- **n=5.** Below the n=10-20 threshold the perf agent recommended for
  defensible numbers. Doing more trials before final write-up.
- **Hero off in both.** UIKit version has no hero; SwiftUI defaults to
  `showHomeHero=false`. Both fair, but if the user typically runs with
  hero on, the SwiftUI cost is under-represented.
- **No scroll measurement yet.** Cold-launch and idle memory are
  captured, but scroll FPS / hitch ratio require Instruments
  (Animation Hitches template). To be done on physical Apple TV.
- **No focus latency yet.** Same — needs device + Instruments.

## Next steps

1. Run on physical Apple TV (master bedroom). Same script works once a
   matching SIM_UDID equivalent (device id) is set up.
2. Capture Instruments Animation Hitches traces under scroll.
3. Add hero to UIKit version OR run both with hero on, for the more
   complete comparison.
4. Increase n to 10+ for both impls.
5. Write final recommendation doc with numbers + verdict.

## Files

```
perf-spike/
  README.md                    — this file
  initial_simulator_n5.csv     — first n=5 simulator run
Scripts/
  perf_compare.sh              — driver script
Rivulet/Services/Perf/
  PerfSignpost.swift           — shared signpost helpers
Rivulet/Views/Media/PlexHome/
  HomeImplPreference.swift     — AppStorage key
  PlexHomeRoot.swift           — SwiftUI router (swaps SwiftUI vs UIKit)
  PlexHomeUIKitBridge.swift    — UIViewControllerRepresentable
  UIKit/
    PlexHomeViewController.swift — controller + compositional layout
    PosterCell.swift             — TVPosterView wrapper
    ContinueWatchingCell.swift   — TVCardView wrapper
    HeroCell.swift               — placeholder, not wired
    HubHeaderView.swift          — section header
```
