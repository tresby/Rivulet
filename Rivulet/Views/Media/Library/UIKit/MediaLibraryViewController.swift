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
    case placeholder(String) // zero-height sort/grid placeholder — associated value ensures uniqueness across sections
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

    // Focused index path forwarded by FocusCenteringCollectionView.
    private var focusedIndexPath: IndexPath?

    // MARK: - UI properties

    private var backgroundBlurView: UIVisualEffectView!
    private var collectionView: FocusCenteringCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<SectionKind, ItemID>!
    private var stateView: HomeStateView!

    // MARK: - Cell registrations
    //
    // Per the tvOS CellRegistration rule: each registration is stored as a
    // lazy let (created once, never inside the diffable cell-provider closure).

    private lazy var heroCellRegistration: UICollectionView.CellRegistration<HeroOverlayCell, MediaItem> = {
        UICollectionView.CellRegistration<HeroOverlayCell, MediaItem> { _, _, _ in
            // Hero cell configuration wired in the next task.
        }
    }()

    private lazy var posterCellRegistration: UICollectionView.CellRegistration<PosterCell, MediaItem> = {
        UICollectionView.CellRegistration<PosterCell, MediaItem> { cell, _, item in
            cell.configure(item: item)
        }
    }()

    private lazy var continueWatchingCellRegistration: UICollectionView.CellRegistration<ContinueWatchingCell, MediaItem> = {
        UICollectionView.CellRegistration<ContinueWatchingCell, MediaItem> { cell, _, item in
            cell.configure(item: item)
        }
    }()

    /// No-op cell for `.placeholder` items in zero-height sortHeader/grid sections.
    /// Must be dequeued BEFORE `resolve()` is called — placeholders carry no MediaItem.
    private lazy var placeholderCellRegistration: UICollectionView.CellRegistration<UICollectionViewCell, MediaLibraryItemID> = {
        UICollectionView.CellRegistration<UICollectionViewCell, MediaLibraryItemID> { _, _, _ in }
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear base so the blur effect samples through (same as PlexHomeViewController).
        view.backgroundColor = .clear

        configureBackground()
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
        loadingTask = Task { [weak self] in
            guard let self else { return }
            // Run rows and grid first-page concurrently.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in await self?.loadRows() }
                group.addTask { [weak self] in await self?.loadGridFirstPage() }
            }
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
    }

    /// Fetches the first page of grid items into state. The snapshot does NOT
    /// include grid items yet — that is deferred to Task 11 when the grid section
    /// is made visible. This avoids off-screen cell churn on the zero-height section.
    private func loadGridFirstPage() async {
        guard let result = try? await provider.items(
            in: library,
            sort: sort,
            page: Page(offset: 0, limit: 60)
        ) else { return }

        guard !Task.isCancelled else { return }

        gridItems = result.items
        totalGridCount = result.total
        // NOTE: applySnapshot() is intentionally NOT called here.
        // Grid items enter the snapshot in Task 11 when the grid layout is wired.
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

        // sortHeader — zero-height placeholder (Task 9 will make it real).
        snapshot.appendSections([.sortHeader])
        snapshot.appendItems([.placeholder("sortHeader")], toSection: .sortHeader)

        // grid — zero-height placeholder; items NOT included (see loadGridFirstPage()).
        snapshot.appendSections([.grid])
        snapshot.appendItems([.placeholder("grid")], toSection: .grid)

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
        collectionView.onFocusedIndexPath = { [weak self] indexPath in
            self?.focusedIndexPath = indexPath
        }

        // Supplementary registration: row header via class (matches home's approach).
        collectionView.register(
            HubHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: HubHeaderView.reuseID
        )

        // Cell registrations are handled by the stored CellRegistration lazy properties
        // (heroCellRegistration, posterCellRegistration, continueWatchingCellRegistration).
        // No class-based register(_:forCellWithReuseIdentifier:) calls here.

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
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
            return makePlaceholderSection()
        case .grid:
            return makePlaceholderSection()
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

    /// Zero-height placeholder for sortHeader and grid (not yet implemented).
    private func makePlaceholderSection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(0))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        return NSCollectionLayoutSection(group: group)
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
        // SHORT-CIRCUIT: placeholder items carry no MediaItem — dequeue the no-op
        // cell before resolve() can be reached. Task 6 puts placeholders in the
        // zero-height sortHeader/grid sections; reaching resolve() with a placeholder
        // would be a hard crash.
        if case .placeholder = itemID {
            return collectionView.dequeueConfiguredReusableCell(
                using: placeholderCellRegistration, for: indexPath, item: itemID)
        }

        // Skeleton: the snapshot is empty until Task 6 wires data, so this
        // closure is unreachable in the current task. Real item-lookup and
        // configure() calls are added in the next task.
        //
        // Resolves ItemID -> MediaItem for the CellRegistration item parameter.
        // .placeholder is handled above and never reaches here.
        //
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
                    // Row sections: keyed by RowData.id.
                    if let row = rows.first(where: { $0.id == section }),
                       let item = row.items.first(where: { $0.ref.itemID == refID }) {
                        return item
                    }
                }
                fatalError("MediaLibraryViewController: no MediaItem for section=\(section) itemID=\(refID)")
            case .placeholder(_):
                // Unreachable: short-circuited above.
                preconditionFailure("MediaLibraryViewController: placeholder reached resolve()")
            }
        }

        let sections = dataSource.snapshot().sectionIdentifiers
        guard indexPath.section < sections.count else {
            fatalError("MediaLibraryViewController: indexPath.section \(indexPath.section) out of range")
        }
        let item = resolve()
        switch sections[indexPath.section] {
        case .hero:
            // Hero cell — configure() wired in next task.
            return collectionView.dequeueConfiguredReusableCell(
                using: heroCellRegistration, for: indexPath, item: item)
        case .row(let id):
            let isCW = rows.first(where: { $0.id == id })?.isContinueWatching ?? false
            if isCW {
                return collectionView.dequeueConfiguredReusableCell(
                    using: continueWatchingCellRegistration, for: indexPath, item: item)
            } else {
                return collectionView.dequeueConfiguredReusableCell(
                    using: posterCellRegistration, for: indexPath, item: item)
            }
        case .sortHeader, .grid:
            return collectionView.dequeueConfiguredReusableCell(
                using: posterCellRegistration, for: indexPath, item: item)
        }
    }

    // MARK: - State overlays

    private func configureStateOverlays() {
        // Full-screen placeholder: mirrored from PlexHomeViewController.configureStateOverlays().
        // Sits behind the collection view; isHidden = true until data or error state
        // is resolved (wired in a later task).
        stateView = HomeStateView()
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
}

