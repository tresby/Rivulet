# UIKit Plex Home: line-by-line audit vs SwiftUI source

Working doc. SwiftUI is the source of truth; UIKit must match. Each entry
cites the SwiftUI file/line that's authoritative.

Severity:
- **Bug** = visible/functional discrepancy users notice
- **Cosmetic** = subtle visual delta (off by a few pt, slightly wrong colour)
- **Acceptable** = intentional UIKit-side deviation, documented

---

## 1. Hero composition

### 1.1 Backdrop layer

`Rivulet/Views/Media/Hero/HeroBackdropLayer.swift`

SwiftUI uses three layers behind the image:
- Image with `HeroBackdropImage` (full-bleed, scaleAspectFill)
- Horizontal scrim: `0.88 → 0.55 → 0.08 → clear` at stops `0 / 0.28 / 0.55 / 0.7`
- Vertical scrim: `clear → 0.15 → 0.85` at stops `0 / 0.55 / 1`

`Rivulet/Views/Media/PlexHome/UIKit/HeroBackdropView.swift`

UIKit matches all three (verified by re-reading current file). **Match.**

### 1.2 Scroll parallax

SwiftUI: `.offset(y: -heroScrollOffset * 1.3 - min(72, heroScrollOffset * 0.72))`
(`PlexHomeView.swift:679`)

UIKit: same formula in `HeroBackdropView.applyScrollOffset`. **Match.**

### 1.3 Hero section height

SwiftUI: `heroSectionHeight = UIScreen.main.bounds.height - 200`
(`PlexHomeView.swift:660`, `HeroOverlayContent.swift:64`)

UIKit: `height = max(400, UIScreen.main.bounds.height - 200)`
(`PlexHomeViewController.swift:321`)

**Match** (the `max(400, …)` floor is defensive; never reached on real devices).

### 1.4 Hero overlay positioning

SwiftUI HeroOverlayContent layout (`HeroOverlayContent.swift:66-115`):
- ZStack with bottom alignment
- VStack contents: `Spacer()` then `VStack(spacing: 28)` with logo+meta + button row
- Whole inner VStack `.padding(.leading, 120)`
- Trailing `Spacer().frame(height: 120)` reserves space for the dots
- Dots pinned bottom-center via the ZStack alignment, `.padding(.bottom, 24)`

UIKit (`HeroOverlayView.swift:97-117`):
- Slide pinned `leading: 120`, no trailing constraint (uses `lessThanOrEqual`)
- Button row pinned `leading: 120`, `bottom: -144`, top 28pt below slide
- Dots centred X, `bottom: -24`

**Bug 1.4.a — Slide & buttons collapse to bottom without a Spacer.**
SwiftUI has `Spacer(minLength: 0)` above the VStack, so the slide+buttons
are pushed to the bottom of the available height. My UIKit pins the
button row at `bottom: -144` and stacks the slide on top via
`slideView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor - 28)`.
But my current constraint is `buttonRow.topAnchor.constraint(equalTo: slideView.bottomAnchor, constant: 28)`,
which pushes the slide *up* from button row. The slide will end up wherever
its top anchor lets it. **I have no `slideView.topAnchor` constraint that
holds it in place — it's only anchored to its leading anchor.** That means
the slide may float to wherever the stack view's intrinsic content wants.

Look closer: `HeroSlideView.setUp` creates an internal `stack` pinned
top/bottom of the slide view. So the slide view *as a UIView* has no
top anchor inside HeroOverlayView. Without that, the slide is unconstrained
vertically and Auto Layout could put it anywhere (likely at the top).

**Fix**: anchor `slideView.bottomAnchor` to `buttonRow.topAnchor - 28` and
let the slide grow upward. The trailing `Spacer.height(120)` in SwiftUI
maps to the gap between buttonRow and the dots; my `bottom: -144` already
covers that (24 for dot baseline + 80 for the dots pill + slack).

Actually, even simpler: only anchor the **bottom** of slideView to the
**top** of buttonRow with 28pt spacing. Don't pin slideView's top. That
mirrors the SwiftUI "VStack pushed to bottom by Spacer" intent.

### 1.5 Slide content

SwiftUI HeroSlideContent (`HeroSlideContent.swift:55-69`):
- VStack(alignment: .leading, spacing: 14)
  - titleView (logo or fallback)
  - metadataRow (HStack: type · genre · contentRatingBadge)
  - taglineLabel
  - `.padding(.top, 4)` on tagline only

