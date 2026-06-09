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

        // sortHeader — one dedicated sentinel per snapshot. Always shown (library title + count).
        snapshot.appendSections([.sortHeader])
        snapshot.appendItems([.sortHeader], toSection: .sortHeader)

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

    /// Zero-height placeholder for the grid section (not yet implemented).
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
            cell.onSortTapped = { [weak self] in
                // TODO Task 10: present sort action sheet.
                _ = self
            }
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
                onIndexChanged: { [weak self] _, changedItem in
                    self?.updateBackdrop(for: changedItem)
                },
                onPlay: { [weak self] playItem in
                    self?.onSelectItem?(playItem)
                },
                onInfo: { _ in
                    // Task 12 wires the info action (detail push).
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


