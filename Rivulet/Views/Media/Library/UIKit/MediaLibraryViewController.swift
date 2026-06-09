//
//  MediaLibraryViewController.swift
//  Rivulet
//
//  Source-agnostic UIKit library browser. Replaces the SwiftUI PlexLibraryView
//  for any MediaProvider + MediaLibrary pair.
//
//  Architecture notes
//  ------------------
//  - Background: UIVisualEffectView(.regular) pinned to view edges (backmost),
//    same as PlexHomeViewController.backgroundBlurView. view.backgroundColor = .clear
//    so the blur samples through to whatever is behind the VC.
//  - Collection: FocusCenteringCollectionView (Task 1). isScrollEnabled = false;
//    self-driven vertical scroll via its CADisplayLink loop. Pinned edge-to-edge,
//    contentInsetAdjustmentBehavior = .never.
//  - State view: HomeStateView (reused from PlexHome) full-screen behind the collection.
//  - Sections: hero | row(id) | sortHeader (placeholder) | grid (placeholder).
//  - Layout: hero = screen - 200pt; row = orthogonal .continuous with home's tile
//    sizes, spacing, and insets (read from PlexHomeViewController code, NOT memory).
//  - Cell registrations: STORED as lazy properties per the tvOS CellRegistration rule
//    (registrations created inside the diffable provider closure crash on tvOS 15+).
//
//  Data loading, snapshot application, and sort/grid wiring live in the next task.
//

import UIKit

// MARK: - MediaLibraryViewController types
//
// Defined at file scope so their Hashable/Sendable conformances are NOT
// main-actor-isolated. Swift 6 strict concurrency requires the section and
// item identifier types passed to NSDiffableDataSourceSnapshot to be
// unconditionally Sendable; nesting them inside a @MainActor class makes
// their conformances main-actor-isolated, which the compiler rejects.

// `nonisolated` on the type declaration opts the entire type out of the
// module-wide @MainActor default, so Hashable/Sendable conformances are
// unconditionally available. NSDiffableDataSourceSnapshot requires both
// SectionIdentifierType and ItemIdentifierType to be Sendable without
// actor gating. (Pattern from HomeSectionID / HomeItemID in PlexHomeViewController.)
nonisolated enum MediaLibrarySectionKind: Hashable, Sendable {
    case hero
    case row(String)    // row id string
    case sortHeader
    case grid
}

nonisolated enum MediaLibraryItemID: Hashable, Sendable {
    /// Section-scoped item identity. `section` is the section's raw string key
    /// (e.g. "cw", "recent", the hub id, "grid") so the SAME MediaItem appearing
    /// in multiple sections (CW + a shelf hub + grid) yields DISTINCT identifiers
    /// and the diffable snapshot never throws a duplicate-identifier exception.
    /// Pattern mirrors HomeItemID(sectionID:itemID:) in PlexHomeViewController.
    case media(section: String, itemID: String)
    case placeholder(String) // zero-height grid placeholder — associated value ensures uniqueness across sections
    /// Sentinel for the sort-header cell. One per snapshot; never duplicated.
    case sortHeader
}

// MARK: - MediaLibraryViewController

@MainActor
final class MediaLibraryViewController: UIViewController {

    // MARK: - Config

    struct Config {
        var showHero = false
        var showRecommendations = true
        var showRecentRows = true
    }

    // MARK: - Convenience typealiases

    typealias SectionKind = MediaLibrarySectionKind
    typealias ItemID = MediaLibraryItemID

    // MARK: - Public interface

    var onSelectItem: ((MediaItem) -> Void)?

    // MARK: - Init

    private let provider: any MediaProvider
    private let library: MediaLibrary
    private let config: Config