UIKit HeroSlideView: stack spacing 14, same children, no extra top padding
on tagline. **Cosmetic 1.5.a — missing 4pt extra top padding on tagline.**
Minor.

### 1.6 Logo size

SwiftUI: `.frame(maxWidth: 520, maxHeight: 180, alignment: .leading)` on
the logo image. Logo has `.aspectRatio(contentMode: .fit)`.
(`HeroSlideContent.swift:78-88`)

UIKit: `logoImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 180)`
+ `widthAnchor.constraint(lessThanOrEqualToConstant: 520)` +
`contentMode = .scaleAspectFit`.

**Match.** (Note: SwiftUI also adds `.frame(maxHeight: 180, alignment: .leading)`
outside the CachedAsyncImage which I don't strictly mirror — but the inner
maxHeight covers it.)

### 1.7 Fallback title

SwiftUI: `.font(.system(size: 72, weight: .heavy, design: .serif))`
(`HeroSlideContent.swift:97`)

UIKit: `.systemFont(ofSize: 72, weight: .heavy)` — **missing
`design: .serif`. Bug 1.7.a** — should use `UIFont.systemFont` with
`.serif` design via `UIFontDescriptor`.

### 1.8 Metadata row

SwiftUI (`HeroSlideContent.swift:102-121`):
- HStack(spacing: 12)
  - `metaLine` text, `.system(size: 20, weight: .medium)`, foreground white-0.9
  - if contentRating: `Text(rating)` with `.system(size: 16, weight: .semibold)`,
    `.padding(.horizontal, 10)`, `.padding(.vertical, 3)`, white-0.5 stroke,
    cornerRadius 4, white-0.9 foreground

UIKit: HeroSlideView builds the same. Verified pixel-for-pixel.
**Match.**

### 1.9 Tagline

SwiftUI: `.font(.system(size: 22, weight: .regular))`, foreground
`white.opacity(0.85)`, `lineLimit(2)`, `frame(maxWidth: 720, alignment: .leading)`,
`.padding(.top, 4)`.

UIKit: matches except missing the `.padding(.top, 4)` (see 1.5).
**Cosmetic.**

### 1.10 Button row

SwiftUI (`HeroButtonRow.swift`):
- HStack(spacing: 16)
- Play: pill, height 66, `padding(.horizontal, 32)`, `HStack(spacing: 10)` of
  icon + "Play" text, font `.system(size: 22, weight: .semibold)`,
  cornerRadius `pillButtonHeight / 2` = 33, primary style
- Watchlist / Info / Next: 66×66 circle buttons, icon `.system(size: 24, weight: .semibold)`,
  cornerRadius 33, **secondary** style (`isPrimary: false`)

`AppStoreActionButtonStyle` (`GlassRowStyle.swift:45-74`):
- foregroundStyle: focused→.black, unfocused→.white
- background fill: focused→.white; unfocused primary→white-0.2;
  unfocused secondary→white-0.12
- second background (only when unfocused): `.ultraThinMaterial`
- overlay stroke when unfocused: white-0.2 0.5pt; focused: clear
- `.scaleEffect(1.08)` on focus, `.scaleEffect(0.95)` on press
- spring(response 0.25, damping 0.8) for focus
- spring(response 0.15, damping 0.9) for press

UIKit HeroPillButton + HeroCircleButton: implements all of the above.
Verified line-by-line. **Match.**

**Bug 1.10.a — `.ultraThinMaterial` replaced with `black.alpha(0.25)`.**
The comment in my code calls this "more faithful on tvOS over Plex
backdrops". That was a judgment call I made; the task brief is
explicit that I match SwiftUI exactly. SwiftUI ships
`.ultraThinMaterial` and the user gets whatever tvOS does with it. I
should use `UIVisualEffectView(effect: UIBlurEffect(style: ...))` with
a tvOS-supported style and let it be tvOS's interpretation. The closest
available on tvOS is `.regular` or `.systemThinMaterialDark` (tvOS 13+).

### 1.11 Paging dots

SwiftUI (`HeroOverlayContent.swift:146-155`):
- HStack(spacing: 10) of Capsules
- Active: width 22, height 8, opacity 1.0
- Inactive: width 8, height 8, opacity 0.35
- animation `.easeInOut(duration: 0.25)`

