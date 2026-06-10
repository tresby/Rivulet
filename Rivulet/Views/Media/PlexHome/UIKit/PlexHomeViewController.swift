//
//  PlexHomeViewController.swift
//  Rivulet
//
//  UIKit/TVUIKit implementation of the Plex Home screen. Mirrors the
//  SwiftUI `PlexHomeView` feature set so it can replace it 1:1.
//
//  Composition:
//    - `HeroBackdropView` (fixed): full-bleed sibling of the collection
//      view, translated upward on scroll for the receding parallax effect
//      (matches the SwiftUI `.offset(y: -heroScrollOffset * 1.3 ...)`).
//    - `UICollectionView` (scrolling):
//        * Section 0: hero overlay (SwiftUI `HeroOverlayContent` via
//          `HeroOverlayCell` / UIHostingController) — when hero is enabled
//        * Section 1: Continue Watching (`ContinueWatchingCell`)
//        * Sections 2..N: Recently Added per Home library (`PosterCell`)
//        * Section N+1: Watchlist (`WatchlistPosterCell`)
//        * Section N+2: Personalized Recommendations (`PosterCell`)
//
//  Navigation:
//    - Detail navigation hands `MediaItem` back to SwiftUI via the
//      `onSelectItem` callback so the existing NavigationStack pushes
//      `MediaDetailView`.
//    - Preview carousel is presented as `PreviewContainerViewController`
//      (a UIKit overFullScreen modal hosting SwiftUI `PreviewOverlayHost`)
//      from this controller — mirrors the SwiftUI flow.
//    - Resume-or-restart prompt is a `UIAlertController(.actionSheet)`.
//
//  Focus restoration:
//    - `UICollectionView.remembersLastFocusedIndexPath = true` keeps the
//      last focused tile in each row.
//    - When the preview is dismissed with a `PreviewSourceTarget`, we
//      translate that into the matching `IndexPath` and force a focus
//      update there.
//

import UIKit
import TVUIKit
import SwiftUI
import Combine
import os.log

private let homeUIKitLog = Logger(subsystem: "com.rivulet.app", category: "PlexHomeUIKit")

// MARK: - Section model

nonisolated struct HomeSectionID: Hashable, Sendable {
    let raw: String
    static let hero = HomeSectionID(raw: "hero")
    static let watchlist = HomeSectionID(raw: "watchlist")
    static let recommendations = HomeSectionID(raw: "recommendations")
    static func hub(_ hubID: String) -> HomeSectionID { .init(raw: "hub:\(hubID)") }
}

/// Which surface this controller renders. The library page IS the home page —
/// same hero, rows, focus, scroll, backdrop — just fed a single library's hubs
/// (plus, later, a sortable grid section). One implementation, two surfaces:
/// parity by construction instead of a separate VC that drifts.
enum HomeMode {
    case home
    /// A single Plex library (`key` = section id, `title` for headers).
    case library(key: String, title: String)
}

nonisolated struct HomeItemID: Hashable, Sendable {
    let sectionID: HomeSectionID
    /// Item identifier — ratingKey for hubs and recommendations,
    /// watchlist-entry id for watchlist, "hero-overlay" for hero,
    /// `skeletonSentinel` for the loading-skeleton card at row end.
    let itemID: String

    /// Reserved string used as the itemID for a section's loading-skeleton
    /// card. No real Plex/watchlist item will ever produce this value.
    static let skeletonSentinel = "__skeleton__"
}

enum HomeSectionKind: Equatable {
    case hero
    case continueWatching
    case recentlyAdded
    case watchlist
    /// Populated recommendations row — renders PosterCells.
    case recommendations
    /// Inline loading state — single full-width spinner + message cell.
    case recommendationsLoading
    /// Inline error state — single full-width warning + retry cell. The
    /// message itself lives on the controller as `recommendationsError`;
    /// the kind is just a tag so the layout/render code can pick it.
    case recommendationsError
}

struct HomeSectionData {
    let id: HomeSectionID
    let kind: HomeSectionKind
    let title: String?
    /// Which header style applies — SwiftUI uses two distinct ones:
    /// InfiniteContentRow style (30pt semibold white-0.6, optional inline
    /// count) vs WatchlistHubRow style (28pt bold white, no count).
    let headerStyle: HubHeaderView.Style
    /// Total item count from Plex for the "X of Y" indicator. nil when
    /// pagination hasn't loaded a total yet, which is the case for first
    /// render of every section.
    let totalSize: Int?
    /// Plex items for hub/recommendations/CW sections.
    let plexItems: [PlexMetadata]
    /// Watchlist entries for the watchlist section.
    let watchlistItems: [PlexWatchlistItem]
    /// Hero carousel items (used by the hero overlay cell).
    let heroItems: [PlexMetadata]
    let hubKey: String?
    let hubIdentifier: String?

    static func hub(id: HomeSectionID, title: String, items: [PlexMetadata], isContinueWatching: Bool, hubKey: String?, hubIdentifier: String?, totalSize: Int? = nil) -> HomeSectionData {
        HomeSectionData(
            id: id,
            kind: isContinueWatching ? .continueWatching : .recentlyAdded,
            title: title,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: totalSize,
            plexItems: items,
            watchlistItems: [],
            heroItems: [],
            hubKey: hubKey,
            hubIdentifier: hubIdentifier
        )
    }