    init(provider: any MediaProvider, library: MediaLibrary, config: Config) {
        self.provider = provider
        self.library = library
        self.config = config
        super.init(nibName: nil, bundle: nil)
        // Restore the persisted sort for this library before the first grid load
        // (which runs in viewDidLoad via startLoading). Falls back to .addedAtDesc
        // if no sort has been saved yet.
        self.sort = LibrarySettingsManager.shared.getMediaSortOption(for: library.id) ?? .addedAtDesc
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Section / data model

    struct RowData: Hashable {
        let id: String
        let title: String
        let items: [MediaItem]
        let isContinueWatching: Bool
    }

    // Data backing.
    private var heroItems: [MediaItem] = []
    private var rows: [RowData] = []
    // gridItems and totalGridCount are populated by loadGridFirstPage() but NOT
    // included in the snapshot until Task 11 makes the grid section visible.
    // Deferring them avoids off-screen cell churn on a zero-height section.
    private var gridItems: [MediaItem] = []
    private var totalGridCount = 0
    private var sort: SortOption = .addedAtDesc

    /// Combined loading task. Stored so it can be cancelled in viewWillDisappear
    /// and deinit. Never fire-and-forget.
    private var loadingTask: Task<Void, Never>?

    /// Prevents concurrent pagination requests. Set before the async fetch, cleared
    /// when the fetch completes (success or failure). Guards the willDisplay trigger.
    private var isLoadingNextPage = false

    // MARK: - State tracking (for updateLibraryState)

    /// True until the first full load group (rows + grid first page) completes.
    /// Set to true again when startLoading() restarts the load (e.g. retry).
    private var isInitialLoading = true

    /// Set when the grid first-page fetch throws a non-cancellation error.
    /// Cleared when a grid load succeeds or when the user triggers a retry.
    private var loadFailed = false

    // Focused index path forwarded by FocusCenteringCollectionView.
    private var focusedIndexPath: IndexPath?

    /// Tracks the hero carousel's current page so the info/play tap can open
    /// the carousel at the right index. Updated by the hero overlay's
    /// onIndexChanged callback. Defaults to 0 (first item).
    private var currentHeroIndex: Int = 0

    // MARK: - UI properties

    private var backgroundBlurView: UIVisualEffectView!
    /// Full-bleed hero backdrop. Sits between the blur and the collection;
    /// hidden when config.showHero is false. Mirrors PlexHomeViewController.backdropView.
    private var backdropView: HeroBackdropView!
    private var collectionView: FocusCenteringCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<SectionKind, ItemID>!
    private var stateView: HomeStateView!

    /// Sits at the leading edge of the collection view and absorbs fast
    /// Left-swipe focus moves that would otherwise escape to the sidebar
    /// mid-row. Updated in the onFocusedIndexPath / didUpdateFocus path:
    /// when the focused cell is at item 0 of its row (or in a non-orthogonal
    /// section), preferredFocusEnvironments = [] and the guide is transparent
    /// to the engine -- focus passes through to the sidebar normally. When
    /// the focused cell is item >= 1 of a horizontal row, the guide redirects
    /// focus to the cell at indexPath.item - 1 (if already on screen).
    /// Mirrors PlexHomeViewController.leftEdgeFocusGuide.
    private var leftEdgeFocusGuide: UIFocusGuide!

    // MARK: - Cell reuse identifiers
    //
    // Class-based dequeue (mirrors PlexHomeViewController). UICollectionViewDiffableDataSource
    // requires that any CellRegistration's Item type exactly matches the data source's
    // ItemIdentifierType. Our data source is keyed by MediaLibraryItemID, not MediaItem, so
    // CellRegistration<SomeCell, MediaItem> causes a UIKit assertion → SIGABRT on first render.
    // Class-based register/dequeue + manual configure() bypasses that type check entirely.
    //
    // Registrations are performed in configureCollectionView() and the placeholder reuse ID
    // is a plain string constant — no lazy CellRegistration properties needed.

    private static let placeholderReuseID = "library.placeholder"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear base so the blur effect samples through (same as PlexHomeViewController).
        view.backgroundColor = .clear

        configureBackground()
        configureBackdrop()
        configureCollectionView()
        configureStateOverlays()
        configureDataSource()

        // Kick off data loading. The stored Task is cancelled on disappear/deinit.
        startLoading()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadingTask?.cancel()
        loadingTask = nil
    }

    deinit {
        loadingTask?.cancel()
    }

    // MARK: - Data loading