Container around dots (`:103-113`):
- padding `horizontal: 14`, `vertical: 8`
- `RoundedRectangle(cornerRadius: 12)` with `Color.black.opacity(0.35)`
- `.padding(.bottom, 24)`

UIKit: HeroPagingDotsView + pagingDotsBackground match exactly.
**Match.**

### 1.12 Slide-swap delay

SwiftUI: `slideSwapDelay = .milliseconds(100)` (`HeroOverlayContent.swift:42`).
On `currentIndex` change, sleeps 100ms then `withAnimation(.easeInOut(duration: 0.22))`
sets `displayedIndex = newIndex`.

UIKit: `setCurrentIndex` schedules a `DispatchWorkItem` 100ms out,
then `renderSlide(animated: true)` which does a 0.22s fade-in.

**Bug 1.12.a — UIKit fades from alpha 0, but SwiftUI uses `.transition(.opacity)`
on the inner `HeroSlideContent` which is symmetric (old fades out as
new fades in via the `.id()` change).** My UIKit version just fades the
new content in — there's no fade-out of the old. Visually: the old
content snaps away as the new content appears with a fade-in. Subtle but
wrong. Fix is to fade old out then fade new in, or use a quick
crossfade (snapshot + crossfade).

### 1.13 Hero focus → scroll behavior

SwiftUI: on focus, calls `onHeroFocused` which does
`scrollProxy.scrollTo("homeHero", anchor: .top)` with
`.smooth(duration: 0.8)` (`PlexHomeView.swift:703-707`).

UIKit: `onFocusEntered` → `scrollHeroIntoView()` sets contentOffset to
top with a 0.8s `easeInOut` animation. **Match.**

### 1.14 Play resolve

SwiftUI HeroOverlayContent.handlePlay (`HeroOverlayContent.swift:168-196`):
- `resolvedPlayTargets[key]` cache, fast path for movie/episode types,
  otherwise `HeroPlaySession.resolvePlaybackTarget`

UIKit HeroOverlayView.handlePlay: identical logic. **Match.**

### 1.15 Watchlist toggle

SwiftUI: `toggleWatchlist`, `resolvedForWatchlist`, watch type derivation,
poster URL construction (`HeroOverlayContent.swift:200-230`).

UIKit: identical. **Match.**

### 1.16 Watchlist bookmark icon refresh

SwiftUI: `resolvedForWatchlistCache` + `resolvedTmdbId` resolve, then
`isOnWatchlist = ... watchlistService.contains(tmdbId: $0)` (via
`@ObservedObject watchlistService`). SwiftUI auto-refreshes on
`watchlistItems` change.

UIKit: subscribes to `watchlistService.$watchlistGUIDs` and calls
`updateButtonStateForCurrentItem` on each fire. **Match.**

---

## 2. Continue Watching row

### 2.1 Tile size

SwiftUI: `ScaledDimensions.continueWatchingWidth = 392`, `continueWatchingHeight = 280`.
UIKit: same constants. **Match.**

### 2.2 Tile composition (`ContinueWatchingCard.swift:33-65`)

SwiftUI:
- ZStack:
  - artwork (CachedAsyncImage, scaleAspectFill, .clipped(), background dark grey
    placeholder while loading, failure → gradient with `film` or `play.rectangle` icon)
  - bottom gradient: stops `clear@0.3, black-0.7@0.7, black-0.85@1.0`, top→bottom
  - centered title logo (`ContinueWatchingTitleLogo` — fetches clearLogo,
    falls back to centered title text)
  - bottom info bar (HStack)
- `.frame(width: 392, height: 280)`
- `.clipShape(RoundedRectangle(cornerRadius: 16, .continuous))`
- `.hoverEffect(.highlight)`
- `.shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)`

UIKit ContinueWatchingCell:
- TVCardView wrapper (not ZStack)
- imageView (scaleAspectFill, dark grey background)
- titleLabel pinned bottom-leading (not center)
- progressBackground (4pt tall, full-width, black.alpha(0.5))
- progressFill (UIColor.systemBlue)

**Bug 2.2.a — UIKit is missing the centered title logo (`ContinueWatchingTitleLogo`).**
The SwiftUI card has a clearLogo centered on the card; if no logo, it falls
back to centered title text. My UIKit version has a `titleLabel` pinned
bottom-leading instead — visually very different.

**Bug 2.2.b — UIKit is missing the bottom gradient overlay** (clear → 0.7 black → 0.85 black).
This makes the title legible against bright backdrops; without it, text
on light images is unreadable.