    static func hero(items: [PlexMetadata]) -> HomeSectionData {
        HomeSectionData(
            id: .hero,
            kind: .hero,
            title: nil,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            plexItems: [],
            watchlistItems: [],
            heroItems: items,
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    static func watchlist(items: [PlexWatchlistItem]) -> HomeSectionData {
        HomeSectionData(
            id: .watchlist,
            kind: .watchlist,
            title: "Watchlist",
            headerStyle: .swiftUIWatchlist,
            totalSize: nil,
            plexItems: [],
            watchlistItems: items,
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    static func recommendations(items: [PlexMetadata]) -> HomeSectionData {
        HomeSectionData(
            id: .recommendations,
            kind: .recommendations,
            title: "Personalized Recommendations",
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            plexItems: items,
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    static func recommendationsLoading() -> HomeSectionData {
        HomeSectionData(
            id: .recommendations,
            kind: .recommendationsLoading,
            // SwiftUI's loading view doesn't render the row title at all
            // (PlexHomeView.swift:867-881) -- it's an inline status row
            // that replaces the row entirely. nil here suppresses the
            // section-header.
            title: nil,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            plexItems: [],
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    static func recommendationsError() -> HomeSectionData {
        HomeSectionData(
            id: .recommendations,
            kind: .recommendationsError,
            title: nil,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            plexItems: [],
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }
}

// MARK: - Controller

@MainActor
final class PlexHomeViewController: UIViewController {

    // Callbacks back into the SwiftUI shell.
    var onSelectItem: ((MediaItem) -> Void)?
    var onSelectMusic: ((PlexMetadata) -> Void)?

    /// Surface selector — .home (default) or .library(key:title:). All
    /// library-specific behavior branches off this; home-mode code paths are
    /// byte-identical to before the mode was introduced.
    let mode: HomeMode

    init(mode: HomeMode = .home) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Library-mode loading/error state for this library's hub fetch
    /// (home mode uses dataStore.isLoadingHubs / hubsError instead).
    private var isLoadingLibraryHubs = false
    private var libraryHubsError: String?

    private let dataStore = PlexDataStore.shared
    private let authManager = PlexAuthManager.shared
    private let watchlistService = PlexWatchlistService.shared
    private let recommendationService = PersonalizedRecommendationService.shared

    /// Standard tvOS frosted background (adapts to light/dark). The backmost
    /// layer of the screen; the hero art and the collection sit in front. As
    /// the hero art translates up on scroll it reveals this surface instead of
    /// flat black, matching the Apple TV+ home. Stays visible when the hero is
    /// off too.
    private var backgroundBlurView: UIVisualEffectView!
    private var backdropView: HeroBackdropView!
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<HomeSectionID, HomeItemID>!

    /// Sits at the leading edge of the collection view and absorbs
    /// fast Left-swipe focus moves that would otherwise escape to the
    /// sidebar mid-row. Updated in `didUpdateFocus`: when the focused
    /// cell is at item 0 of its row (or in a non-orthogonal section),
    /// `preferredFocusEnvironments = []` and the guide is transparent
    /// to the engine — focus passes through to the sidebar normally.
    /// When the focused cell is item ≥1 of a horizontal row, the guide
    /// redirects to the cell at `indexPath.item - 1` (and we scroll
    /// the orthogonal section so that cell is on screen).
    private var leftEdgeFocusGuide: UIFocusGuide!

    /// Full-screen state placeholder (notConnected / loading / error / empty).
    /// `isHidden` toggles based on auth + data-store state precedence
    /// matching `PlexHomeView.body`.
    private var stateView: HomeStateView!
    /// Transient toast for watchlist-write errors. Bottom-anchored, fades
    /// in when `watchlistService.transientWriteError` becomes non-nil.
    private var watchlistToast: WatchlistToastView!
    /// Yellow warning banner at the top of the content scroll when we're
    /// rendering cached content but the Plex connection check is failing.
    private var connectionBanner: ConnectionErrorBannerView!
    /// Top inset reserved for the connection banner when it's visible.
    /// Stored so we can toggle it cleanly without recomputing.
    private var connectionBannerTopInset: CGFloat = 0

    private var sectionsSnapshot: [HomeSectionData] = []

    /// Hero carousel index (drives backdrop image + overlay current item).
    private var heroCurrentIndex: Int = 0
    private var heroItems: [PlexMetadata] = []

    private var dataStoreObservers: Set<AnyCancellable> = []

    private var hasMarkedFirstFrame = false
    private var hasLoadedRecommendations = false

    /// Pending focus restoration after preview dismiss.
    private var pendingPreviewRestore: PreviewSourceTarget?

    /// Per-section pagination state. Keyed by HomeSectionID. Mirrors the
    /// per-row state SwiftUI InfiniteContentRow keeps locally
    /// (items / isLoadingMore / hasReachedEnd / totalSize).
    private struct PaginationState {
        var loadedItems: [PlexMetadata]    // initial items + everything paginated in
        var totalSize: Int?
        var isLoadingMore: Bool
        var hasReachedEnd: Bool
    }
    private var paginationStates: [HomeSectionID: PaginationState] = [:]
    private let paginationPageSize = 24

    /// Recommendations state (latched local copy — service caches itself).
    private var recommendations: [PlexMetadata] = []
    private var isLoadingRecommendations = false
    private var recommendationsError: String?

    /// Hero gate for the current mode: `showHomeHero` AppStorage on the home,
    /// `showLibraryHero` on a library page (both mirror the SwiftUI toggles).
    /// Kept under the original name so every existing call site stays as-is.
    private var showHomeHero: Bool {
        switch mode {
        case .home: return UserDefaults.standard.bool(forKey: "showHomeHero")
        case .library: return UserDefaults.standard.bool(forKey: "showLibraryHero")
        }
    }
    /// `enablePersonalizedRecommendations` AppStorage gate.
    private var enablePersonalizedRecommendations: Bool {
        UserDefaults.standard.bool(forKey: "enablePersonalizedRecommendations")
    }
    /// `promptResumeOrRestart` AppStorage gate.
    private var promptResumeOrRestart: Bool {
        UserDefaults.standard.bool(forKey: "promptResumeOrRestart")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // No opaque base behind `backgroundBlurView`: let the blur sample
        // whatever sits behind the home view (the SwiftUI shell / system)
        // rather than a flat colour. (Trying this to see if it yields a softer,
        // content-independent backdrop instead of the flat fill.)
        view.backgroundColor = .clear

        Perf.event(.homeFirstRender, message: "viewDidLoad start")

        configureBackdrop()
        configureCollectionView()
        configureStateOverlays()
        configureDataSource()
        observeDataStore()
        observeWatchlist()
        observeUserDefaults()
        observeAuth()

        // Seed hero from cache before the initial snapshot so the first
        // frame already contains it on warm launches. Data-store refresh
        // below + the TMDB upgrade task will update the carousel later.
        selectHeroItemsIfNeeded()

        applySnapshot(animated: false)
        updateHomeState()

        switch mode {
        case .home:
            Task { @MainActor in
                await Perf.interval(.homeDataFetch) {
                    await dataStore.refreshHubs()
                    await dataStore.refreshLibraryHubs()
                }
                // Re-evaluate after the network pass in case the cache was
                // empty and the hub-derived fallback couldn't run earlier.
                selectHeroItemsIfNeeded()
            }
            Task { await watchlistService.fetchWatchlist() }

            if enablePersonalizedRecommendations {
                Task { await refreshRecommendations(force: false) }
            }
        case .library:
            // Library page: just this library's hubs. No watchlist row, no
            // personalized recommendations, no cross-library fetches.
            Task { @MainActor in
                await refreshThisLibraryHubs()
            }
        }
    }

    /// Library-mode data load: fetch this library's hubs (its own Continue
    /// Watching, Recently Added, genre rows) into `dataStore.libraryHubs` —
    /// the same store slot + network call the SwiftUI PlexLibraryView used.
    private func refreshThisLibraryHubs() async {
        guard case .library(let key, _) = mode,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        isLoadingLibraryHubs = (dataStore.libraryHubs[key] == nil)
        updateHomeState()
        do {
            let hubs = try await PlexNetworkManager.shared.getLibraryHubs(
                serverURL: serverURL, authToken: token, sectionId: key
            )
            dataStore.libraryHubs[key] = hubs
            libraryHubsError = nil
        } catch {
            // Keep stale content if we have any; only surface the error when
            // there's nothing to show (mirrors the home's hubsError handling).
            if (dataStore.libraryHubs[key] ?? []).isEmpty {
                libraryHubsError = error.localizedDescription
            }
        }
        isLoadingLibraryHubs = false
        applySnapshot(animated: false)
        selectHeroItemsIfNeeded()
        updateHomeState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasMarkedFirstFrame {
            hasMarkedFirstFrame = true
            Perf.event(.homeFirstFrameOnScreen, message: "viewDidAppear")

            if PerfAutoScroll.enabled {
                runAutoScroll()
            }
        }
        applyPendingPreviewRestoreIfNeeded()
    }

    private func runAutoScroll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let id = Perf.begin(.homeScroll, message: "auto-scroll vertical")
            self.collectionView.setContentOffset(
                CGPoint(x: 0, y: max(0, self.collectionView.contentSize.height - self.collectionView.bounds.height)),
                animated: true
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Perf.end(.homeScroll, id: id)
                Perf.event(.homeScroll, message: "auto-scroll done")
            }
        }
    }

    // MARK: - Backdrop

    private func configureBackdrop() {
        // Backmost layer: a standard tvOS frosted background that adapts to
        // light/dark. The hero art (added next, in front) bleeds full-screen at
        // the top and translates up on scroll; past it this surface shows
        // instead of black. Static (does not translate) and non-interactive.
        // Visible even when the hero is off.
        backgroundBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        backgroundBlurView.translatesAutoresizingMaskIntoConstraints = false
        backgroundBlurView.isUserInteractionEnabled = false
        view.addSubview(backgroundBlurView)
        NSLayoutConstraint.activate([
            backgroundBlurView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundBlurView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backgroundBlurView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundBlurView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        backdropView = HeroBackdropView()
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropView)
        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        backdropView.isHidden = !showHomeHero
    }

    /// SwiftUI: `.padding(.top, heroActive ? 0 : 48)`. When hero is off we
    /// give the first row some breathing room from the top edge. Also
    /// reserves space below the connection banner when it's visible
    /// (mirrors SwiftUI's banner positioning above the content).
    private func updateContentTopInset() {
        let baseTop: CGFloat = showHomeHero ? 0 : 48
        let topInset = baseTop + connectionBannerTopInset
        if collectionView.contentInset.top != topInset {
            collectionView.contentInset.top = topInset
        }
    }

    private func updateBackdropForCurrentHeroItem() {
        guard showHomeHero, !heroItems.isEmpty else {
            backdropView.setBackdrop(url: nil)
            return
        }
        let clamped = max(0, min(heroCurrentIndex, heroItems.count - 1))
        updateBackdrop(for: heroItems[clamped])
    }

    /// Set the hero backdrop from a specific item. Used by the overlay's
    /// `onIndexChanged` so the backdrop matches exactly the slide the overlay is
    /// showing. The index-based path above can disagree once `heroItems` is
    /// reordered by the TMDB upgrade after the overlay was configured.
    private func updateBackdrop(for item: PlexMetadata) {
        guard showHomeHero,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            backdropView.setBackdrop(url: nil)
            return
        }
        let request = item.heroBackdropRequest(serverURL: serverURL, authToken: token)
        let url = request.backdropURL ?? request.thumbnailURL
        backdropView.setBackdrop(url: url)
    }

    // MARK: - State overlays (loading / empty / error / not-connected,
    //          connection banner, watchlist toast)

    private func configureStateOverlays() {
        // Connection-error banner. Sits at the top of the screen above
        // the collection view. Hidden by default.
        connectionBanner = ConnectionErrorBannerView()
        connectionBanner.translatesAutoresizingMaskIntoConstraints = false
        connectionBanner.isHidden = true
        connectionBanner.onRetry = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.authManager.verifyAndFixConnection()
                if self.authManager.isConnected {
                    await self.dataStore.refreshHubs()
                }
            }
        }
        view.addSubview(connectionBanner)

        // Full-screen state placeholder.
        stateView = HomeStateView()
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        stateView.onAction = { [weak self] in
            guard let self else { return }
            Task { await self.dataStore.refreshHubs() }
        }
        view.addSubview(stateView)

        // Bottom-anchored toast for watchlist write reverts.
        watchlistToast = WatchlistToastView()
        view.addSubview(watchlistToast)

        NSLayoutConstraint.activate([
            connectionBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 100),
            connectionBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            connectionBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            watchlistToast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            watchlistToast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80)
        ])
    }

    /// Evaluate auth + data-store state and show the right overlay (or
    /// the home content). Mirror of SwiftUI `PlexHomeView.body`'s
    /// branching precedence (`PlexHomeView.swift:122-150`).
    private func updateHomeState() {
        let hasCredentials = authManager.hasCredentials
        // Data presence/loading/error per mode: the home reads the global hub
        // store; a library page reads its own hub fetch state.
        let isLoadingHubs: Bool
        let hubsError: String?
        let hubsEmpty: Bool
        switch mode {
        case .home:
            isLoadingHubs = dataStore.isLoadingHubs
            hubsError = dataStore.hubsError
            hubsEmpty = dataStore.hubs.isEmpty
        case .library(let key, _):
            isLoadingHubs = isLoadingLibraryHubs
            hubsError = libraryHubsError
            hubsEmpty = (dataStore.libraryHubs[key] ?? []).isEmpty
        }

        // Precedence: notConnected → loading → error → empty → content.
        if !hasCredentials {
            stateView.configure(kind: .notConnected)
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            connectionBanner.isHidden = true
        } else if isLoadingHubs && hubsEmpty {
            stateView.configure(kind: .loading)
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            connectionBanner.isHidden = true
        } else if let error = hubsError, hubsEmpty {
            stateView.configure(kind: .error(message: error))
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            connectionBanner.isHidden = true
        } else if hubsEmpty {
            stateView.configure(kind: .empty)
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            connectionBanner.isHidden = true
        } else {
            // Content path. Reveal the collection view + backdrop, then
            // decide whether to show the inline connection banner.
            stateView.isHidden = true
            collectionView.isHidden = false
            backdropView.isHidden = !showHomeHero
            let shouldShowBanner = !authManager.isConnected
            updateConnectionBanner(shouldShowBanner)
        }
    }

    private func updateConnectionBanner(_ shouldShow: Bool) {
        if shouldShow {
            connectionBanner.setMessage(authManager.connectionError)
        }
        if connectionBanner.isHidden != !shouldShow {
            connectionBanner.isHidden = !shouldShow
        }
        let bannerHeight: CGFloat = shouldShow ? 120 : 0
        if connectionBannerTopInset != bannerHeight {
            connectionBannerTopInset = bannerHeight
            updateContentTopInset()
        }
    }

    // MARK: - Layout

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            return self.layoutSection(at: sectionIndex, environment: environment)
        }

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.contentInsetAdjustmentBehavior = .never
        // SwiftUI: `.padding(.top, heroActive ? 0 : 48)` on the content
        // VStack. When the hero is off, the first row (Continue Watching)
        // gets 48pt of breathing room at the top of the scroll.
        updateContentTopInset()
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.clipsToBounds = false
        // Take over the vertical focus-scroll. Left enabled, the focus engine
        // runs its OWN scroll animator whenever focus moves between rows, and
        // that animator races the per-frame CADisplayLink driver in
        // `animateContentOffset`. Two clocks writing `contentOffset` on
        // different curves is what reads as the "moves, then slows, then moves
        // again" stutter. Disabling it stops the engine's focus-scroll; we
        // drive every vertical move ourselves from `didUpdateFocusIn`. The
        // orthogonal rows keep their own inner horizontal scroller, so Left/
        // Right within a row is unaffected. (Same pattern the detail view uses
        // in FocusScrollControlledCollectionView.)
        collectionView.isScrollEnabled = false

        collectionView.register(HubHeaderView.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: HubHeaderView.reuseID)
        collectionView.register(PosterCell.self, forCellWithReuseIdentifier: PosterCell.reuseID)
        collectionView.register(ContinueWatchingCell.self, forCellWithReuseIdentifier: ContinueWatchingCell.reuseID)
        collectionView.register(HeroOverlayCell.self, forCellWithReuseIdentifier: HeroOverlayCell.reuseID)
        collectionView.register(WatchlistPosterCell.self, forCellWithReuseIdentifier: WatchlistPosterCell.reuseID)
        collectionView.register(PosterSkeletonCell.self, forCellWithReuseIdentifier: PosterSkeletonCell.reuseID)
        collectionView.register(RecommendationsStateCell.self, forCellWithReuseIdentifier: RecommendationsStateCell.reuseID)

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Leading-edge focus guide. See property doc for the why.
        leftEdgeFocusGuide = UIFocusGuide()
        view.addLayoutGuide(leftEdgeFocusGuide)
        NSLayoutConstraint.activate([
            leftEdgeFocusGuide.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            leftEdgeFocusGuide.widthAnchor.constraint(equalToConstant: 1),
            leftEdgeFocusGuide.topAnchor.constraint(equalTo: collectionView.topAnchor),
            leftEdgeFocusGuide.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor)
        ])
    }

