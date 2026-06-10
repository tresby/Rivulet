# Cold-Launch Startup Analysis (2026-06-10)

Device-measured investigation of the "app appears → 30+ seconds → content"
cold launch on Apple TV, run after the UIKit home/library migration. This doc
is the synthesis of instrumented device timelines (`StartupTimer`, the
`[Startup +Nms]` console lines) plus a four-track code investigation
(launch-path inventory, render-cost inventory, double-build mechanism,
data-layer isolation audit).

## Why the UIKit pivot "caused" this

It didn't — it un-hid it. The data layer was always slow (main-actor JSON
decode, redundant refresh signals, a 20MB launch fetch), but the SwiftUI home
rendered lazily and asynchronously and the splash screen absorbed the rest.
The UIKit home does full synchronous `applySnapshot` rebuilds on every data
signal, so the same pre-existing debt now lands as visible main-thread
stalls. Migration lesson: when you move a surface from SwiftUI to UIKit you
also take ownership of the coalescing/laziness SwiftUI was doing for free.

## Root causes (all device-measured, debug build)

| # | Cause | Measured cost | Status |
|---|-------|---------------|--------|
| 1 | Splash dismissal signal (`isHomeContentReady`) was only ever set by the retired SwiftUI home → every launch rode the 15s safety timeout | 15s, every launch | FIXED `e68eb58` |
| 2 | `refreshHubs()` (cache-CLEARING) ran at launch from the home VC while the sidebar ran cache-first `loadHubsIfNeeded()` — the clears queued 7–17.5s behind image-cache IO on the CacheManager actor, twice, and defeated the instant cache paint | 7–17.5s ×2 | FIXED `d7d2c94` (launch is cache-first `loadXIfNeeded` only) |
| 3 | plex.tv `/api/v2/home/users` (profile switcher data, never needed for home content) raced the critical path | up to 18.5s wall | FIXED `4494fdf` (deferred 3s, fire-and-forget) |
| 4 | **JSON decode pinned to the main actor.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes `PlexNetworkManager` *and every model's `Decodable` conformance* main-actor-isolated. `Task.detached` callers were silently defeated — the decode hopped right back to main. Debug-build Codable is 5–20× slower, so /hubs (395KB) and especially the GUID index (~5MB × 4 libraries) produced the recurring 10–18s main-thread clogs. The "SLOW net" lines were largely *waiting to resume onto a clogged main actor*, not network. | 10–18s clogs | FIXED `19e7fdc` (`decodeDetached` + the whole Plex model layer marked `nonisolated`) |
| 5 | `applySnapshot` burst: 4–6 launch signals (cache paint, network refresh, CW hub, watchlist, hero) each triggered a full synchronous rebuild at 1.9–3.5s per call (40–60 cells realized per apply: TVUIKit views + a UIVisualEffectView blur band per cell, orthogonal prefetch realizing ~2× visible) | 1.9–3.5s × 4–6 | PARTIALLY FIXED `19e7fdc` (observer-driven applies coalesced to one per runloop turn); per-apply cost itself shrinks a lot once decode is off main; further options below |
| 6 | Home VC builds **twice** at launch (~950ms apart), and the scroll `CADisplayLink` retained the VC strongly with no `deinit` — a discarded instance #1 could leak and keep applying snapshots forever | 2× everything | MITIGATED `19e7fdc` (weak `DisplayLinkProxy`, `deinit` diagnostic). Structural cause still open — see below |
| 7 | GUID index: ~20MB fetched + decoded **every** launch, no persistence | ~20MB + decode | MITIGATED `19e7fdc` (deferred 20s past launch). Proper fix queued: persist to disk with TTL |

Pre-content overhead (0→6s before anything renders): SwiftData
ModelContainer creation, 4 Keychain reads in PlexAuthManager init, singleton
init chain, debug/dyld overhead. Sub-second each in Release; not currently
the priority. Sentry swizzling is `#if !DEBUG` so it costs release launches
~50–200ms.

## Target architecture (the "how it should work")

Cold launch golden path, in order, nothing else allowed on it:

1. **Paint cached content immediately** (< 1s): `loadHubsIfNeeded()` reads the
   disk cache on the CacheManager actor and paints. No clears, no network
   gate, no profile fetch, no index build.
2. **One snapshot apply per data burst** (`setNeedsSnapshotApply`).
3. **Background refresh diffs in** when the network answers (~1.3s on LAN).
4. **Everything else is deferred and off-main**: profile list (+3s), GUID
   index (+20s, eventually disk-cached), library prefetch, recommendations,
   TMDB upgrades.
5. **Decode never touches the main actor.** Rule going forward: payload
   models are `nonisolated` structs; any new endpoint goes through
   `request<T: Decodable & Sendable>` and inherits off-main decode.

## Open follow-ups, in priority order

1. **Double-build structural fix.** The next device log shows whether
   `PlexHomeVC deinit` fires for instance #1. If it deallocs: the remaining
   cost is one wasted build (~moderate); find the SwiftUI identity flip in
   `TVSidebarView.tabContent` (the `if isAwaitingProfileSelection` /
   `if authManager.hasCredentials` structural branches are the suspects) and
   stabilize it (overlay instead of branch-swap). If it does NOT dealloc:
   hunt the remaining retain (long-running Tasks).
2. **GUID index disk persistence** (TTL ~24h) — kills the recurring 20MB
   refetch entirely; also consider slimming the fetch.
3. **Lazy `BottomInfoBlurView`** — create the UIVisualEffectView only when a
   cell actually shows it (poster cells: only in-progress items). ~40–60
   blur views per apply today.
4. **TMDB payload structs** (`TMDBImagesResponse` etc.) have the same
   isolated-conformance issue (currently warnings) — same `nonisolated`
   treatment when touched.
5. **Measure a Release build / detached launch** once the above land — a
   chunk of the residual is debug-only amplification (Codable 5–20×, no
   optimization). The shipping number is what matters.

## Instrumentation kept in-tree

- `StartupTimer` (`Services/Perf/StartupTimer.swift`): `[Startup +Nms]`
  console lines; `mark`/`measure`; `SLOW net` lines for any request > 750ms
  in the two generic PlexNetworkManager methods.
- `applySnapshot` logs compute/apply split when > 200ms.
- `bridge.makeUIViewController` + `PlexHomeVC.viewDidLoad`/`deinit` marks
  expose instance lifecycle.

These are cheap and worth keeping until launch is verified < 2s on device.