**Bug 2.2.c — UIKit is missing the bottom info bar.**
SwiftUI shows: `play.fill` icon + (optional) progress bar capsule (44pt
wide, 4pt tall) + "S1, E2 • 35m" or "1h 7m" info text. My version has
NO info bar — just a thin systemBlue progress strip at the very bottom.

**Bug 2.2.d — Progress bar is wrong shape and colour.**
SwiftUI: a small 44pt-wide capsule inside the info bar, white-on-white-0.3.
UIKit: a 4pt-tall full-width bar at the very bottom, systemBlue.
Completely different.

**Bug 2.2.e — UIKit has no `.hoverEffect(.highlight)` equivalent.**
TVCardView may give some focus glow natively, but it's not 1:1 with
SwiftUI's hoverEffect. The shadow boost on focus is also absent.

**Bug 2.2.f — UIKit missing drop shadow.**
`shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)` on the
card. UIKit ContinueWatchingCell has no `layer.shadow*` configuration.

**Bug 2.2.g — corner radius**: SwiftUI clips to rounded 16. TVCardView
probably has its own corner radius — needs verification.

### 2.3 Title logo behavior (`ContinueWatchingCard.swift:182-300`)

SwiftUI: fetches `clearLogo` for the show/movie:
- If episode, walk grandparent → fetch full metadata if not cached
- Otherwise fetch own full metadata
- Resolved URL goes through ImageCacheManager
- 18000 pt² target area, max 75% card width, 45% card height
- Logo aspect ratio preserved, `aspectRatio(contentMode: .fit)`
- Logo has `.shadow(color: .black.opacity(0.6), radius: 4, y: 2)`
- 0.22s ease-in-out reveal animation

UIKit: **completely missing**. This is a substantial visual feature.

### 2.4 Info text format

SwiftUI infoText (`ContinueWatchingCard.swift:140-156`):
- Episodes: "S\(parentIndex), E\(index) • \(remaining-or-duration)"
- Movies: just remaining-or-duration ("35m left" or "1h 7m")
- Uses `item.remainingTimeFormatted` or `item.durationFormatted`

UIKit: titleLabel just shows the title. **No info text.**

### 2.5 Watch-progress logic

SwiftUI uses `item.watchProgress` (computed property on PlexMetadata).
Shows progress capsule only when `0 < progress < 1`.

UIKit uses `viewOffset/duration` directly — equivalent computation, but
shows the bar in any case where `progress > 0`. Includes fully-watched
items (progress=1). **Cosmetic bug — should hide when progress == 1.**

---

## 3. MediaPosterCard (the regular poster)

### 3.1 Frame + clip + shadow

SwiftUI (`MediaPosterCard.swift:86-98`):
- `.frame(width: 260, height: 390)` (video; 260×260 for music)
- `.clipShape(RoundedRectangle(cornerRadius: 16, .continuous))`
- `.hoverEffect(.highlight)`
- `.shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)`

UIKit PosterCell: TVPosterView wrapper, no title/subtitle (correctly).
Built-in TVPosterView focus effects. **Match-ish** but TVPosterView's
focus motion (parallax tilt, glow) isn't 1:1 with SwiftUI's
hoverEffect — which is a focus glow only. Acceptable, this is the
documented "Apple-native focus motion" trade-off.

**Bug 3.1.a — UIKit has no explicit drop shadow.**
TVPosterView may render its own shadow on focus, but it doesn't match
the unfocused `0.35 opacity, radius 8, y 6` shadow SwiftUI has.

### 3.2 Image fill

SwiftUI: CachedAsyncImage with `aspectRatio(contentMode: .fill)`.
UIKit: TVPosterView with image. **Match-ish** (caption=nil fix from
previous commit resolved the aspect issue).

### 3.3 Watched indicators

SwiftUI (`MediaPosterCard.swift:180-211`):
- TV show with `leafCount > 0` and `unwatched > 0`: blue capsule with
  unwatched count, top-trailing, 10pt padding
- TV show with full viewedLeafCount: `WatchedCornerTag`
- Movie/episode with `isFullyWatched`: `WatchedCornerTag`
- Audio items: nothing

UIKit PosterCell: **completely missing**. No unwatched count badge,
no watched corner tag.

### 3.4 In-progress indicator (`MediaPosterCard.swift:147-175`)