    /// Starts the combined rows + grid load. Any prior task is cancelled first.
    private func startLoading() {
        loadingTask?.cancel()
        isInitialLoading = true
        loadFailed = false
        updateLibraryState()   // show loading overlay before any await
        loadingTask = Task { [weak self] in
            guard let self else { return }
            // Run rows and grid first-page concurrently.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in await self?.loadRows() }
                group.addTask { [weak self] in await self?.loadGridFirstPage() }
            }
            guard !Task.isCancelled else { return }
            // Both loaders done: mark initial load complete and resolve final state.
            self.isInitialLoading = false
            self.updateLibraryState()
        }
    }

    /// Fetches hubs, continueWatching, and recentlyAdded concurrently, builds
    /// the rows array, then applies the snapshot.
    private func loadRows() async {
        async let hubsFetch   = (try? await provider.hubs()) ?? []
        async let cwFetch     = (try? await provider.continueWatching(limit: 20)) ?? []
        async let recentFetch = (try? await provider.recentlyAdded(limit: 20)) ?? []

        let (hubs, cw, recent) = await (hubsFetch, cwFetch, recentFetch)

        // Check cancellation before touching main-actor state.
        guard !Task.isCancelled else { return }

        var built: [RowData] = []

        if !cw.isEmpty {
            built.append(RowData(id: "cw", title: "Continue Watching", items: cw, isContinueWatching: true))
        }
        if config.showRecentRows, !recent.isEmpty {
            built.append(RowData(id: "recent", title: "Recently Added", items: recent, isContinueWatching: false))
        }
        if config.showRecommendations {
            let shelfHubs = hubs.filter { $0.style == .shelf }
            built.append(contentsOf: shelfHubs.map {
                RowData(id: $0.id, title: $0.title, items: $0.items, isContinueWatching: false)
            })
        }

        rows = built

        if config.showHero {
            heroItems = hubs.first(where: { $0.style == .hero })?.items ?? recent
        }

        applySnapshot(animated: !rows.isEmpty)
        // Rows arrived — re-evaluate state; rows being non-empty may flip to content.
        updateLibraryState()
    }

    /// Fetches the first page of grid items into state. The snapshot does NOT
    /// include grid items yet — that is deferred to Task 11 when the grid section
    /// is made visible. This avoids off-screen cell churn on the zero-height section.
    private func loadGridFirstPage() async {
        do {
            let result = try await provider.items(
                in: library,
                sort: sort,
                page: Page(offset: 0, limit: 60)
            )

            guard !Task.isCancelled else { return }

            var seenIDs = Set<String>()
            gridItems = result.items.filter { seenIDs.insert($0.ref.itemID).inserted }
            totalGridCount = result.total
            loadFailed = false
        } catch {
            // Use Task.isCancelled rather than checking error type: the Plex provider
            // remaps every thrown error (including CancellationError / NSURLErrorCancelled)
            // into MediaProviderError.backendSpecific before it reaches this catch, so
            // `error is CancellationError` is always false. Task.isCancelled is true
            // whenever the surrounding loadingTask was cancelled (navigate away, sort
            // change, retry), regardless of the wrapped error type.
            if !Task.isCancelled { loadFailed = true }
        }

        guard !Task.isCancelled else { return }

        // NOTE: applySnapshot() is intentionally NOT called here.
        // Grid items enter the snapshot in Task 11 when the grid layout is wired.
        // Reconfigure the sort header so its count reflects totalGridCount once known.
        // reconfigureItems on the snapshot is a no-op if .sortHeader is not yet applied.
        var snap = dataSource.snapshot()
        if snap.itemIdentifiers(inSection: .sortHeader).contains(.sortHeader) {
            snap.reconfigureItems([.sortHeader])
            dataSource.apply(snap, animatingDifferences: false, completion: nil)
        }
        // Grid result (or error) is in — re-evaluate state.
        updateLibraryState()
    }

    // MARK: - Snapshot

    /// Builds and applies a diffable snapshot from the current data state.
    ///
    /// Item identity: every item is keyed as .media(section: sectionKey, itemID: ref.itemID).
    /// The `section` component scopes identity so the same MediaItem appearing in
    /// multiple sections (e.g. "Interstellar" in CW and a genre hub) produces
    /// distinct identifiers and never triggers a diffable duplicate-identifier crash.
    private func applySnapshot(animated: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<SectionKind, ItemID>()

        // Hero section (config.showHero defaults false — Task 7).
        if config.showHero, !heroItems.isEmpty {
            snapshot.appendSections([.hero])
            let rawHeroIDs = heroItems.map { ItemID.media(section: "hero", itemID: $0.ref.itemID) }
            // Dedup within section — mirrors PlexHomeViewController applySnapshot (lines 970-971).
            var heroSeen = Set<ItemID>()
            let heroIDs = rawHeroIDs.filter { heroSeen.insert($0).inserted }
            snapshot.appendItems(heroIDs, toSection: .hero)
        }

        // Hub row sections — one section per RowData.
        for row in rows {
            let section = SectionKind.row(row.id)
            snapshot.appendSections([section])
            let rawItemIDs = row.items.map { ItemID.media(section: row.id, itemID: $0.ref.itemID) }
            // Dedup within section — Plex hubs occasionally return the same ratingKey twice.
            // Keep first occurrence, drop the rest. Mirrors PlexHomeViewController applySnapshot.
            var seen = Set<ItemID>()
            let itemIDs = rawItemIDs.filter { seen.insert($0).inserted }
            snapshot.appendItems(itemIDs, toSection: section)
        }

        // sortHeader — one dedicated sentinel per snapshot. Always shown (library title + count).
        snapshot.appendSections([.sortHeader])
        snapshot.appendItems([.sortHeader], toSection: .sortHeader)

        // Grid section. When items have loaded they replace the placeholder so the
        // layout renders real poster cells. When gridItems is empty (initial load or
        // between a sort reset and the next fetch), the section is still present but
        // zero-height (makePlaceholderSection) with a single placeholder item —
        // this keeps the section stable across snapshot applies and avoids crashes
        // from a section disappearing while a snapshot diff is in flight.
        snapshot.appendSections([.grid])
        if gridItems.isEmpty {
            snapshot.appendItems([.placeholder("grid")], toSection: .grid)
        } else {
            var gridSeen = Set<ItemID>()
            let gridIDs = gridItems
                .map { ItemID.media(section: "grid", itemID: $0.ref.itemID) }
                .filter { gridSeen.insert($0).inserted }
            snapshot.appendItems(gridIDs, toSection: .grid)
        }

        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    // MARK: - Background

    private func configureBackground() {
        // Mirror of PlexHomeViewController.configureBackdrop() — backmost layer is
        // a standard tvOS frosted surface (UIBlurEffect .regular) pinned edge-to-edge.
        // Adapts to light/dark; non-interactive; always visible.
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
    }

    // MARK: - Backdrop (hero art layer between blur and collection)

    /// Mirrors PlexHomeViewController.configureBackdrop(). Adds HeroBackdropView
    /// as a full-bleed sibling in front of the blur but behind the collection.
    /// Hidden when config.showHero is false (the default), so it has no visual
    /// impact on the standard library route.
    private func configureBackdrop() {
        backdropView = HeroBackdropView()
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropView)
        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        backdropView.isHidden = !config.showHero
    }

    /// Update the backdrop from a MediaItem (called by the hero cell's onIndexChanged).
    /// Mirrors PlexHomeViewController.updateBackdrop(for:PlexMetadata) — uses
    /// item.artwork.backdrop (already a fully-resolved URL, no server/token needed).
    private func updateBackdrop(for item: MediaItem) {
        guard config.showHero else { return }
        let url = item.artwork.backdrop ?? item.artwork.thumbnail
        backdropView.setBackdrop(url: url)
    }

    // MARK: - Collection view

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] sectionIndex, layoutEnvironment in
            guard let self else { return nil }
            return self.makeLayoutSection(at: sectionIndex, layoutEnvironment: layoutEnvironment)
        }

        collectionView = FocusCenteringCollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.contentInsetAdjustmentBehavior = .never
        // isScrollEnabled = false: let FocusCenteringCollectionView's CADisplayLink
        // drive all vertical scrolling. Without this the focus engine runs its own
        // scroll animator that races our driver (two clocks writing contentOffset on
        // different curves = visible stutter). Same reasoning as PlexHomeViewController.
        collectionView.isScrollEnabled = false
        collectionView.clipsToBounds = false

        // Forward the focused index path for use by action handlers (next task).
        // Also re-aim the leading-edge focus guide on every focus change.
        collectionView.onFocusedIndexPath = { [weak self] indexPath in
            self?.focusedIndexPath = indexPath
            self?.updateLeftEdgeGuide(for: indexPath)
        }

        // Supplementary registration: row header via class (matches home's approach).
        collectionView.register(
            HubHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: HubHeaderView.reuseID
        )

        // Class-based cell registrations — mirrors PlexHomeViewController.
        collectionView.register(PosterCell.self, forCellWithReuseIdentifier: PosterCell.reuseID)
        collectionView.prefetchDataSource = self
        // Delegate re-added for willDisplay pagination. ONLY willDisplay is implemented;
        // didUpdateFocusIn is intentionally absent — the left-edge guide is driven
        // solely by FocusCenteringCollectionView.onFocusedIndexPath and a
        // UICollectionViewDelegate.didUpdateFocusIn would clobber that routing.
        collectionView.delegate = self
        collectionView.register(ContinueWatchingCell.self, forCellWithReuseIdentifier: ContinueWatchingCell.reuseID)
        collectionView.register(HeroOverlayCell.self, forCellWithReuseIdentifier: HeroOverlayCell.reuseID)
        collectionView.register(MediaLibrarySortControl.self, forCellWithReuseIdentifier: MediaLibrarySortControl.reuseID)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Self.placeholderReuseID)

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Leading-edge focus guide. See property doc for the why.
        // Mirrors PlexHomeViewController setup at ~line 589.
        leftEdgeFocusGuide = UIFocusGuide()
        view.addLayoutGuide(leftEdgeFocusGuide)
        NSLayoutConstraint.activate([
            leftEdgeFocusGuide.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            leftEdgeFocusGuide.widthAnchor.constraint(equalToConstant: 1),
            leftEdgeFocusGuide.topAnchor.constraint(equalTo: collectionView.topAnchor),
            leftEdgeFocusGuide.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor)
        ])
    }

    // MARK: - Compositional layout

    private func makeLayoutSection(at sectionIndex: Int, layoutEnvironment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        // The section ordering is driven by the snapshot applied in the next task.
        // For now we resolve by index from the current snapshot section identifiers.
        let sections = dataSource?.snapshot().sectionIdentifiers ?? []
        guard sectionIndex < sections.count else {
            // Fallback during skeleton phase (no snapshot yet): zero-height placeholder.
            return makePlaceholderSection()
        }
        switch sections[sectionIndex] {
        case .hero:
            return makeHeroSectionLayout(containerHeight: layoutEnvironment.container.effectiveContentSize.height)
        case .row(let id):
            let rowData = rows.first(where: { $0.id == id })
            let isCW = rowData?.isContinueWatching ?? false
            return makeRowSectionLayout(isContinueWatching: isCW, hasTitle: rowData?.title.isEmpty == false)
        case .sortHeader:
            return makeSortHeaderSectionLayout()
        case .grid:
            // Use the real multi-column layout when there are items; fall back to the
            // zero-height placeholder while the grid is empty (initial load / sort reset).
            return gridItems.isEmpty ? makePlaceholderSection() : makeGridSectionLayout()
        }
    }

    /// Hero section. Height mirrors PlexHomeViewController.makeHeroSectionLayout():
    ///   max(400, containerHeight - 200)
    /// with a 40pt bottom gap so the first row sits separated from the hero.
    private func makeHeroSectionLayout(containerHeight: CGFloat) -> NSCollectionLayoutSection {
        let height = max(400, containerHeight - 200)
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(height))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 40, trailing: 0)
        return section
    }

    /// Row (shelf) section. Tile sizes, spacing, and insets re-read verbatim from
    /// PlexHomeViewController.makeHubSectionLayout():
    ///   - Continue Watching: tileWidth 360, tileHeight 280, interGroupSpacing 16
    ///   - Other rows:        tileWidth 260, tileHeight 390, interGroupSpacing 30
    ///   - groupHeight = tileHeight + 80  (room for focus growth + shadow)
    ///   - contentInsets: top 12, leading 32, bottom 15, trailing 48
    ///   - Header: estimated height 40, .elementKindSectionHeader, .top alignment
    private func makeRowSectionLayout(isContinueWatching: Bool, hasTitle: Bool) -> NSCollectionLayoutSection {
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
        layoutSection.interGroupSpacing = isContinueWatching ? 16 : 30
        layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 32, bottom: 15, trailing: 48)

        if hasTitle {
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

    /// Full-width section for MediaLibrarySortControl.
    /// Height is estimated at 96pt (34pt title + 4pt gap + ~21pt count + 20+20pt vertical padding).
    /// Leading inset matches the row tiles (32pt) for visual alignment.
    private func makeSortHeaderSectionLayout() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(96)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 24, trailing: 0)
        return section
    }

    /// Zero-height placeholder for the grid section when it has no items.
    /// Kept so the section can stay in the snapshot without taking any space.
    private func makePlaceholderSection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(0))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        return NSCollectionLayoutSection(group: group)
    }

    /// Multi-column poster grid. Matches the home row tile size (260 x 390),
    /// inter-item / inter-group spacing (30pt), and leading (32) / trailing (48)
    /// insets — re-read verbatim from PlexHomeViewController.makeHubSectionLayout().
    /// 6 columns: 6 x 260 = 1560pt tiles + 5 x 30 = 150pt gaps + 32+48 = 80pt
    /// insets = 1790pt < 1920pt screen width, leaving ~130pt of focus-growth room.
    private func makeGridSectionLayout() -> NSCollectionLayoutSection {
        let tileWidth:  CGFloat = 260
        let tileHeight: CGFloat = 390
        // Group height adds 80pt for focus growth and shadow, matching the row layout.
        let groupHeight = tileHeight + 80

        // 6-across horizontal group (fractionalWidth 1/6 each item within the group).
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / 6.0),
            heightDimension: .absolute(groupHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .absolute(groupHeight)
        )
        // Horizontal group with explicit count fixes each row at 6 items regardless
        // of fractional rounding; subitems: [item] with count=6 distributes evenly.
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize,
                                                       repeatingSubitem: item,
                                                       count: 6)
        group.interItemSpacing = .fixed(30)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 30
        // Insets match the home row: top gives breathing room after the sort header,
        // leading/trailing mirror PlexHomeViewController row insets exactly.
        section.contentInsets = NSDirectionalEdgeInsets(top: 24, leading: 32, bottom: 48, trailing: 48)
        return section
    }

    // MARK: - Data source (minimal skeleton — snapshot application in next task)

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<SectionKind, ItemID>(
            collectionView: collectionView
        ) { [weak self] (collectionView: UICollectionView, indexPath: IndexPath, itemID: ItemID) -> UICollectionViewCell? in
            guard let self else { return nil }
            return self.cell(for: itemID, at: indexPath, in: collectionView)
        }

        dataSource.supplementaryViewProvider = { [weak self] (collectionView: UICollectionView, kind: String, indexPath: IndexPath) -> UICollectionReusableView? in
            guard let self,
                  kind == UICollectionView.elementKindSectionHeader else { return nil }
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: HubHeaderView.reuseID,
                for: indexPath
            ) as! HubHeaderView

            // Resolve the section title from the snapshot section identifier.
            let sections = self.dataSource.snapshot().sectionIdentifiers
            var title = ""
            if indexPath.section < sections.count,
               case .row(let rowID) = sections[indexPath.section],
               let rowData = self.rows.first(where: { $0.id == rowID }) {
                title = rowData.title
            }
            header.configure(title: title, style: .swiftUIInfiniteRow, loadedCount: 0, totalCount: nil)
            return header
        }

        // Empty initial snapshot — the collection starts with no sections.
        // applySnapshot() supplies all sections once data loads, so no
        // duplication and no layout-closure ambiguity before rows arrive.
        let snapshot = NSDiffableDataSourceSnapshot<SectionKind, ItemID>()
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func cell(
        for itemID: ItemID,
        at indexPath: IndexPath,
        in collectionView: UICollectionView
    ) -> UICollectionViewCell {
        // SHORT-CIRCUIT: items that carry no MediaItem are handled here before
        // resolve() is reached. This covers zero-height placeholders AND the
        // sort-header sentinel which has its own real cell class.
        if case .placeholder = itemID {
            return collectionView.dequeueReusableCell(
                withReuseIdentifier: Self.placeholderReuseID, for: indexPath)
        }
        if case .sortHeader = itemID {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MediaLibrarySortControl.reuseID,
                for: indexPath) as! MediaLibrarySortControl
            cell.configure(
                title: library.title,
                count: totalGridCount,
                sortName: sort.displayName
            )
            cell.onSortTapped = { [weak self] in self?.presentSortPicker() }
            return cell
        }

        // Section-scoped lookup: each .media(section:itemID:) carries the section
        // key so we search only the items array for that section. This is both
        // more efficient (no full flat scan) and correct when the same MediaItem
        // appears in multiple sections — we always return the right copy.
        func resolve() -> MediaItem {
            switch itemID {
            case .media(let section, let refID):
                switch section {
                case "hero":
                    if let item = heroItems.first(where: { $0.ref.itemID == refID }) { return item }
                case "grid":
                    if let item = gridItems.first(where: { $0.ref.itemID == refID }) { return item }
                default:
                    if let row = rows.first(where: { $0.id == section }),
                       let item = row.items.first(where: { $0.ref.itemID == refID }) {
                        return item
                    }
                }
                fatalError("MediaLibraryViewController: no MediaItem for section=\(section) itemID=\(refID)")
            case .placeholder(_):
                preconditionFailure("MediaLibraryViewController: placeholder reached resolve()")
            case .sortHeader:
                preconditionFailure("MediaLibraryViewController: .sortHeader reached resolve()")
            }
        }

        let sections = dataSource.snapshot().sectionIdentifiers
        guard indexPath.section < sections.count else {
            fatalError("MediaLibraryViewController: indexPath.section \(indexPath.section) out of range")
        }
        let item = resolve()

        switch sections[indexPath.section] {
        case .hero:
            // Class-based dequeue mirrors PlexHomeViewController hero branch.
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: HeroOverlayCell.reuseID, for: indexPath) as! HeroOverlayCell
            let config = HeroOverlayCell.MediaItemConfiguration(
                items: heroItems,
                initialIndex: 0,
                onIndexChanged: { [weak self] idx, changedItem in
                    self?.currentHeroIndex = idx
                    self?.updateBackdrop(for: changedItem)
                },
                onPlay: { [weak self] _ in
                    self?.presentCarousel(items: self?.heroItems ?? [], selectedIndex: self?.currentHeroIndex ?? 0, sourceFrame: .zero)
                },
                onInfo: { [weak self] _ in
                    self?.presentCarousel(items: self?.heroItems ?? [], selectedIndex: self?.currentHeroIndex ?? 0, sourceFrame: .zero)
                }
            )
            cell.configure(withMediaItems: config)
            // Set initial backdrop for index 0.
            if let first = heroItems.first {
                updateBackdrop(for: first)
            }
            return cell

        case .row(let id):
            let isCW = rows.first(where: { $0.id == id })?.isContinueWatching ?? false
            if isCW {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ContinueWatchingCell.reuseID, for: indexPath) as! ContinueWatchingCell
                cell.configure(item: item)
                return cell
            } else {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
                cell.configure(item: item)
                return cell
            }

        case .sortHeader:
            // .sortHeader item carries no MediaItem — it must have been caught by the
            // short-circuit above. If we reach here the snapshot is malformed.
            preconditionFailure("MediaLibraryViewController: .sortHeader reached resolve() — item ID mismatch")

        case .grid:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
            cell.configure(item: item)
            return cell
        }
    }

    // MARK: - State overlays

    private func configureStateOverlays() {
        // Full-screen placeholder: mirrored from PlexHomeViewController.configureStateOverlays().
        // Sits behind the collection view; isHidden = true until data or error state
        // is resolved.
        stateView = HomeStateView()
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true

        // Wire the Try Again / Refresh button: restart the full load from scratch.
        stateView.onAction = { [weak self] in
            guard let self else { return }
            self.startLoading()
        }

        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: - State management

    /// Evaluates the four state conditions and shows or hides the stateView,
    /// collectionView, and backdropView.
    ///
    /// Precedence mirrors PlexHomeViewController.updateHomeState() (line 484):
    ///   notConnected → loading → error → empty → content
    ///
    /// "notConnected" uses the provider's ConnectionState rather than
    /// credential presence (the library VC has no PlexAuthManager; the host
    /// only routes here when a provider exists, so non-nil provider is given).
    private func updateLibraryState() {
        let hasContent = !rows.isEmpty || !gridItems.isEmpty

        if provider.connectionState != .connected {
            show(.notConnected)
        } else if isInitialLoading && !hasContent {
            show(.loading)
        } else if loadFailed && !hasContent {
            show(.error(message: "Unable to load this library. Check your connection and try again."))
        } else if !isInitialLoading && !hasContent {
            show(.empty)
        } else {
            hideState()
        }
    }

    /// Configure and reveal the stateView; hide collection and backdrop.
    /// Mirrors the three repeated toggle blocks in PlexHomeViewController.updateHomeState().
    private func show(_ kind: HomeStateView.Kind) {
        stateView.configure(kind: kind)
        stateView.isHidden = false
        collectionView.isHidden = true
        backdropView.isHidden = true
    }

    /// Hide the stateView and reveal the collection + (optionally) backdrop.
    /// Backdrop visibility follows config.showHero — same as the home's content branch
    /// (`backdropView.isHidden = !showHomeHero`).
    private func hideState() {
        stateView.isHidden = true
        collectionView.isHidden = false
        backdropView.isHidden = !config.showHero
    }

    // MARK: - Sort

    /// Presents a UIAlertController action sheet listing all sort options.
    /// The current sort is prefixed with a checkmark so the user can see
    /// the active selection at a glance (tvOS UIAlertAction has no native
    /// checkmark accessory). Mirrors PlexHomeViewController action-sheet pattern.
    private func presentSortPicker() {
        let sheet = UIAlertController(title: "Sort By", message: nil, preferredStyle: .actionSheet)
        let options: [SortOption] = [.addedAtDesc, .releaseDateDesc, .titleAsc, .titleDesc, .ratingDesc]
        for option in options {
            let checked = option == sort
            let title = checked ? "\u{2713} \(option.displayName)" : option.displayName
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.applySort(option)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    /// Updates `sort`, persists the choice, resets grid state, and kicks off a
    /// fresh grid load. The sort header cell is reconfigured via reconfigureItems
    /// so it reflects the new sort name and the live count.
    ///
    /// Reload strategy: cancel any in-flight loadingTask (which may be mid-rows+grid
    /// concurrent fetch), then start a new task that re-fetches the grid. If rows
    /// is empty (the initial loadRows was cancelled before it finished), rows are
    /// re-fetched too so hub rows are never left blank after a sort change during
    /// initial load. Rows are NOT re-fetched when already loaded — sort order does
    /// not affect them.
    private func applySort(_ option: SortOption) {
        guard option != sort else { return }
        sort = option
        LibrarySettingsManager.shared.setMediaSortOption(option, for: library.id)

        // Reset grid state before the reload so stale items don't flash.
        // Clear loadFailed so a prior error state doesn't flash before the reload resolves.
        gridItems = []
        totalGridCount = 0
        loadFailed = false

        // Cancel any in-flight load (rows+grid concurrent task or a prior grid-only task).
        loadingTask?.cancel()
        loadingTask = Task { [weak self] in
            guard let self else { return }
            // Recover rows if the initial load was cancelled before loadRows finished.
            if self.rows.isEmpty { await self.loadRows() }
            await self.loadGridFirstPage()
            // Reconfigure the sort header so the count reflects the freshly loaded total.
            var snap = self.dataSource.snapshot()
            snap.reconfigureItems([.sortHeader])
            self.dataSource.apply(snap, animatingDifferences: false, completion: nil)
        }

        // Re-apply snapshot immediately so the sort name and the placeholder count
        // (0 while the reload is in flight) are visible right away. reconfigureItems
        // on the snapshot is called here — not just in the task — so the label flips
        // instantly on sort selection rather than waiting for the grid fetch to complete.
        applySnapshot()
        var sortSnap = dataSource.snapshot()
        sortSnap.reconfigureItems([.sortHeader])
        dataSource.apply(sortSnap, animatingDifferences: false)
    }

    // MARK: - Grid pagination

    /// Loads the next page of grid items and appends them to `gridItems`.
    /// Guarded by `isLoadingNextPage` so concurrent calls are no-ops.
    /// All state mutations happen on the @MainActor (VC is @MainActor).
    private func loadGridNextPage() {
        guard !isLoadingNextPage, gridItems.count < totalGridCount else { return }
        isLoadingNextPage = true
        Task { [weak self] in
            guard let self else { return }
            let page = Page(offset: gridItems.count, limit: 60)
            guard let result = try? await provider.items(in: library, sort: sort, page: page) else {
                isLoadingNextPage = false
                return
            }
            guard !Task.isCancelled else {
                isLoadingNextPage = false
                return
            }
            // Dedup against already-loaded items: the provider may overlap pages if
            // items are added between requests. Filter by itemID (not full equality).
            let existing = Set(gridItems.map { $0.ref.itemID })
            let newItems = result.items.filter { !existing.contains($0.ref.itemID) }
            gridItems.append(contentsOf: newItems)
            totalGridCount = result.total  // keep authoritative count current
            isLoadingNextPage = false
            applySnapshot()
        }
    }

    // MARK: - Leading-edge focus guide

    /// Re-aim the leading-edge UIFocusGuide based on the newly-focused cell.
    /// See property doc on leftEdgeFocusGuide for the bug this prevents.
    ///
    /// Section-kind handling:
    ///   - no focus / item == 0 / out of bounds       -> [] (guide transparent, Left escapes to sidebar)
    ///   - .hero, .sortHeader, placeholder             -> [] (non-orthogonal, no walk-back needed)
    ///   - .row(_) with item > 0                       -> previous cell if on screen, else []
    ///   - .grid   with item > 0                       -> previous cell if on screen, else []
    ///     (.grid is zero-height today; branch is inert until Task 11 lands the grid.)
    ///
    /// CRITICAL: do NOT scroll the row to bring the previous cell into view here.
    /// Doing so fires on every focus update (including Right/Up/Down moves) and
    /// produces a "row keeps re-centering under you" effect. If the previous cell
    /// is not already on screen the guide fails open (no redirect) -- the system
    /// falls back to normal Left behaviour. Mirrors PlexHomeViewController
    /// updateLeftEdgeGuide(for:) at ~line 2040.
    private func updateLeftEdgeGuide(for indexPath: IndexPath?) {
        guard let indexPath else {
            leftEdgeFocusGuide.preferredFocusEnvironments = []
            return
        }

        let sections = dataSource?.snapshot().sectionIdentifiers ?? []
        guard indexPath.section < sections.count, indexPath.item > 0 else {
            // item == 0 or out of bounds: guide is transparent.
            leftEdgeFocusGuide.preferredFocusEnvironments = []
            return
        }

        switch sections[indexPath.section] {
        case .hero, .sortHeader:
            // Non-orthogonal or placeholder sections: no walk-back.
            leftEdgeFocusGuide.preferredFocusEnvironments = []
        case .row, .grid:
            // Orthogonal row or grid: point at the previous cell if already on screen.
            // DO NOT preemptively scroll.
            let target = IndexPath(item: indexPath.item - 1, section: indexPath.section)
            if let cell = collectionView.cellForItem(at: target) {
                leftEdgeFocusGuide.preferredFocusEnvironments = [cell]
            } else {
                leftEdgeFocusGuide.preferredFocusEnvironments = []
            }
        }
    }
}

// MARK: - Carousel presentation
extension MediaLibraryViewController {
    /// Present `PreviewCarouselViewController` for the given item array.
    ///
    /// This is the library VC's SOLE presentation path for item taps.  The
    /// carousel VC is MediaItem-native and handles the PlexMetadata "escape
    /// hatch" internally, so this VC stays fully agnostic (no PlexMetadata /
    /// PlexNetworkManager imports required here).
    ///
    /// Mirror of PlexHomeViewController's UIKit carousel branch (~line 1514).
    ///
    /// Focus restoration: sourceTarget is nil (no PreviewSourceTarget needed)
    /// and onDismiss is a no-op.  The collection's stable item identifiers let
    /// the focus engine restore focus to the previously-focused cell on dismiss
    /// without manual bookkeeping.  If a more precise restore is needed later,
    /// store the tapped IndexPath and set preferredFocusEnvironments to that
    /// cell in viewDidAppear after dismiss.
    ///
    /// onSelectItem remains as a public hook but is NOT called here; the
    /// carousel handles play/detail internally.  It becomes vestigial once the
    /// full UIKit carousel path is canonical.
    func presentCarousel(items: [MediaItem], selectedIndex: Int, sourceFrame: CGRect) {
        guard !items.isEmpty,
              selectedIndex >= 0 && selectedIndex < items.count else { return }

        let carouselVC = PreviewCarouselViewController(
            items: items,
            selectedIndex: selectedIndex,
            sourceFrame: sourceFrame,
            sourceTarget: nil,
            // standaloneDetail defaults to false — the spring-morph carousel
            // is the correct first-entry presentation.
            onDismiss: { _ in }
        )

        // Walk to the topmost presented VC before presenting — matches the
        // home VC's pattern so the carousel stacks correctly if something is
        // already presented (e.g. sort picker still animating out).
        var topVC: UIViewController = self
        while let presented = topVC.presentedViewController { topVC = presented }
        // animated: false — the carousel's own spring morph IS the transition.
        // A modal transition would compose on top of it.
        topVC.present(carouselVC, animated: false)
    }
}

// MARK: - UICollectionViewDelegate (pagination only)
//
// IMPORTANT: didUpdateFocusIn is intentionally NOT implemented here.
// The left-edge focus guide is driven exclusively by
// FocusCenteringCollectionView.onFocusedIndexPath (wired in configureCollectionView).
// Adding a didUpdateFocusIn override in a UICollectionViewDelegate extension would
// re-introduce the clobber bug that was fixed by removing the delegate entirely.
// Only willDisplay is implemented; any focus-related delegate methods belong in
// FocusCenteringCollectionView's callback, NOT here.
extension MediaLibraryViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        // Trigger the next page when the user is within 12 items of the loaded tail.
        let sections = dataSource.snapshot().sectionIdentifiers
        guard indexPath.section < sections.count,
              case .grid = sections[indexPath.section] else { return }
        let threshold = gridItems.count - 12
        guard indexPath.item >= threshold, gridItems.count < totalGridCount else { return }
        loadGridNextPage()
    }

    // MARK: - Item tap (Siri Remote Select)
    //
    // On tvOS a focusable collection cell fires didSelectItemAt on Select press.
    // Route by section:
    //   .row(id)   → open carousel for that row's items at the tapped item's index
    //   .grid      → open carousel for gridItems at the tapped item's index
    //   .hero / .sortHeader / placeholder → ignored (their controls handle input)
    //
    // NOTE: didUpdateFocusIn is NOT added here. The left-edge focus guide is driven
    // solely by FocusCenteringCollectionView.onFocusedIndexPath. Adding any
    // didUpdateFocusIn in this extension would re-introduce the focus-guide clobber
    // bug that was fixed by removing the delegate's focus methods entirely.
    func collectionView(_ collectionView: UICollectionView,
                        didSelectItemAt indexPath: IndexPath) {
        let sections = dataSource.snapshot().sectionIdentifiers
        guard indexPath.section < sections.count else { return }
        let section = sections[indexPath.section]

        // Compute the source frame in window coordinates for the morph origin.
        let sourceFrame: CGRect
        if let cell = collectionView.cellForItem(at: indexPath),
           let window = view.window {
            sourceFrame = collectionView.convert(cell.frame, to: window)
        } else {
            sourceFrame = .zero
        }

        switch section {
        case .row(let rowID):
            guard let rowData = rows.first(where: { $0.id == rowID }),
                  let itemID = dataSource.itemIdentifier(for: indexPath),
                  case .media(_, let refID) = itemID,
                  let tappedItem = rowData.items.first(where: { $0.ref.itemID == refID }),
                  let selectedIndex = rowData.items.firstIndex(where: { $0.ref.itemID == tappedItem.ref.itemID })
            else { return }
            presentCarousel(items: rowData.items, selectedIndex: selectedIndex, sourceFrame: sourceFrame)

        case .grid:
            guard let itemID = dataSource.itemIdentifier(for: indexPath),
                  case .media(_, let refID) = itemID,
                  let tappedItem = gridItems.first(where: { $0.ref.itemID == refID }),
                  let selectedIndex = gridItems.firstIndex(where: { $0.ref.itemID == tappedItem.ref.itemID })
            else { return }
            presentCarousel(items: gridItems, selectedIndex: selectedIndex, sourceFrame: sourceFrame)

        case .hero, .sortHeader:
            // Hero's onPlay/onInfo callbacks handle their own presentation.
            // .sortHeader has its own sort picker action. Neither routes here.
            break
        }
    }
}

// MARK: - UICollectionViewDataSourcePrefetching
extension MediaLibraryViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView,
                        prefetchItemsAt indexPaths: [IndexPath]) {
        let sections = dataSource.snapshot().sectionIdentifiers
        var urls: [URL] = []
        for indexPath in indexPaths {
            guard indexPath.section < sections.count,
                  case .grid = sections[indexPath.section],
                  indexPath.item < gridItems.count else { continue }
            let item = gridItems[indexPath.item]
            // Mirror PosterCell.configure(item:) URL choice: prefer grandparent poster,
            // fall back to the item's own poster. Compact-map drops nil URLs.
            if let url = item.grandparentArtwork?.poster ?? item.artwork.poster {
                urls.append(url)
            }
        }
        if !urls.isEmpty {
            ImageCacheManager.shared.prefetch(urls: urls)
        }
    }
}