    private func layoutSection(at sectionIndex: Int, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        guard sectionIndex < sectionsSnapshot.count else { return nil }
        let section = sectionsSnapshot[sectionIndex]
        switch section.kind {
        case .hero:
            return makeHeroSectionLayout()
        case .continueWatching, .recentlyAdded, .recommendations:
            return makeHubSectionLayout(section: section, isContinueWatching: section.kind == .continueWatching)
        case .watchlist:
            return makeHubSectionLayout(section: section, isContinueWatching: false)
        case .recommendationsLoading, .recommendationsError:
            return makeRecommendationsStateLayout()
        }
    }

    /// Single full-width cell for the recommendations-loading / error
    /// inline states. SwiftUI rendering uses `padding(.horizontal,
    /// rowHorizontalPadding=48)` + `.padding(.vertical, 24)` for loading
    /// and `.padding(.vertical, 12)` for error -- we use 24 as the
    /// average; the cell handles its own internal padding via its
    /// rowStack constraints.
    private func makeRecommendationsStateLayout() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(80)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 24, leading: 32, bottom: 48, trailing: 48)
        return section
    }

    private func makeHeroSectionLayout() -> NSCollectionLayoutSection {
        // Height matches the SwiftUI hero section height: screen - 200pt.
        let height = max(400, UIScreen.main.bounds.height - 200)
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(height))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        // Small bottom gap so the first row (Continue Watching) sits a bit
        // lower, separated from the hero.
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 40, trailing: 0)
        return section
    }

    private func makeHubSectionLayout(section: HomeSectionData, isContinueWatching: Bool) -> NSCollectionLayoutSection {
        let tileWidth: CGFloat = isContinueWatching ? 360 : 260
        let tileHeight: CGFloat = isContinueWatching ? 280 : 390
        let groupHeight = tileHeight + 80  // room for focus growth + shadow

        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(tileWidth),
                                              heightDimension: .absolute(tileHeight))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(widthDimension: .absolute(tileWidth),
                                               heightDimension: .absolute(groupHeight))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let layoutSection = NSCollectionLayoutSection(group: group)
        layoutSection.orthogonalScrollingBehavior = .continuous
        // Continue Watching is tighter than the other rows (CW 16, others 30).
        layoutSection.interGroupSpacing = isContinueWatching ? 16 : 30
        // top: header-to-first-card gap, tightened to 12 so the row title sits
        //   close to its cards.
        // leading: page content-left margin (32; kept in sync with the hero
        //   overlay's leading). This inset also positions the header, so the
        //   title aligns with the first card.
        // bottom: gap to the next section.
        layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 32, bottom: 15, trailing: 48)

        if section.title != nil {
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(40)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            layoutSection.boundarySupplementaryItems = [header]
        }

        return layoutSection
    }

    // MARK: - Data source

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<HomeSectionID, HomeItemID>(collectionView: collectionView) { [weak self] collectionView, indexPath, itemID in
            guard let self else { return nil }
            return self.cell(for: itemID, at: indexPath, in: collectionView)
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard let self,
                  kind == UICollectionView.elementKindSectionHeader,
                  indexPath.section < self.sectionsSnapshot.count
            else { return nil }
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: HubHeaderView.reuseID,
                for: indexPath
            ) as! HubHeaderView
            let section = self.sectionsSnapshot[indexPath.section]
            let loadedCount: Int
            switch section.kind {
            case .hero, .recommendationsLoading, .recommendationsError:
                loadedCount = 0
            case .continueWatching, .recentlyAdded, .recommendations:
                loadedCount = section.plexItems.count
            case .watchlist: loadedCount = section.watchlistItems.count
            }
            header.configure(
                title: section.title ?? "",
                style: section.headerStyle,
                loadedCount: loadedCount,
                totalCount: section.totalSize
            )
            return header
        }
    }

    private func cell(for itemID: HomeItemID, at indexPath: IndexPath, in collectionView: UICollectionView) -> UICollectionViewCell {
        guard indexPath.section < sectionsSnapshot.count else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
        }
        let section = sectionsSnapshot[indexPath.section]
        let perfKey = "\(itemID.sectionID.raw):\(itemID.itemID)"

        // Skeleton item: SwiftUI shows a placeholder card at the row's end
        // while pagination is in flight. We add a synthetic itemID with a
        // fixed sentinel; recognise it here and dequeue a skeleton cell.
        if itemID.itemID == HomeItemID.skeletonSentinel {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PosterSkeletonCell.reuseID, for: indexPath) as! PosterSkeletonCell
            cell.configure(layout: section.kind == .continueWatching ? .continueWatching : .poster)
            return cell
        }

        switch section.kind {
        case .hero:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: HeroOverlayCell.reuseID, for: indexPath) as! HeroOverlayCell
            cell.configure(with: HeroOverlayCell.Configuration(
                items: section.heroItems,
                serverURL: authManager.selectedServerURL ?? "",
                authToken: authManager.selectedServerToken ?? "",
                initialIndex: heroCurrentIndex,
                onIndexChanged: { [weak self] newIndex, item in
                    guard let self else { return }
                    self.heroCurrentIndex = newIndex
                    // Drive the backdrop off the exact item the overlay is
                    // showing, not heroItems[newIndex] (the two arrays diverge
                    // once the TMDB upgrade reorders heroItems).
                    self.updateBackdrop(for: item)
                },
                onInfo: { [weak self] item in self?.presentDetailPage(for: item) },
                onPlay: { [weak self] item in self?.playItemDirectly(item) },
                onFocusEntered: { [weak self] in
                    self?.scrollHeroIntoView()
                }
            ))
            return cell

        case .continueWatching:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ContinueWatchingCell.reuseID, for: indexPath) as! ContinueWatchingCell
            if indexPath.item < section.plexItems.count {
                Perf.interval(.cellPrepare, key: perfKey) {
                    cell.configure(item: section.plexItems[indexPath.item])
                }
            }
            return cell

        case .recentlyAdded, .recommendations:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
            if indexPath.item < section.plexItems.count {
                Perf.interval(.cellPrepare, key: perfKey) {
                    cell.configure(item: section.plexItems[indexPath.item])
                }
            }
            return cell

        case .watchlist:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: WatchlistPosterCell.reuseID, for: indexPath) as! WatchlistPosterCell
            if indexPath.item < section.watchlistItems.count {
                Perf.interval(.cellPrepare, key: perfKey) {
                    cell.configure(item: section.watchlistItems[indexPath.item])
                }
            }
            return cell

        case .recommendationsLoading:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: RecommendationsStateCell.reuseID, for: indexPath) as! RecommendationsStateCell
            cell.configure(state: .loading)
            return cell

        case .recommendationsError:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: RecommendationsStateCell.reuseID, for: indexPath) as! RecommendationsStateCell
            cell.configure(state: .error(message: recommendationsError ?? "Unknown error"))
            cell.onRetry = { [weak self] in
                Task { await self?.refreshRecommendations(force: true) }
            }
            return cell
        }
    }

    // MARK: - Data store observation

    private func observeDataStore() {
        dataStore.$hubsVersion
            .merge(with: dataStore.$libraryHubsVersion)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySnapshot(animated: false)
                self?.selectHeroItemsIfNeeded()
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)

        dataStore.$continueWatchingHub
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySnapshot(animated: false)
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)

        dataStore.$isLoadingHubs
            .merge(with: dataStore.$hubsError.map { _ in false })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)

        // Refresh hubs after playback dismissals etc.
        NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    switch self.mode {
                    case .home:
                        await self.dataStore.refreshHubs()
                        await self.dataStore.refreshLibraryHubs()
                        if self.enablePersonalizedRecommendations {
                            await self.refreshRecommendations(force: true)
                        }
                    case .library:
                        await self.refreshThisLibraryHubs()
                    }
                }
            }
            .store(in: &dataStoreObservers)

        // TMDB hero logo upgrade is home-only for now (the library hero uses
        // the items' own art; revisit if library logos need the upgrade too).
        if case .home = mode {
            NotificationCenter.default.publisher(for: .libraryGUIDIndexDidUpdate)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { await self?.upgradeHeroFromTMDB() }
                }
                .store(in: &dataStoreObservers)
        }
    }

    private func observeWatchlist() {
        watchlistService.$watchlistItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySnapshot(animated: false)
            }
            .store(in: &dataStoreObservers)

        // Transient write-error toast. Mirrors SwiftUI
        // `.watchlistToast(message: watchlistService.transientWriteError)`.
        watchlistService.$transientWriteError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.watchlistToast.show(message: message)
            }
            .store(in: &dataStoreObservers)
    }

    private func observeAuth() {
        // Connection state controls the inline banner + the
        // notConnectedView precedence (via hasCredentials → authToken).
        authManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)

        authManager.$connectionError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.authManager.isConnected {
                    self.connectionBanner.setMessage(self.authManager.connectionError)
                }
            }
            .store(in: &dataStoreObservers)

        authManager.$authToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)
    }

    /// React to AppStorage-backed settings (`showHomeHero`,
    /// `enablePersonalizedRecommendations`) flipping while the home is on
    /// screen. `UserDefaults.didChangeNotification` fires once per change.
    /// We just re-evaluate the relevant subsystem; no need to filter by key.
    private func observeUserDefaults() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.backdropView.isHidden = !self.showHomeHero
                if !self.showHomeHero {
                    self.backdropView.setBackdrop(url: nil)
                }
                self.updateContentTopInset()
                self.selectHeroItemsIfNeeded()
                if case .home = self.mode {
                    if self.enablePersonalizedRecommendations {
                        if self.recommendations.isEmpty {
                            Task { await self.refreshRecommendations(force: false) }
                        }
                    } else if !self.recommendations.isEmpty {
                        self.recommendations = []
                        self.applySnapshot(animated: false)
                    }
                }
            }
            .store(in: &dataStoreObservers)
    }

    // MARK: - Snapshot

    private func applySnapshot(animated: Bool) {
        let sections = computeSections()
        sectionsSnapshot = sections

        var snapshot = NSDiffableDataSourceSnapshot<HomeSectionID, HomeItemID>()
        for section in sections {
            snapshot.appendSections([section.id])
            var ids: [HomeItemID]
            switch section.kind {
            case .hero:
                ids = [HomeItemID(sectionID: section.id, itemID: "hero-overlay")]
            case .continueWatching, .recentlyAdded, .recommendations:
                ids = section.plexItems.enumerated().compactMap { idx, meta -> HomeItemID? in
                    let id = meta.ratingKey ?? "\(section.id.raw)-\(idx)"
                    return HomeItemID(sectionID: section.id, itemID: id)
                }
            case .watchlist:
                ids = section.watchlistItems.map { item in
                    HomeItemID(sectionID: section.id, itemID: item.id)
                }
            case .recommendationsLoading:
                ids = [HomeItemID(sectionID: section.id, itemID: "recs-loading")]
            case .recommendationsError:
                ids = [HomeItemID(sectionID: section.id, itemID: "recs-error")]
            }

            // Append a skeleton placeholder at the row's end when
            // pagination is in flight for this section. Mirror of
            // SwiftUI's `if isLoadingMore { loadingIndicator }`
            // (PlexHomeView.swift:1339).
            if paginationStates[section.id]?.isLoadingMore == true {
                ids.append(HomeItemID(sectionID: section.id, itemID: HomeItemID.skeletonSentinel))
            }

            // Diffable data source crashes on duplicate identifiers.
            // Plex hubs occasionally return the same ratingKey twice
            // (cross-library cameos, hub merges, etc.) — keep the first
            // occurrence and drop the rest.
            var seen = Set<HomeItemID>()
            let deduped = ids.filter { seen.insert($0).inserted }
            snapshot.appendItems(deduped, toSection: section.id)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func computeSections() -> [HomeSectionData] {
        if case .library(let key, _) = mode {
            return computeLibrarySections(libraryKey: key)
        }

        var sections: [HomeSectionData] = []

        // Hero (when enabled + items available)
        if showHomeHero, !heroItems.isEmpty {
            sections.append(.hero(items: heroItems))
        }

        // Continue Watching
        if let cw = dataStore.continueWatchingHub,
           let items = cw.Metadata, !items.isEmpty {
            let id = HomeSectionID.hub(cw.id)
            let merged = mergedItems(forSection: id, initial: items)
            sections.append(.hub(
                id: id,
                title: cw.title ?? "Continue Watching",
                items: merged.items,
                isContinueWatching: true,
                hubKey: cw.key ?? cw.hubKey,
                hubIdentifier: cw.hubIdentifier,
                totalSize: merged.totalSize
            ))
        }

        // Recently Added per home library
        for library in dataStore.librariesForHomeScreen {
            guard let hubs = dataStore.libraryHubs[library.key],
                  let recent = hubs.first(where: { isRecentlyAdded($0) }),
                  let items = recent.Metadata, !items.isEmpty
            else { continue }
            let id = HomeSectionID.hub("\(library.key):recent")
            let merged = mergedItems(forSection: id, initial: items)
            sections.append(.hub(
                id: id,
                title: "Recently Added \(library.title)",
                items: merged.items,
                isContinueWatching: false,
                hubKey: recent.key ?? recent.hubKey,
                hubIdentifier: recent.hubIdentifier,
                totalSize: merged.totalSize
            ))
        }

        // Watchlist
        let watchlistItems = Array(watchlistService.watchlistItems.prefix(20))
        if !watchlistItems.isEmpty {
            sections.append(.watchlist(items: watchlistItems))
        }

        // Personalized recommendations. Three-way branch matching
        // SwiftUI recommendationsSection (`PlexHomeView.swift:867-922`):
        //   isLoadingRecommendations && empty   -> loading state cell
        //   recommendationsError != nil         -> error state cell
        //   !recommendations.isEmpty            -> populated row
        if enablePersonalizedRecommendations {
            if isLoadingRecommendations && recommendations.isEmpty {
                sections.append(.recommendationsLoading())
            } else if recommendationsError != nil {
                sections.append(.recommendationsError())
            } else if !recommendations.isEmpty {
                sections.append(.recommendations(items: recommendations))
            }
            // else: no section (matches SwiftUI's silent dropout when the
            // user has enabled recs but the service returned nothing).
        }

        return sections
    }

    /// Library-mode section assembly: hero (from the library's own hubs) +
    /// one row per library hub, in Plex's order — its Continue Watching,
    /// Recently Added/Released, genre rows, etc. No watchlist row, no
    /// recommendations. Rows reuse the home's hub pipeline verbatim, so they
    /// get `mergedItems` pagination (hubKey) for free.
    private func computeLibrarySections(libraryKey key: String) -> [HomeSectionData] {
        var sections: [HomeSectionData] = []

        if showHomeHero, !heroItems.isEmpty {
            sections.append(.hero(items: heroItems))
        }

        var seenIDs = Set<String>()
        for hub in dataStore.libraryHubs[key] ?? [] {
            guard let items = hub.Metadata, !items.isEmpty else { continue }
            // Stable per-hub identity (the SwiftUI library used the same
            // identifier chain); de-dupe defensively — duplicate section IDs
            // crash the diffable snapshot.
            let hubID = hub.hubIdentifier ?? hub.key ?? hub.hubKey ?? hub.title ?? "row"
            guard seenIDs.insert(hubID).inserted else { continue }
            let id = HomeSectionID.hub("\(key):\(hubID)")
            let merged = mergedItems(forSection: id, initial: items)
            sections.append(.hub(
                id: id,
                title: hub.title ?? "",
                items: merged.items,
                isContinueWatching: isContinueWatchingHub(hub),
                hubKey: hub.key ?? hub.hubKey,
                hubIdentifier: hub.hubIdentifier,
                totalSize: merged.totalSize
            ))
        }

        return sections
    }

    /// A library's own "Continue Watching" hub, detected by identifier/title
    /// (Plex labels it `inProgress`/`continueWatching` depending on server).
    private func isContinueWatchingHub(_ hub: PlexHub) -> Bool {
        let identifier = (hub.hubIdentifier ?? "").lowercased()
        if identifier.contains("continue") || identifier.contains("inprogress") || identifier.contains("ondeck") {
            return true
        }
        return (hub.title ?? "").lowercased().contains("continue")
    }

    /// For a section with pagination state, return the merged item list
    /// (initial items + everything paginated in) and the current total
    /// size if known. If the state dict has no entry yet, seed it.
    private func mergedItems(forSection id: HomeSectionID, initial: [PlexMetadata])
    -> (items: [PlexMetadata], totalSize: Int?) {
        if var state = paginationStates[id] {
            // Server-side hubs can change items between renders (e.g.
            // refresh adds new content at the top). When the initial
            // list is a strict superset we replace the head to pick up
            // the changes; otherwise keep whatever pagination accumulated.
            let initialKeys = Set(initial.compactMap { $0.ratingKey })
            let loadedKeys = Set(state.loadedItems.compactMap { $0.ratingKey })
            if !initialKeys.isSubset(of: loadedKeys) {
                // Initial set has new items we haven't seen — rebuild
                // from initial, then re-append paginated-only entries.
                let paginatedExtras = state.loadedItems.filter { item in
                    guard let key = item.ratingKey else { return false }
                    return !initialKeys.contains(key)
                }
                state.loadedItems = initial + paginatedExtras
                paginationStates[id] = state
            }
            return (state.loadedItems, state.totalSize)
        } else {
            paginationStates[id] = PaginationState(
                loadedItems: initial,
                totalSize: nil,
                isLoadingMore: false,
                hasReachedEnd: false
            )
            return (initial, nil)
        }
    }

    private func isRecentlyAdded(_ hub: PlexHub) -> Bool {
        let id = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return id.contains("recentlyadded") || title.contains("recently added")
    }

    // MARK: - Hero selection

    private static let heroItemCap = 9
    private static let heroTMDBMinMatches = 3

    private func selectHeroItemsIfNeeded() {
        guard showHomeHero else { return }

        // Hero source + cache slot per mode: the home draws from the global
        // hubs under the "home" cache key; a library page draws from its own
        // hubs under its library key (same scheme the SwiftUI library used).
        let cacheKey: String
        let sourceHubs: [PlexHub]
        switch mode {
        case .home:
            cacheKey = "home"
            sourceHubs = dataStore.hubs
        case .library(let key, _):
            cacheKey = key
            sourceHubs = dataStore.libraryHubs[key] ?? []
        }

        if heroItems.isEmpty,
           let cached = dataStore.getCachedHeroItems(forLibrary: cacheKey),
           !cached.isEmpty {
            heroItems = cached
            updateBackdropForCurrentHeroItem()
            applySnapshot(animated: false)
        }

        if heroItems.isEmpty {
            let candidates = computeHubBackedHero(from: sourceHubs)
            if !candidates.isEmpty {
                heroItems = candidates
                dataStore.cacheHeroItems(candidates, forLibrary: cacheKey)
                updateBackdropForCurrentHeroItem()
                applySnapshot(animated: false)
            }
        }

        if case .home = mode {
            Task { await upgradeHeroFromTMDB() }
        }
    }

    private func computeHubBackedHero(from hubs: [PlexHub]) -> [PlexMetadata] {
        let curatedKeywords = ["recommended", "promoted", "featured", "spotlight"]
        let curated = hubs.first { hub in
            guard let id = hub.hubIdentifier?.lowercased(),
                  hub.Metadata?.isEmpty == false else { return false }
            return curatedKeywords.contains(where: id.contains)
        }
        if let items = curated?.Metadata, !items.isEmpty {
            return Array(items.prefix(Self.heroItemCap)).filter { $0.ratingKey != nil }
        }

        let recentlyAdded = hubs.first { isRecentlyAdded($0) && ($0.Metadata?.isEmpty == false) }
        if let items = recentlyAdded?.Metadata, !items.isEmpty {
            return Array(items.prefix(Self.heroItemCap)).filter { $0.ratingKey != nil }
        }

        if let firstHub = hubs.first(where: { $0.Metadata?.isEmpty == false }),
           let items = firstHub.Metadata, !items.isEmpty {
            return Array(items.prefix(Self.heroItemCap)).filter { $0.ratingKey != nil }
        }
        return []
    }

    @MainActor
    private func upgradeHeroFromTMDB() async {
        guard showHomeHero else { return }
        let curated = await PlexHomeView.computeTMDBHero(cap: Self.heroItemCap)
        guard curated.count >= Self.heroTMDBMinMatches else { return }

        // Preserve currently-visible item if it's in the curated set.
        let mergedItems: [PlexMetadata]
        if !heroItems.isEmpty {
            let clamped = max(0, min(heroCurrentIndex, heroItems.count - 1))
            let current = heroItems[clamped]
            if let currentKey = current.ratingKey,
               curated.contains(where: { $0.ratingKey == currentKey }) {
                let withoutCurrent = curated.filter { $0.ratingKey != currentKey }
                let targetIndex = max(0, min(heroCurrentIndex, withoutCurrent.count))
                var rotated = withoutCurrent
                rotated.insert(current, at: targetIndex)
                mergedItems = rotated
            } else if let _ = current.ratingKey {
                var merged: [PlexMetadata] = [current]
                let currentKey = current.ratingKey
                for item in curated where item.ratingKey != currentKey {
                    merged.append(item)
                }
                mergedItems = Array(merged.prefix(Self.heroItemCap))
                if heroCurrentIndex != 0 { heroCurrentIndex = 0 }
            } else {
                mergedItems = curated
            }
        } else {
            mergedItems = curated
        }

        let newKeys = mergedItems.compactMap { $0.ratingKey }
        let currentKeys = heroItems.compactMap { $0.ratingKey }
        guard newKeys != currentKeys else { return }

        heroItems = mergedItems
        dataStore.cacheHeroItems(mergedItems, forLibrary: "home")
        updateBackdropForCurrentHeroItem()
        applySnapshot(animated: false)
    }

    // MARK: - Recommendations

    @MainActor
    private func refreshRecommendations(force: Bool) async {
        guard enablePersonalizedRecommendations else { return }
        if force || recommendations.isEmpty { isLoadingRecommendations = true }
        recommendationsError = nil

        do {
            let items = try await recommendationService.recommendations(
                forceRefresh: force,
                contentType: .moviesAndShows
            )
            recommendations = items
            isLoadingRecommendations = false
            applySnapshot(animated: false)
        } catch {
            recommendations = []
            recommendationsError = error.localizedDescription
            isLoadingRecommendations = false
            applySnapshot(animated: false)
        }
    }

    // MARK: - Direct play

    /// Mirrors the SwiftUI `playItemDirectly` flow including the
    /// resume-or-restart prompt (when `promptResumeOrRestart` is on).
    private func playItemDirectly(_ item: PlexMetadata, fromBeginning: Bool = false) {
        if promptResumeOrRestart,
           !fromBeginning,
           item.isInProgress,
           let offsetMs = item.viewOffset, offsetMs > 0 {
            presentResumeChoice(for: item, offsetMs: offsetMs)
        } else {
            presentPlayer(for: item, fromBeginning: fromBeginning)
        }
    }

    private func presentResumeChoice(for item: PlexMetadata, offsetMs: Int) {
        let alert = UIAlertController(
            title: "Resume Playback?",
            message: nil,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Resume from \(PlexMetadata.formatResumeTime(offsetMs))", style: .default) { [weak self] _ in
            self?.presentPlayer(for: item, fromBeginning: false)
        })
        alert.addAction(UIAlertAction(title: "Start from Beginning", style: .default) { [weak self] _ in
            self?.presentPlayer(for: item, fromBeginning: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func presentPlayer(for item: PlexMetadata, fromBeginning: Bool) {
        Task { @MainActor in
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }

            let request = item.heroBackdropRequest(serverURL: serverURL, authToken: token)
            let (artImage, thumbImage) = await HeroBackdropResolver.shared.playerLoadingImages(for: request)

            let resumeOffset: Double? = fromBeginning ? nil : item.viewOffset.map { Double($0) / 1000.0 }
            let viewModel = UniversalPlayerViewModel(
                metadata: item,
                serverURL: serverURL,
                authToken: token,
                startOffset: (resumeOffset ?? 0) > 0 ? resumeOffset : nil,
                loadingArtImage: artImage,
                loadingThumbImage: thumbImage
            )
            let useApplePlayer = UserDefaults.standard.bool(forKey: "useApplePlayer")
            let playerVC: UIViewController
            if useApplePlayer {
                let nativePlayer = NativePlayerViewController(viewModel: viewModel)
                nativePlayer.onDismiss = { [weak self] in
                    Task { await self?.dataStore.refreshHubs() }
                }
                playerVC = nativePlayer
            } else {
                let inputCoordinator = PlaybackInputCoordinator()
                let playerView = UniversalPlayerView(viewModel: viewModel, inputCoordinator: inputCoordinator)
                let container = PlayerContainerViewController(
                    rootView: playerView,
                    viewModel: viewModel,
                    inputCoordinator: inputCoordinator
                )
                container.onDismiss = { [weak self] in
                    Task { await self?.dataStore.refreshHubs() }
                }
                playerVC = container
            }

            // Walk up to the topmost presented controller so we don't try to
            // present from a stale parent (covers re-entry after dismiss).
            var topVC: UIViewController = self
            while let presented = topVC.presentedViewController { topVC = presented }
            topVC.present(playerVC, animated: true)
        }
    }

    // MARK: - Selection / navigation

    /// Tile-tap router. Continue Watching tiles play directly; other tiles
    /// open the preview carousel. Hero buttons route through their own
    /// callbacks (`onInfo` -> `selectPlexItem`, `onPlay` -> `playItemDirectly`).
    private func handleTap(at indexPath: IndexPath) {
        guard indexPath.section < sectionsSnapshot.count else { return }
        let section = sectionsSnapshot[indexPath.section]

        // Ignore taps on the skeleton placeholder.
        if let itemID = dataSource.itemIdentifier(for: indexPath),
           itemID.itemID == HomeItemID.skeletonSentinel {
            return
        }

        switch section.kind {
        case .hero, .recommendationsLoading, .recommendationsError:
            return  // hero overlay + state cells handle their own input
        case .continueWatching:
            guard indexPath.item < section.plexItems.count else { return }
            playItemDirectly(section.plexItems[indexPath.item])
        case .recentlyAdded, .recommendations:
            guard indexPath.item < section.plexItems.count else { return }
            presentPreview(forSection: section, indexPath: indexPath)
        case .watchlist:
            guard indexPath.item < section.watchlistItems.count else { return }
            Task { await openWatchlistPreview(section: section, tappedIndex: indexPath.item, indexPath: indexPath) }
        }
    }

    private func selectPlexItem(_ meta: PlexMetadata) {
        switch meta.type {
        case "artist", "album":
            onSelectMusic?(meta)
        case "track":
            playMusicTrack(meta)
        default:
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }
            let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
            let item = PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
            onSelectItem?(item)
        }
    }

    /// Open the new UIKit detail page (`MediaItemDetailPageViewController`) for a
    /// hero item — the hero Info ("i") button. Mirrors how the carousel presents
    /// the same page. Play inside the page closes it first, then routes to the
    /// hero's normal play flow (so the player / resume prompt isn't presented
    /// underneath the detail page).
    private func presentDetailPage(for meta: PlexMetadata) {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
        let item = PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
        let page = MediaItemDetailPageViewController(
            item: item,
            seriesTitle: nil,
            onPlay: { [weak self] _ in
                self?.dismiss(animated: true) { self?.playItemDirectly(meta) }
            }
        )
        present(page, animated: true)
    }

    private func playMusicTrack(_ plexMeta: PlexMetadata) {
        guard let provider = MusicProviderRegistry.shared.primaryProvider,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let track = PlexMusicMapper.track(plexMeta, providerID: provider.id, serverURL: serverURL, authToken: token)
        MusicQueue.shared.playNow(track: track)
    }

    // MARK: - Preview presentation

    private func presentPreview(forSection section: HomeSectionData, indexPath: IndexPath) {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
        let mediaItems = section.plexItems.map {
            PlexMediaMapper.item($0, providerID: providerID, serverURL: serverURL, authToken: token)
        }
        guard indexPath.item < section.plexItems.count else { return }
        let tappedMeta = section.plexItems[indexPath.item]
        let sourceItemID = tappedMeta.ratingKey ?? "\(section.id.raw)-\(indexPath.item)"

        presentPreviewOverlay(
            items: mediaItems,
            selectedIndex: indexPath.item,
            sourceRowID: section.id.raw,
            sourceItemID: sourceItemID,
            sourceIndexPath: indexPath
        )
    }

    private func openWatchlistPreview(section: HomeSectionData, tappedIndex: Int, indexPath: IndexPath) async {
        let entries = section.watchlistItems
        let pairs = await buildWatchlistMediaItems(from: entries)
        guard !pairs.isEmpty else { return }

        let tapped = entries[tappedIndex]
        // Match on the originating watchlist entry id — robust across both
        // library-matched (Plex ratingKey) and TMDB-only itemID encodings,
        // and tolerant of entries that get skipped during mapping. Mirrors
        // SwiftUI WatchlistHubRow's tap-resolution fix (commit `bb15fdb`).
        let validIndex = pairs.firstIndex(where: { $0.sourceID == tapped.id }) ?? 0
        let mediaItems = pairs.map(\.item)
        presentPreviewOverlay(
            items: mediaItems,
            selectedIndex: validIndex,
            sourceRowID: section.id.raw,
            sourceItemID: tapped.id,
            sourceIndexPath: indexPath
        )
    }

    /// Mirrors `WatchlistHubRow.buildMediaItems(from:)` — parallel library
    /// lookups against the GUID index, with TMDB fallback for unmatched
    /// entries. Returns `(sourceID, item)` pairs so callers can match on
    /// the originating watchlist entry id (see `openWatchlistPreview`).
    private func buildWatchlistMediaItems(from entries: [PlexWatchlistItem]) async -> [(sourceID: String, item: MediaItem)] {
        let serverURL = authManager.selectedServerURL ?? ""
        let token = authManager.selectedServerToken ?? ""
        let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"

        let lookups = await withTaskGroup(of: (Int, PlexMetadata?).self) { group in
            for (index, entry) in entries.enumerated() {
                guard let tmdbId = entry.tmdbId else { continue }
                let mediaType: TMDBMediaType = entry.type == .movie ? .movie : .tv
                group.addTask {
                    let match = await LibraryGUIDIndex.shared.lookup(tmdbId: tmdbId, type: mediaType)
                    return (index, match)
                }
            }
            var out: [Int: PlexMetadata] = [:]
            for await (index, match) in group {
                if let match { out[index] = match }
            }
            return out
        }

        var result: [(sourceID: String, item: MediaItem)] = []
        result.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            guard let tmdbId = entry.tmdbId else { continue }
            let mediaType: TMDBMediaType = entry.type == .movie ? .movie : .tv

            if let match = lookups[index], !serverURL.isEmpty {
                result.append((
                    sourceID: entry.id,
                    item: PlexMediaMapper.item(match,
                                               providerID: providerID,
                                               serverURL: serverURL,
                                               authToken: token)
                ))
                continue
            }

            let stub = TMDBListItem(
                id: tmdbId,
                title: entry.title,
                overview: nil,
                posterPath: nil,
                backdropPath: nil,
                releaseDate: entry.year.map { "\($0)" },
                voteAverage: nil,
                mediaType: mediaType
            )
            var built = TMDBMediaMapper.item(stub)
            if let poster = entry.posterURL {
                built = MediaItem(
                    ref: built.ref,
                    kind: built.kind,
                    title: built.title,
                    sortTitle: built.sortTitle,
                    overview: built.overview,
                    year: built.year,
                    releaseDate: built.releaseDate,
                    contentRating: built.contentRating,
                    runtime: built.runtime,
                    parentRef: built.parentRef,
                    grandparentRef: built.grandparentRef,
                    episodeNumber: built.episodeNumber,
                    seasonNumber: built.seasonNumber,
                    childProgress: built.childProgress,
                    userState: built.userState,
                    artwork: MediaArtwork(
                        poster: poster,
                        backdrop: built.artwork.backdrop,
                        thumbnail: poster,
                        logo: built.artwork.logo
                    ),
                    parentArtwork: built.parentArtwork,
                    grandparentArtwork: built.grandparentArtwork
                )
            }
            result.append((sourceID: entry.id, item: built))
        }
        return result
    }

    private func presentPreviewOverlay(
        items: [MediaItem],
        selectedIndex: Int,
        sourceRowID: String,
        sourceItemID: String,
        sourceIndexPath: IndexPath
    ) {
        let request = PreviewRequest(
            items: items,
            selectedIndex: selectedIndex,
            sourceRowID: sourceRowID,
            sourceItemID: sourceItemID
        )

        // Capture the source cell's frame in window coordinates so the
        // entry-morph (SwiftUI or UIKit) has something to interpolate from.
        var sourceFrames: [PreviewSourceTarget: CGRect] = [:]
        let sourceTarget = PreviewSourceTarget(rowID: sourceRowID, itemID: sourceItemID)
        if let attrs = collectionView.layoutAttributesForItem(at: sourceIndexPath),
           let window = view.window {
            let inCollection = attrs.frame
            let inWindow = collectionView.convert(inCollection, to: window)
            sourceFrames[sourceTarget] = inWindow
        }

        // Flag-gated UIKit branch — when PreviewImplPreference is .uikit,
        // present the new PreviewCarouselViewController instead of the
        // SwiftUI PreviewOverlayHost. Default is currently .uikit during
        // perf-spike active iteration (see HomeImplPreference.swift).
        if PreviewImplPreference.current == .uikit {
            let carouselVC = PreviewCarouselViewController(
                items: items,
                selectedIndex: selectedIndex,
                sourceFrame: sourceFrames[sourceTarget] ?? .zero,
                sourceTarget: sourceTarget,
                onDismiss: { [weak self] sourceTarget in
                    self?.pendingPreviewRestore = sourceTarget
                }
            )
            var topVC: UIViewController = self
            while let presented = topVC.presentedViewController { topVC = presented }
            // animated: false — the carousel's spring morph IS the
            // transition. Modal transitions would compose on top.
            topVC.present(carouselVC, animated: false) {
            }
            return
        }

        let menuBridge = PreviewMenuBridge()

        let previewContent = PreviewOverlayHost(
            request: request,
            sourceFrames: sourceFrames,
            onDismiss: { [weak self] sourceTarget in
                _ = menuBridge  // retain
                self?.pendingPreviewRestore = sourceTarget
                self?.dismissPresentedPreview()
            },
            menuBridge: menuBridge
        )

        let contentWithRegistries = previewContent
            .environment(MediaProviderRegistry.shared)
            .environment(MusicProviderRegistry.shared)
            .environment(MetadataSourceRegistry.shared)

        let container = PreviewContainerViewController(
            content: contentWithRegistries,
            menuHandler: { menuBridge.triggerMenu() }
        )
        container.onDismiss = { [weak self] in
            self?.applyPendingPreviewRestoreIfNeeded()
        }

        var topVC: UIViewController = self
        while let presented = topVC.presentedViewController { topVC = presented }
        topVC.present(container, animated: false)
    }

    private func dismissPresentedPreview() {
        var topVC: UIViewController = self
        while let presented = topVC.presentedViewController { topVC = presented }
        if let preview = topVC as? PreviewContainerViewController {
            preview.dismissPreview()
        }
    }

    // MARK: - Focus restoration after preview dismiss

    private func applyPendingPreviewRestoreIfNeeded() {
        guard let target = pendingPreviewRestore else { return }
        guard let indexPath = indexPath(for: target) else {
            pendingPreviewRestore = nil
            return
        }
        pendingPreviewRestore = nil
        // Defer to next runloop so the preview-dismiss layout pass finishes
        // before we ask the focus engine to update.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.collectionView.scrollToItem(at: indexPath, at: [.centeredVertically, .centeredHorizontally], animated: false)
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
        }
    }

    private func indexPath(for target: PreviewSourceTarget) -> IndexPath? {
        guard let sectionIndex = sectionsSnapshot.firstIndex(where: { $0.id.raw == target.rowID }) else { return nil }
        let section = sectionsSnapshot[sectionIndex]
        switch section.kind {
        case .hero, .recommendationsLoading, .recommendationsError:
            return nil
        case .continueWatching, .recentlyAdded, .recommendations:
            if let itemIndex = section.plexItems.firstIndex(where: { $0.ratingKey == target.itemID }) {
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
        case .watchlist:
            if let itemIndex = section.watchlistItems.firstIndex(where: { $0.id == target.itemID }) {
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
        }
        return nil
    }

    // MARK: - Scroll-on-focus

    /// Snap the collection view to the top so the hero overlay sits at the
    /// top of the screen and the Continue Watching peek shows below.
    private func scrollHeroIntoView() {
        let targetY = -collectionView.adjustedContentInset.top
        guard collectionView.contentOffset.y != targetY else { return }
        animateContentOffset(toY: targetY)
    }

    /// Centre a row vertically so the focused tile sits roughly mid-screen.
    /// Matches the SwiftUI version's `scrollTo(rowID, anchor: .center)`.
    private func scrollSectionIntoView(sectionIndex: Int) {
        guard sectionsSnapshot.indices.contains(sectionIndex) else { return }
        // Find any layout attribute belonging to this section to derive its
        // vertical centre. Falls back to the section's first item.
        let firstItemPath = IndexPath(item: 0, section: sectionIndex)
        guard let attrs = collectionView.layoutAttributesForItem(at: firstItemPath) else { return }
        let target = attrs.frame.midY - collectionView.bounds.height / 2
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        let clamped = max(-collectionView.adjustedContentInset.top, min(target, maxOffset))
        guard abs(collectionView.contentOffset.y - clamped) > 1 else { return }
        animateContentOffset(toY: clamped)
    }

    // MARK: - Per-frame vertical scroll driver

    // `UIView.animate { setContentOffset }` only animates the PRESENTATION layer:
    // the model contentOffset jumps to the target immediately, so the collection
    // recycles cells based on the final offset and a row that lands off-screen has
    // its cells removed at once — it "pops" before finishing its slide-out (worse
    // here because the collection is clipsToBounds=false, so off-bounds cells are
    // visible). A CADisplayLink advancing the real offset per frame recycles cells
    // progressively, so rows scroll out smoothly.
    private var offsetLink: CADisplayLink?
    private var offsetStartY: CGFloat = 0
    private var offsetTargetY: CGFloat = 0
    private var offsetStartTime: CFTimeInterval = 0
    private let offsetDuration: CFTimeInterval = FocusScrollMotion.settleDuration

    private func animateContentOffset(toY targetY: CGFloat) {
        offsetLink?.invalidate()
        offsetStartY = collectionView.contentOffset.y   // continue from current position
        offsetTargetY = targetY
        offsetStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepOffset))
        link.add(to: .main, forMode: .common)
        offsetLink = link
    }

    @objc private func stepOffset(_ link: CADisplayLink) {
        let t = offsetDuration > 0 ? min(1, (CACurrentMediaTime() - offsetStartTime) / offsetDuration) : 1
        let e = FocusScrollMotion.ease(t)   // shared focus-scroll curve (cubic ease-out)
        collectionView.contentOffset = CGPoint(x: 0, y: offsetStartY + (offsetTargetY - offsetStartY) * CGFloat(e))
        if t >= 1 {
            link.invalidate()
            offsetLink = nil
            collectionView.contentOffset = CGPoint(x: 0, y: offsetTargetY)
        }
    }

    // MARK: - UIFocusEnvironment override

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Route the focus update at restoration time toward the right cell.
        if let target = pendingPreviewRestore,
           let indexPath = indexPath(for: target),
           let cell = collectionView.cellForItem(at: indexPath) {
            return [cell]
        }
        return super.preferredFocusEnvironments
    }
}