SwiftUI: progress bar at the bottom of the poster when `0 < watchProgress < 1`:
- VStack with bottom-aligned overlay
- 6pt-tall Capsule with three layers (dark backing, blurred glow, sharp core)
- horizontal padding 8, bottom padding 1

UIKit PosterCell: **completely missing**.

### 3.5 Episode poster source

SwiftUI: `item.grandparentThumb ?? item.parentThumb ?? item.thumb` for episodes.
UIKit: same. **Match.**

### 3.6 Failure / empty state

SwiftUI failure state: dark gradient + system-icon overlay matching item type
(film, tv, number.square, play.rectangle, etc.).
UIKit: PosterCell shows nothing on failure (TVPosterView blank).

**Cosmetic 3.6.a** — relatively minor since image loads usually succeed,
but a blank tile in the row is more jarring than an icon stub.

---

## 4. Watchlist row

### 4.1 Header

SwiftUI (`WatchlistHubRow.swift:41-43`):
- "Watchlist" — `.font(.system(size: ScaledDimensions.sectionTitleSize, weight: .bold))`
  = 28pt × scale
- `.padding(.horizontal, ScaledDimensions.rowHorizontalPadding)` = 48pt

UIKit HubHeaderView: `30pt weight: .bold`, leading 48pt. **Bug 4.1.a:
font size is 30 vs SwiftUI's 28.** Off by 2pt.

### 4.2 Spacing

SwiftUI (`WatchlistHubRow.swift:46`): `LazyHStack(spacing: ScaledDimensions.rowItemSpacing * scale)` = 40pt.
SwiftUI (`WatchlistHubRow.swift:58-59`): `.padding(.horizontal, 48)`, `.padding(.vertical, 32)`.
SwiftUI VStack spacing 16 between title and scroll row.

UIKit hub section layout (`PlexHomeViewController.swift:340-355`):
- `interGroupSpacing = 40` ✓
- `contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 48, bottom: 32, trailing: 48)`
  - Top 16 vs SwiftUI 32 — **Bug 4.2.a, off by 16pt**
  - bottom 32 ✓
  - leading/trailing 48 ✓
- header height 60pt — SwiftUI doesn't enforce a header height, lets it
  size to content. **Cosmetic 4.2.b — extra space below title vs SwiftUI.**

### 4.3 Tile

SwiftUI WatchlistTile (`WatchlistHubRow.swift:237-290`):
- `.frame(width: 260, height: 390)`
- `.clipShape(RoundedRectangle(cornerRadius: 16, .continuous))`
- `.hoverEffect(.highlight)`
- `.shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)`
- Placeholder when no posterURL: dark gradient + `film` or `tv` SF symbol,
  32pt light weight, white-0.3
- Failure: same placeholder

UIKit WatchlistPosterCell: TVPosterView, title/subtitle nil (after fix).
**Bug 4.3.a — no placeholder** for missing poster. Just blank.
**Bug 4.3.b — no drop shadow** (same as PosterCell 3.1.a).

---

## 5. Recently Added / Personalized Recommendations rows (InfiniteContentRow)

`PlexHomeView.swift:1248-1395`

### 5.1 Title

SwiftUI:
- HStack(spacing: 12):
  - `Text(title).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white.opacity(0.6))`
  - if totalSize > items.count: "\(items.count) of \(total)" with `size: 17, weight: .medium, white.opacity(0.3)`
  - else if hasReachedEnd && items.count > pageSize: "All \(items.count)"

UIKit HubHeaderView: `.systemFont(ofSize: 30, weight: .bold)`, `.white`.
**Bug 5.1.a — weight is `.bold` instead of `.semibold`.**
**Bug 5.1.b — colour is solid white instead of `white.opacity(0.6)`.**
**Bug 5.1.c — missing "X of Y" / "All Z" count indicator.**

Note this conflicts with 4.1: Watchlist row uses `ScaledDimensions.sectionTitleSize`
(28) with `.bold` and full white. InfiniteContentRow uses `30, semibold, white-0.6`.
The two header styles **differ between watchlist and regular hubs in SwiftUI**.
My UIKit version uses ONE HubHeaderView for everything → can't match both.
**Architectural bug — need two header styles.**

### 5.2 Row spacing + padding

