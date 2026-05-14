//
//  PlexHomeViewController.swift
//  Rivulet
//
//  UIKit/TVUIKit implementation of the Plex Home screen, built for the
//  perf comparison spike on `perf-tvuikit-spike` branch. Mirrors the
//  SwiftUI `PlexHomeView` data flow exactly so traces are apples-to-apples.
//
//  Architecture:
//    - Single UICollectionView with UICollectionViewCompositionalLayout
//    - One section per hub (Continue Watching + N Recently Added)
//    - Each section uses .continuous orthogonalScrollingBehavior
//    - Cells are TVPosterView (poster hubs) or TVCardView (Continue Watching)
//    - Hero is rendered as section 0 — full-bleed, custom layout group
//
//  Data: reads from `PlexDataStore.shared` exactly like the SwiftUI version,
//  observes via Combine. Hub processing logic mirrors `computeProcessedHubs`.
//
//  Image loading: same `ImageCacheManager.shared.image(for:)` API the
//  SwiftUI cards use; signposts capture per-image latency.
//
//  Focus: native UIKit + UICollectionView focus engine. No focus guides
//  needed (single focus target per cell, standard behavior).
//

import UIKit
import TVUIKit
import Combine
import os.log

private let homeUIKitLog = Logger(subsystem: "com.rivulet.app", category: "PlexHomeUIKit")

// MARK: - Section model
//
// Identifiers must be Sendable + Hashable for
// UICollectionViewDiffableDataSource. We use trivial String-based IDs to
// avoid actor-isolation inference around custom value types. The actual
// section data (titles, items, isContinueWatching) lives on the
// controller in `sectionsSnapshot` keyed by the same IDs.

nonisolated struct HomeSectionID: Hashable, Sendable {
    let raw: String
    static let hero = HomeSectionID(raw: "hero")
    static func hub(_ hubID: String) -> HomeSectionID { .init(raw: "hub:\(hubID)") }
}

nonisolated struct HomeItemID: Hashable, Sendable {
    let sectionID: HomeSectionID
    let ratingKey: String
}

/// Controller-side bookkeeping. Held in `sectionsSnapshot` to be looked
/// up by `cellForItemAt` and `layoutSection`.
struct HomeSectionData {
    let id: HomeSectionID
    let title: String?
    let isContinueWatching: Bool
    let isHero: Bool
    let items: [PlexMetadata]
}

// MARK: - Controller

@MainActor
final class PlexHomeViewController: UIViewController {

    private let dataStore = PlexDataStore.shared
    private let authManager = PlexAuthManager.shared

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<HomeSectionID, HomeItemID>!

    /// Latest snapshot of sections in render order. Cell configurators look
    /// up the source `PlexMetadata` from here without round-tripping the
    /// data store on every cellForItem.
    private var sectionsSnapshot: [HomeSectionData] = []

    private var dataStoreObservers: Set<AnyCancellable> = []

    private var hasMarkedFirstFrame = false

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        Perf.event(.homeFirstRender, message: "viewDidLoad start")

        configureCollectionView()
        configureDataSource()
        observeDataStore()

        // Seed initial snapshot from whatever's in the store right now.
        applySnapshot(animated: false)