// MARK: - Delegate

extension PlexHomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        handleTap(at: indexPath)
    }

    /// Block Left-press focus escapes from a horizontally-scrolling row
    /// when there are still cells to the left in the same row that have
    /// scrolled offscreen.
    ///
    /// Bug: with `orthogonalScrollingBehavior = .continuous`, cells that
    /// scroll outside the orthogonal viewport are removed from the focus
    /// chain entirely. When the user presses Left on (say) item 8 of 20,
    /// the focus engine doesn't see items 0–6 (offscreen, dequeued), so
    /// it falls through to whatever is to the left of the collection
    /// view — the sidebar. The sidebar briefly reveals before some other
    /// focus mechanism snaps focus back. Annoying flicker.
    ///
    /// Fix: intercept the Left update. If the previously-focused cell is
    /// not at item 0 of its section, block the system update and instead
    /// scroll-to + focus the cell at `indexPath.item - 1`. The orthogonal
    /// scroll view brings that cell back into the viewport so it can
    /// regain focus.
    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        guard context.focusHeading == .left,
              let prevIndexPath = context.previouslyFocusedIndexPath,
              prevIndexPath.section < sectionsSnapshot.count,
              prevIndexPath.item > 0
        else { return true }

        // Only intercept for orthogonally-scrolling rows.
        let section = sectionsSnapshot[prevIndexPath.section]
        switch section.kind {
        case .continueWatching, .recentlyAdded, .watchlist, .recommendations:
            break
        case .hero, .recommendationsLoading, .recommendationsError:
            return true
        }

        // Only intercept when focus is trying to leave the collection
        // view entirely (e.g. into the sidebar). If the next focus is
        // still inside our collection view, the engine has already
        // picked the right neighbour and we let it through.
        let nextIsInside = context.nextFocusedView?.isDescendant(of: collectionView) ?? false
        guard !nextIsInside else { return true }

        // Block the system update and bring the target cell into view.
        // The focus engine will re-poll on next runloop, find the
        // now-visible neighbour, and land focus there. We scroll the
        // orthogonal section non-animated so the cell is in the view
        // hierarchy by the time the engine runs again.
        let target = IndexPath(item: prevIndexPath.item - 1, section: prevIndexPath.section)
        collectionView.scrollToItem(at: target, at: .left, animated: false)
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
        return false
    }

    /// Mirrors SwiftUI InfiniteContentRow's `.onAppear` pagination trigger
    /// (`PlexHomeView.swift:1328-1335`): when a card within 5 items of
    /// the end displays, fire `loadMoreIfNeeded()` for its section.
    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard indexPath.section < sectionsSnapshot.count else { return }
        let section = sectionsSnapshot[indexPath.section]
        switch section.kind {
        case .hero, .watchlist, .recommendations,
             .recommendationsLoading, .recommendationsError:
            return  // No pagination for these (matches SwiftUI hubKey == nil)
        case .continueWatching, .recentlyAdded:
            break
        }
        let total = section.plexItems.count
        guard indexPath.item >= total - 5 else { return }
        Task { @MainActor in await self.loadMoreIfNeeded(sectionID: section.id, hubKey: section.hubKey, hubIdentifier: section.hubIdentifier) }
    }

    /// Long-press / hold on a tile surfaces a UIMenu. Mirrors
    /// `MediaItemContextMenu` (`MediaItemContextMenu.swift:30`) and the
    /// CW-specific override in `ContinueWatchingContextMenuModifier`
    /// (`PlexHomeView.swift:1037`). tvOS 17+ uses the `Items` (plural)
    /// signature — we just use the first index since we don't support
    /// multi-selection on the home.
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              indexPath.section < sectionsSnapshot.count
        else { return nil }
        // Skeleton placeholder doesn't get a context menu.
        if let itemID = dataSource.itemIdentifier(for: indexPath),
           itemID.itemID == HomeItemID.skeletonSentinel {
            return nil
        }
        let section = sectionsSnapshot[indexPath.section]
        switch section.kind {
        case .hero, .watchlist, .recommendationsLoading, .recommendationsError:
            return nil  // hero / watchlist / state cells don't get menus
        case .continueWatching, .recentlyAdded, .recommendations:
            guard indexPath.item < section.plexItems.count else { return nil }
            let item = section.plexItems[indexPath.item]
            let isCW = section.kind == .continueWatching
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.buildContextMenu(for: item, isContinueWatching: isCW)
            }
        }
    }

    // MARK: - Context-menu builder

    /// Build the UIMenu for a cell. Mirrors SwiftUI MediaItemContextMenu's
    /// action set, including the conditional Mark-as-Watched / Unwatched
    /// branching and the CW-specific Remove + Go-to-Episode override.
    private func buildContextMenu(for item: PlexMetadata, isContinueWatching: Bool) -> UIMenu {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = item.ratingKey
        else { return UIMenu(children: []) }

        let network = PlexNetworkManager.shared
        var actions: [UIMenuElement] = []

        if isContinueWatching {
            // SwiftUI ContinueWatchingContextMenuModifier (PlexHomeView.swift:1037)
            // has its own action ordering: Watch from Beginning, Go to
            // Episode, Mark as Watched, Remove from Continue Watching,
            // Refresh Metadata.
            actions.append(UIAction(title: "Watch from Beginning",
                                    image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
                self?.playItemDirectly(item, fromBeginning: true)
            })
            actions.append(UIAction(title: "Go to Episode",
                                    image: UIImage(systemName: "info.circle")) { [weak self] _ in
                self?.selectPlexItem(item)
            })

            let markWatched = UIAction(title: "Mark as Watched",
                                       image: UIImage(systemName: "rectangle.badge.checkmark")) { [weak self] _ in
                self?.performMenuAction(optimisticWatched: true) {
                    try await network.markWatched(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                }
            }
            let removeFromCW = UIAction(title: "Remove from Continue Watching",
                                        image: UIImage(systemName: "trash"),
                                        attributes: [.destructive]) { [weak self] _ in
                self?.performMenuAction {
                    try await network.removeFromContinueWatching(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                }
            }
            actions.append(contentsOf: [
                UIMenu(options: .displayInline, children: [markWatched]),
                UIMenu(options: .displayInline, children: [removeFromCW])
            ])

            actions.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Refresh Metadata",
                         image: UIImage(systemName: "arrow.clockwise")) { _ in
                    Task {
                        try? await network.refreshMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                    }
                }
            ]))
            return UIMenu(children: actions)
        }

        // Generic media-item menu (Recently Added, Recommendations).

        // Watch from Beginning. SwiftUI fires markUnwatched here to clear
        // viewOffset — odd action name vs. behavior, but we match exactly.
        actions.append(UIAction(title: "Watch from Beginning",
                                image: UIImage(systemName: "play.fill")) { [weak self] _ in
            self?.performMenuAction(optimisticWatched: false) {
                try await network.markUnwatched(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
            }
        })

        // Mark as Watched / Unwatched — conditional on view state.
        let viewCount = item.viewCount ?? 0
        if viewCount == 0 || item.watchProgress != nil {
            actions.append(UIAction(title: "Mark as Watched",
                                    image: UIImage(systemName: "eye.fill")) { [weak self] _ in
                self?.performMenuAction(optimisticWatched: true) {
                    try await network.markWatched(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                }
            })
        }
        if viewCount > 0 {
            actions.append(UIAction(title: "Mark as Unwatched",
                                    image: UIImage(systemName: "eye.slash.fill")) { [weak self] _ in
                self?.performMenuAction(optimisticWatched: false) {
                    try await network.markUnwatched(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                }
            })
        }

        // Episode-only Go to navigation.
        if item.type == "episode" {
            if item.parentRatingKey != nil {
                actions.append(UIAction(title: "Go to Season",
                                        image: UIImage(systemName: "list.number")) { [weak self] _ in
                    self?.selectPlexItem(item)  // detail view handles per-type routing
                })
            }
            if item.grandparentRatingKey != nil {
                actions.append(UIAction(title: "Go to Show",
                                        image: UIImage(systemName: "tv")) { [weak self] _ in
                    self?.selectPlexItem(item)
                })
            }
        }

        // More Info (navigate to detail view).
        actions.append(UIAction(title: "More Info",
                                image: UIImage(systemName: "info.circle")) { [weak self] _ in
            self?.selectPlexItem(item)
        })

        // Refresh Metadata (always last).
        actions.append(UIAction(title: "Refresh Metadata",
                                image: UIImage(systemName: "arrow.clockwise")) { _ in
            Task {
                try? await network.refreshMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
            }
        })

        return UIMenu(children: actions)
    }

    /// Performs a context-menu action with optional optimistic-watched
    /// update + a hubs refresh after completion. Mirrors SwiftUI's
    /// `performAction(optimisticWatched:_:)` (`MediaItemContextMenu.swift:164`).
    private func performMenuAction(optimisticWatched: Bool? = nil,
                                   _ action: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await action()
            } catch {}
            await dataStore.refreshHubs()
            await dataStore.refreshLibraryHubs()
        }
    }

    // MARK: - Pagination

    /// Load the next page of items for a paginating hub section. Mirror
    /// of SwiftUI `InfiniteContentRow.loadMoreIfNeeded()`
    /// (`PlexHomeView.swift:1436-1496`).
    @MainActor
    private func loadMoreIfNeeded(sectionID: HomeSectionID, hubKey: String?, hubIdentifier: String?) async {
        guard var state = paginationStates[sectionID],
              !state.isLoadingMore,
              !state.hasReachedEnd,
              let hubKey, !hubKey.isEmpty
        else { return }

        if let total = state.totalSize, state.loadedItems.count >= total {
            state.hasReachedEnd = true
            paginationStates[sectionID] = state
            return
        }

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        state.isLoadingMore = true
        paginationStates[sectionID] = state
        applySnapshot(animated: false)  // show skeleton

        do {
            let result = try await PlexNetworkManager.shared.getHubItems(
                serverURL: serverURL,
                authToken: token,
                hubKey: hubKey,
                hubIdentifier: hubIdentifier,
                start: state.loadedItems.count,
                count: paginationPageSize
            )

            // Refetch state in case anything else (refresh, etc.) mutated
            // it while we awaited the network call.
            var freshState = paginationStates[sectionID] ?? state
            freshState.isLoadingMore = false
            if let size = result.totalSize {
                freshState.totalSize = size
            }
            if result.items.isEmpty {
                freshState.hasReachedEnd = true
            } else {
                // Dedupe by ratingKey (SwiftUI does the same).
                let existingKeys = Set(freshState.loadedItems.compactMap { $0.ratingKey })
                let newItems = result.items.filter { item in
                    guard let key = item.ratingKey else { return false }
                    return !existingKeys.contains(key)
                }
                if newItems.isEmpty {
                    freshState.hasReachedEnd = true
                } else {
                    freshState.loadedItems.append(contentsOf: newItems)
                    if let total = freshState.totalSize,
                       freshState.loadedItems.count >= total {
                        freshState.hasReachedEnd = true
                    }
                }
            }
            paginationStates[sectionID] = freshState
            applySnapshot(animated: false)
        } catch {
            // SwiftUI doesn't mark hasReachedEnd on error -- user can
            // retry by continuing to scroll.
            var freshState = paginationStates[sectionID] ?? state
            freshState.isLoadingMore = false
            paginationStates[sectionID] = freshState
            applySnapshot(animated: false)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        backdropView.applyScrollOffset(offset)
        // Parallax the hero paging dots up so they don't sink too low when the
        // page scrolls below the hero: they ride the content at 1x while the
        // backdrop recedes at 1.4x, so without this they fall behind the image.
        for case let heroCell as HeroOverlayCell in collectionView.visibleCells {
            heroCell.overlay.applyScrollOffset(offset)
        }
    }

    /// Auto-scroll to keep the focused row visible — mirrors the SwiftUI
    /// version's `onRowFocused` (`scrollProxy.scrollTo(rowID, anchor: .center)`).
    /// We watch UIKit focus updates and centre the focused row in the
    /// vertical viewport. The orthogonal (horizontal) scroll inside a row
    /// is handled by `UICollectionView` automatically.
    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        // Resolve the section that owns the newly-focused view.
        guard let nextSectionIndex = focusedSectionIndex(in: context) else {
            updateLeftEdgeGuide(for: nil)
            return
        }
        let isHero = sectionsSnapshot.indices.contains(nextSectionIndex) &&
                     sectionsSnapshot[nextSectionIndex].kind == .hero
        if isHero {
            scrollHeroIntoView()
        } else {
            scrollSectionIntoView(sectionIndex: nextSectionIndex)
        }
        updateLeftEdgeGuide(for: context.nextFocusedIndexPath)
    }

    /// Re-aim the leading-edge `UIFocusGuide` based on the newly-focused
    /// cell. See property doc on `leftEdgeFocusGuide` for the bug it
    /// prevents.
    private func updateLeftEdgeGuide(for indexPath: IndexPath?) {
        guard let indexPath,
              indexPath.section < sectionsSnapshot.count,
              indexPath.item > 0
        else {
            // No cell focused, or focus is on item 0 of a row, or out of
            // bounds — let the guide be transparent so Left can escape.
            leftEdgeFocusGuide.preferredFocusEnvironments = []
            return
        }
        let section = sectionsSnapshot[indexPath.section]
        switch section.kind {
        case .continueWatching, .recentlyAdded, .watchlist, .recommendations:
            break
        case .hero, .recommendationsLoading, .recommendationsError:
            leftEdgeFocusGuide.preferredFocusEnvironments = []
            return
        }
        let target = IndexPath(item: indexPath.item - 1, section: indexPath.section)
        // Point the guide at the previous cell if it's already on screen.
        // Critically: DO NOT preemptively scroll the row to bring the
        // target into view -- that runs on every focus update (including
        // Right / Up / Down moves) and produces a "row keeps re-centering
        // under you" effect. UICollectionView prefetch usually keeps the
        // adjacent cell warm anyway; if it doesn't, the guide will fail
        // open (no redirect) and the system falls back to the existing
        // `shouldUpdateFocusIn:` block in commit `d181fd1` which handles
        // the discrete-Left case.
        if let cell = collectionView.cellForItem(at: target) {
            leftEdgeFocusGuide.preferredFocusEnvironments = [cell]
        } else {
            leftEdgeFocusGuide.preferredFocusEnvironments = []
        }
    }

    /// Returns the section index of the newly-focused view, looking either
    /// at the focused cell's indexPath (orthogonal rows) or — for the hero
    /// — at whichever section's overlay contains the focused button.
    private func focusedSectionIndex(in context: UICollectionViewFocusUpdateContext) -> Int? {
        if let nextIndexPath = context.nextFocusedIndexPath {
            return nextIndexPath.section
        }
        // `nextFocusedIndexPath` comes back nil at the collection level for two
        // cases here: (1) the hero, whose focusable Play/Info buttons live in a
        // SwiftUI subview rather than the cell itself, and (2) cells inside the
        // orthogonal (continuous) rows, which don't resolve to a collection-level
        // index path. Walk the focused view's superview chain to its enclosing
        // collection-view cell and read its section. This matters now that
        // `isScrollEnabled = false` hands us the vertical focus-scroll: the
        // engine no longer masks a nil section by scrolling on its own, so a
        // Down/Up move between orthogonal rows would otherwise fail to centre.
        var v: UIView? = context.nextFocusedView
        while let view = v {
            if let cell = view as? UICollectionViewCell,
               let ip = self.collectionView.indexPath(for: cell) {
                return ip.section
            }
            v = view.superview
        }
        return nil
    }
}