SwiftUI:
- ScrollView with LazyHStack `spacing: ScaledDimensions.rowItemSpacing * scale` = 40pt
- `.padding(.horizontal, 48)`, `.padding(.vertical, 32)`
- Outer VStack `spacing: 0` between title and scroll
- Surrounding VStack between rows: `spacing: 48`

UIKit:
- Group spacing 40 ✓
- Section content insets top 16, bottom 32 — top should be **0** since
  the title section in SwiftUI has its own 16pt-bottom-padding to the row.
  Actually, looking again — SwiftUI has `VStack(spacing: 0)` containing
  title with no padding then scroll with vertical 32. So there's no
  top padding above the title and 32pt below the title (before the
  first poster). Between sections (`VStack(alignment: .leading, spacing: 48)`
  in PlexHomeView) there's 48pt.
- Header is 60pt tall and absolute — **doesn't account for the title's
  natural intrinsic height (≈37pt for size 30 semibold).** 60pt is
  ~23pt too much.

### 5.3 Card type

SwiftUI: `MediaPosterCard` for non-CW rows, `ContinueWatchingCard` for CW.
UIKit: `PosterCell` for non-CW, `ContinueWatchingCell` for CW. Maps correctly.

### 5.4 Loading indicator at row end

SwiftUI: when `isLoadingMore`, shows a skeleton-poster card matching the
current row's card dimensions (260×390 for posters, 392×280 for CW).
UIKit: **completely missing**. No more-loading UI.

This is a minor issue since loading is usually fast, but it's a real
discrepancy.

### 5.5 End indicator

SwiftUI returns `EmptyView()` so no actual indicator. **Match (both empty).**

---

## 6. Layout / scroll behavior

### 6.1 Scroll view padding

SwiftUI: `LazyVStack(spacing: 0)` containing hero + content rows VStack.
Content rows VStack: `VStack(alignment: .leading, spacing: 48)`.
`.padding(.top, heroActive ? 0 : 48)`.

UIKit: collection view default insets. **The 48pt top padding when hero
is off is not replicated** — Bug 6.1.a.

### 6.2 Section spacing

SwiftUI inter-section spacing: 48pt (VStack spacing). Plus invisible
"contentRowsAnchor" Color.clear with height 0.

UIKit: each section's `contentInsets.bottom = 32` plus the next
section's `contentInsets.top = 16` = 48pt between sections. **Match.**

### 6.3 Scroll-on-focus

SwiftUI: `onRowFocused` callback per row calls
`scrollProxy.scrollTo(rowID, anchor: UnitPoint(x: 0.5, y: 0.5))`
with `.smooth(duration: 0.8)`. Centres the row vertically.

UIKit: implemented in `collectionView(_:didUpdateFocusIn:with:)`,
calls `scrollSectionIntoView` which centres the row in the viewport.
**Match.**

### 6.4 Hero focus → scroll top

SwiftUI: `onHeroFocused` → `scrollProxy.scrollTo("homeHero", anchor: .top)`.
UIKit: `scrollHeroIntoView()` → contentOffset.y = -adjustedContentInset.top.
**Match.**

---

## 7. Behaviors

### 7.1 Hero advance

SwiftUI: hero advances only when user presses Next button (no timer).
UIKit: same. **Match.**

### 7.2 Watchlist toast

SwiftUI: `.watchlistToast(message: watchlistService.transientWriteError)`
on the NavigationStack (`PlexHomeView.swift:184`). Shows transient error
at bottom of screen when watchlist write fails optimistically.

UIKit: **completely missing**. No equivalent toast.

### 7.3 Resume-or-restart dialog

SwiftUI: `.confirmationDialog("Resume Playback?", ...)`.
UIKit: `UIAlertController(.actionSheet)`. **Match (functionally).**

### 7.4 Refresh hubs on `.plexDataNeedsRefresh`

SwiftUI: `.onReceive(NotificationCenter.default.publisher(for: .plexDataNeedsRefresh))`.
UIKit: same observation. **Match.**

### 7.5 Refresh on libraryGUIDIndexDidUpdate

SwiftUI: triggers `upgradeHeroFromTMDB`. UIKit: same. **Match.**

### 7.6 Recommendation loading states

SwiftUI (`PlexHomeView.swift:867-901`):
- isLoading + empty → spinner + "Building Personalized Recommendations / This may take a moment"
- error → yellow warning icon + retry button
- populated → row

UIKit: **only renders the populated row when `recommendations.isEmpty == false`**.
No loading state, no error state UI. Bug 7.6.a.