        // Kick off data fetch; mirrors SwiftUI .onAppear behavior.
        Task { @MainActor in
            await Perf.interval(.homeDataFetch) {
                await dataStore.refreshHubs()
                await dataStore.refreshLibraryHubs()
            }
        }
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
    }

    /// Perf-spike auto-scroll: deterministic vertical sweep so the perf
    /// driver script can capture frame-bucket data during scrolling
    /// without needing remote input. Runs once after first appear.
    private func runAutoScroll() {
        // Wait briefly for data to populate, then sweep vertically over 5s.
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

    // MARK: Layout

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
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.register(HubHeaderView.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: HubHeaderView.reuseID)
        collectionView.register(PosterCell.self, forCellWithReuseIdentifier: PosterCell.reuseID)
        collectionView.register(ContinueWatchingCell.self, forCellWithReuseIdentifier: ContinueWatchingCell.reuseID)
        collectionView.register(HeroCell.self, forCellWithReuseIdentifier: HeroCell.reuseID)

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func layoutSection(at sectionIndex: Int, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        guard sectionIndex < sectionsSnapshot.count else { return nil }
        let section = sectionsSnapshot[sectionIndex]
        if section.isHero {
            return makeHeroSectionLayout(environment: environment)
        }
        return makeHubSectionLayout(section: section, environment: environment)
    }

    private func makeHeroSectionLayout(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .fractionalHeight(1))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                               heightDimension: .absolute(800))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .paging
        return section
    }

    private func makeHubSectionLayout(section: HomeSectionData, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let isCW = section.isContinueWatching

        // Tile sizing matches the SwiftUI version's ScaledDimensions:
        //  - Continue Watching: 392 x 280 (landscape)
        //  - Poster: 260 x 390 (portrait)
        // Plus extra vertical room for the focused-state grow + drop shadow.
        let tileWidth: CGFloat = isCW ? 392 : 260
        let tileHeight: CGFloat = isCW ? 280 : 390
        let groupHeight = tileHeight + 80   // breathing room for focus growth

        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(tileWidth),
                                              heightDimension: .absolute(tileHeight))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(widthDimension: .absolute(tileWidth),
                                               heightDimension: .absolute(groupHeight))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let layoutSection = NSCollectionLayoutSection(group: group)
        layoutSection.orthogonalScrollingBehavior = .continuous
        layoutSection.interGroupSpacing = 40
        layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 48, bottom: 32, trailing: 48)

        if section.title != nil {
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(60)
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

    // MARK: Data source

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
            header.configure(title: self.sectionsSnapshot[indexPath.section].title ?? "")
            return header
        }
    }

    private func cell(for itemID: HomeItemID, at indexPath: IndexPath, in collectionView: UICollectionView) -> UICollectionViewCell {
        guard indexPath.section < sectionsSnapshot.count else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
        }
        let section = sectionsSnapshot[indexPath.section]
        let key = "\(itemID.sectionID.raw):\(itemID.ratingKey)"

        if section.isHero {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: HeroCell.reuseID, for: indexPath) as! HeroCell
            if indexPath.item < section.items.count {
                cell.configure(item: section.items[indexPath.item])
            }
            return cell
        }
        if section.isContinueWatching {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ContinueWatchingCell.reuseID, for: indexPath) as! ContinueWatchingCell
            if indexPath.item < section.items.count {
                Perf.interval(.cellPrepare, key: key) {
                    cell.configure(item: section.items[indexPath.item])
                }
            }
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
        if indexPath.item < section.items.count {
            Perf.interval(.cellPrepare, key: key) {
                cell.configure(item: section.items[indexPath.item])
            }
        }
        return cell
    }

    // MARK: Data store observation

    private func observeDataStore() {
        // PlexDataStore is @MainActor and uses @Published. Subscribe to the
        // version UUIDs which flip when content actually changes.
        dataStore.$hubsVersion
            .merge(with: dataStore.$libraryHubsVersion)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySnapshot(animated: false)
            }
            .store(in: &dataStoreObservers)

        dataStore.$continueWatchingHub
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySnapshot(animated: false)
            }
            .store(in: &dataStoreObservers)
    }

    // MARK: Snapshot

    private func applySnapshot(animated: Bool) {
        let sections = computeSections()
        sectionsSnapshot = sections

        var snapshot = NSDiffableDataSourceSnapshot<HomeSectionID, HomeItemID>()
        for section in sections {
            snapshot.appendSections([section.id])
            let items = section.items.compactMap { meta -> HomeItemID? in
                guard let rk = meta.ratingKey else { return nil }
                return HomeItemID(sectionID: section.id, ratingKey: rk)
            }
            snapshot.appendItems(items, toSection: section.id)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func computeSections() -> [HomeSectionData] {
        var sections: [HomeSectionData] = []

        // Hero is intentionally skipped for now — basic structure first.
        // Will be enabled once Continue Watching + Recently Added render.

        if let cw = dataStore.continueWatchingHub,
           let items = cw.Metadata, !items.isEmpty {
            sections.append(HomeSectionData(
                id: .hub(cw.id),
                title: cw.title ?? "Continue Watching",
                isContinueWatching: true,
                isHero: false,
                items: items
            ))
        }

        for library in dataStore.librariesForHomeScreen {
            guard let hubs = dataStore.libraryHubs[library.key],
                  let recent = hubs.first(where: { isRecentlyAdded($0) }),
                  let items = recent.Metadata, !items.isEmpty
            else { continue }
            sections.append(HomeSectionData(
                id: .hub("\(library.key):recent"),
                title: "Recently Added \(library.title)",
                isContinueWatching: false,
                isHero: false,
                items: items
            ))
        }

        return sections
    }

    private func isRecentlyAdded(_ hub: PlexHub) -> Bool {
        let id = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return id.contains("recentlyadded") || title.contains("recently added")
    }
}

// MARK: - Delegate

extension PlexHomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.section < sectionsSnapshot.count else { return }
        let section = sectionsSnapshot[indexPath.section]
        guard indexPath.item < section.items.count else { return }
        // TODO: route to play (CW) or detail (poster) — out of scope for the
        // perf spike. Selecting a tile is not part of the measured workflow.
        homeUIKitLog.info("[Tap] section=\(section.id.raw, privacy: .public) ratingKey=\(section.items[indexPath.item].ratingKey ?? "?", privacy: .public)")
    }
}