### 7.7 Connection error banner

SwiftUI (`PlexHomeView.swift:806-847`): yellow banner with retry button
when authManager.isConnected is false and we're showing cached content.

UIKit: **completely missing.**

### 7.8 Empty / loading / error / not-connected states

SwiftUI: separate `loadingView`, `errorView`, `emptyView`, `notConnectedView`
for the major-state branches in `body` (`PlexHomeView.swift:120-150`).

UIKit: **none of these. Just shows blank/black when in any of these states.**

### 7.9 Context menus

SwiftUI: each poster gets `.mediaItemContextMenu(...)` (regular hubs) or
`ContinueWatchingContextMenuModifier` (CW hub). Watchlist tiles get the
mediaItemContextMenu in the legacy path.

UIKit: **completely missing.** No context menu for long-press / hold
on the remote.

### 7.10 Pagination (load-more)

SwiftUI: each row tracks its own state, calls `getHubItems(hubKey: ..., start: ..., count: 24)`
when the user scrolls within 5 items of the end, dedupes by ratingKey.

UIKit: **completely missing.** No pagination at all — only renders the
initial items from the hub. After scrolling to the end of a row,
nothing more loads.

---

## 8. Summary of action items, by severity

**Bugs (visible/functional):**
1. Hero overlay vertical positioning (1.4.a) — slide not bottom-aligned
2. Hero fallback title not serif (1.7.a)
3. ultraThinMaterial mismatch (1.10.a) — use real blur
4. Slide swap fades in but not out (1.12.a)
5. Continue Watching missing centered title logo (2.2.a)
6. Continue Watching missing bottom gradient (2.2.b)
7. Continue Watching missing info bar (2.2.c)
8. Continue Watching wrong progress bar shape/colour (2.2.d)
9. Continue Watching missing shadow (2.2.f)
10. MediaPosterCard missing drop shadow (3.1.a)
11. MediaPosterCard missing watched/in-progress indicators (3.3, 3.4)
12. Watchlist header font size off (4.1.a)
13. Watchlist hub top inset off (4.2.a)
14. Watchlist tile missing placeholder (4.3.a)
15. Watchlist tile missing shadow (4.3.b)
16. InfiniteContentRow header style wrong (weight, colour) (5.1.a, 5.1.b)
17. InfiniteContentRow header missing count indicator (5.1.c)
18. Different header styles per row not supported architecturally (5.1)
19. Skeleton-poster loading indicator missing (5.4)
20. Top padding when hero off (6.1.a)
21. Watchlist toast missing (7.2)
22. Recommendations loading/error states missing (7.6.a)
23. Connection error banner missing (7.7)
24. Loading/error/empty/not-connected views missing (7.8)
25. Context menus missing (7.9)
26. Pagination missing (7.10)

**Cosmetic (subtle):**
- Tagline padding (1.5.a, 1.9)
- Header height too big (4.2.b, 5.2)
- Failure state icon missing (3.6.a)
- Progress=1 hide condition (2.5)

**Acceptable:**
- TVPosterView focus motion vs SwiftUI hoverEffect (3.1)
- Hero section height floor (1.3)

---

## Strategy for fixes

These split naturally into batches by what they touch:

**Batch 1 (highest impact, visible to user on every CW tile)**:
- 2.2.* + 2.3 + 2.4: rebuild ContinueWatchingCell to match
  ContinueWatchingCard (title logo, gradient, info bar, progress capsule,
  drop shadow).

**Batch 2 (poster card parity)**:
- 3.1.a + 3.3 + 3.4 + 3.6: add drop shadow, watched indicators,
  in-progress capsule, failure-state icon to PosterCell.
- 4.3.a + 4.3.b: same for WatchlistPosterCell.

**Batch 3 (header + spacing)**:
- 4.1, 4.2.a, 4.2.b, 5.1, 5.2, 6.1: two header styles + correct
  spacing + count indicator.

**Batch 4 (hero polish)**:
- 1.4.a, 1.7.a, 1.10.a, 1.12.a, 1.5.a/1.9: layout, serif font,
  real blur, crossfade.

**Batch 5 (missing infrastructure)**:
- 7.2 watchlist toast
- 7.6.a recommendations states
- 7.7 connection banner
- 7.8 loading/empty/error/not-connected
- 7.9 context menus
- 7.10 pagination
- 5.4 row-end loading indicator
