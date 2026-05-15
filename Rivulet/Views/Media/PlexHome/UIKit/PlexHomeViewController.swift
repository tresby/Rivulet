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

nonisolated struct HomeItemID: Hashable, Sendable {
    let sectionID: HomeSectionID
    /// Item identifier — ratingKey for hubs and recommendations,
    /// watchlist-entry id for watchlist, "hero-overlay" for hero.
    let itemID: String
}

enum HomeSectionKind {
    case hero
    case continueWatching
    case recentlyAdded
    case watchlist
    case recommendations
}

struct HomeSectionData {
    let id: HomeSectionID
    let kind: HomeSectionKind
    let title: String?
    /// Plex items for hub/recommendations/CW sections.
    let plexItems: [PlexMetadata]
    /// Watchlist entries for the watchlist section.
    let watchlistItems: [PlexWatchlistItem]
    /// Hero carousel items (used by the hero overlay cell).
    let heroItems: [PlexMetadata]
    let hubKey: String?
    let hubIdentifier: String?

    static func hub(id: HomeSectionID, title: String, items: [PlexMetadata], isContinueWatching: Bool, hubKey: String?, hubIdentifier: String?) -> HomeSectionData {
        HomeSectionData(
            id: id,
            kind: isContinueWatching ? .continueWatching : .recentlyAdded,
            title: title,
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
            plexItems: items,
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

    private let dataStore = PlexDataStore.shared
    private let authManager = PlexAuthManager.shared
    private let watchlistService = PlexWatchlistService.shared
    private let recommendationService = PersonalizedRecommendationService.shared

    private var backdropView: HeroBackdropView!
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<HomeSectionID, HomeItemID>!

    private var sectionsSnapshot: [HomeSectionData] = []

    /// Hero carousel index (drives backdrop image + overlay current item).
    private var heroCurrentIndex: Int = 0
    private var heroItems: [PlexMetadata] = []

    private var dataStoreObservers: Set<AnyCancellable> = []

    private var hasMarkedFirstFrame = false
    private var hasLoadedRecommendations = false

    /// Pending focus restoration after preview dismiss.
    private var pendingPreviewRestore: PreviewSourceTarget?

    /// Recommendations state (latched local copy — service caches itself).
    private var recommendations: [PlexMetadata] = []
    private var isLoadingRecommendations = false
    private var recommendationsError: String?

    /// `showHomeHero` AppStorage gate (mirrors SwiftUI version).
    private var showHomeHero: Bool {
        UserDefaults.standard.bool(forKey: "showHomeHero")
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
        view.backgroundColor = .black

        Perf.event(.homeFirstRender, message: "viewDidLoad start")

        configureBackdrop()
        configureCollectionView()
        configureDataSource()
        observeDataStore()
        observeWatchlist()

        applySnapshot(animated: false)

        Task { @MainActor in
            await Perf.interval(.homeDataFetch) {
                await dataStore.refreshHubs()
                await dataStore.refreshLibraryHubs()
            }
            selectHeroItemsIfNeeded()
        }
        Task { await watchlistService.fetchWatchlist() }

        if enablePersonalizedRecommendations {
            Task { await refreshRecommendations(force: false) }
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

    private func updateBackdropForCurrentHeroItem() {
        guard showHomeHero, !heroItems.isEmpty else {
            backdropView.setBackdrop(url: nil)
            return
        }
        let clamped = max(0, min(heroCurrentIndex, heroItems.count - 1))
        let item = heroItems[clamped]
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let request = item.heroBackdropRequest(serverURL: serverURL, authToken: token)
        let url = request.backdropURL ?? request.thumbnailURL
        backdropView.setBackdrop(url: url)
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
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.clipsToBounds = false

        collectionView.register(HubHeaderView.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: HubHeaderView.reuseID)
        collectionView.register(PosterCell.self, forCellWithReuseIdentifier: PosterCell.reuseID)
        collectionView.register(ContinueWatchingCell.self, forCellWithReuseIdentifier: ContinueWatchingCell.reuseID)
        collectionView.register(HeroOverlayCell.self, forCellWithReuseIdentifier: HeroOverlayCell.reuseID)
        collectionView.register(WatchlistPosterCell.self, forCellWithReuseIdentifier: WatchlistPosterCell.reuseID)

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
        switch section.kind {
        case .hero:
            return makeHeroSectionLayout()
        case .continueWatching, .recentlyAdded, .recommendations:
            return makeHubSectionLayout(section: section, isContinueWatching: section.kind == .continueWatching)
        case .watchlist:
            return makeHubSectionLayout(section: section, isContinueWatching: false)
        }
    }

    private func makeHeroSectionLayout() -> NSCollectionLayoutSection {
        // Height matches the SwiftUI hero section height: screen - 200pt.
        let height = max(400, UIScreen.main.bounds.height - 200)
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(height))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .zero
        return section
    }

    private func makeHubSectionLayout(section: HomeSectionData, isContinueWatching: Bool) -> NSCollectionLayoutSection {
        let tileWidth: CGFloat = isContinueWatching ? 392 : 260
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
            header.configure(title: self.sectionsSnapshot[indexPath.section].title ?? "")
            return header
        }
    }

    private func cell(for itemID: HomeItemID, at indexPath: IndexPath, in collectionView: UICollectionView) -> UICollectionViewCell {
        guard indexPath.section < sectionsSnapshot.count else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
        }
        let section = sectionsSnapshot[indexPath.section]
        let perfKey = "\(itemID.sectionID.raw):\(itemID.itemID)"

        switch section.kind {
        case .hero:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: HeroOverlayCell.reuseID, for: indexPath) as! HeroOverlayCell
            cell.configure(with: HeroOverlayCell.Configuration(
                items: section.heroItems,
                serverURL: authManager.selectedServerURL ?? "",
                authToken: authManager.selectedServerToken ?? "",
                initialIndex: heroCurrentIndex,
                onIndexChanged: { [weak self] newIndex in
                    guard let self else { return }
                    self.heroCurrentIndex = newIndex
                    self.updateBackdropForCurrentHeroItem()
                },
                onInfo: { [weak self] item in self?.selectPlexItem(item) },
                onPlay: { [weak self] item in self?.playItemDirectly(item) }
            ), parentVC: self)
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
            }
            .store(in: &dataStoreObservers)

        dataStore.$continueWatchingHub
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySnapshot(animated: false)
            }
            .store(in: &dataStoreObservers)

        // Refresh hubs after playback dismissals etc.
        NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.dataStore.refreshHubs()
                    await self?.dataStore.refreshLibraryHubs()
                    if self?.enablePersonalizedRecommendations == true {
                        await self?.refreshRecommendations(force: true)
                    }
                }
            }
            .store(in: &dataStoreObservers)

        NotificationCenter.default.publisher(for: .libraryGUIDIndexDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.upgradeHeroFromTMDB() }
            }
            .store(in: &dataStoreObservers)
    }

    private func observeWatchlist() {
        watchlistService.$watchlistItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySnapshot(animated: false)
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
            switch section.kind {
            case .hero:
                snapshot.appendItems([HomeItemID(sectionID: section.id, itemID: "hero-overlay")], toSection: section.id)
            case .continueWatching, .recentlyAdded, .recommendations:
                let items = section.plexItems.enumerated().compactMap { idx, meta -> HomeItemID? in
                    let id = meta.ratingKey ?? "\(section.id.raw)-\(idx)"
                    return HomeItemID(sectionID: section.id, itemID: id)
                }
                snapshot.appendItems(items, toSection: section.id)
            case .watchlist:
                let items = section.watchlistItems.map { item in
                    HomeItemID(sectionID: section.id, itemID: item.id)
                }
                snapshot.appendItems(items, toSection: section.id)
            }
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func computeSections() -> [HomeSectionData] {
        var sections: [HomeSectionData] = []

        // Hero (when enabled + items available)
        if showHomeHero, !heroItems.isEmpty {
            sections.append(.hero(items: heroItems))
        }

        // Continue Watching
        if let cw = dataStore.continueWatchingHub,
           let items = cw.Metadata, !items.isEmpty {
            sections.append(.hub(
                id: .hub(cw.id),
                title: cw.title ?? "Continue Watching",
                items: items,
                isContinueWatching: true,
                hubKey: cw.key ?? cw.hubKey,
                hubIdentifier: cw.hubIdentifier
            ))
        }

        // Recently Added per home library
        for library in dataStore.librariesForHomeScreen {
            guard let hubs = dataStore.libraryHubs[library.key],
                  let recent = hubs.first(where: { isRecentlyAdded($0) }),
                  let items = recent.Metadata, !items.isEmpty
            else { continue }
            sections.append(.hub(
                id: .hub("\(library.key):recent"),
                title: "Recently Added \(library.title)",
                items: items,
                isContinueWatching: false,
                hubKey: recent.key ?? recent.hubKey,
                hubIdentifier: recent.hubIdentifier
            ))
        }

        // Watchlist
        let watchlistItems = Array(watchlistService.watchlistItems.prefix(20))
        if !watchlistItems.isEmpty {
            sections.append(.watchlist(items: watchlistItems))
        }

        // Personalized recommendations
        if enablePersonalizedRecommendations, !recommendations.isEmpty {
            sections.append(.recommendations(items: recommendations))
        }

        return sections
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

        if heroItems.isEmpty,
           let cached = dataStore.getCachedHeroItems(forLibrary: "home"),
           !cached.isEmpty {
            heroItems = cached
            updateBackdropForCurrentHeroItem()
            applySnapshot(animated: false)
        }

        if heroItems.isEmpty {
            let candidates = computeHubBackedHero(from: dataStore.hubs)
            if !candidates.isEmpty {
                heroItems = candidates
                dataStore.cacheHeroItems(candidates, forLibrary: "home")
                updateBackdropForCurrentHeroItem()
                applySnapshot(animated: false)
            }
        }

        Task { await upgradeHeroFromTMDB() }
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

        switch section.kind {
        case .hero:
            return  // hero overlay handles its own taps internally
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
        let mediaItems = await buildWatchlistMediaItems(from: entries)
        guard !mediaItems.isEmpty else { return }

        let tapped = entries[tappedIndex]
        let targetItemID = tapped.tmdbId.map(String.init) ?? tapped.id
        let validIndex = mediaItems.firstIndex(where: { $0.ref.itemID == targetItemID }) ?? 0
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
    /// entries.
    private func buildWatchlistMediaItems(from entries: [PlexWatchlistItem]) async -> [MediaItem] {
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

        var result: [MediaItem] = []
        result.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            guard let tmdbId = entry.tmdbId else { continue }
            let mediaType: TMDBMediaType = entry.type == .movie ? .movie : .tv

            if let match = lookups[index], !serverURL.isEmpty {
                result.append(
                    PlexMediaMapper.item(match,
                                         providerID: providerID,
                                         serverURL: serverURL,
                                         authToken: token)
                )
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
            result.append(built)
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
        // SwiftUI entry-morph has something to interpolate from.
        var sourceFrames: [PreviewSourceTarget: CGRect] = [:]
        if let attrs = collectionView.layoutAttributesForItem(at: sourceIndexPath),
           let window = view.window {
            let inCollection = attrs.frame
            let inWindow = collectionView.convert(inCollection, to: window)
            sourceFrames[PreviewSourceTarget(rowID: sourceRowID, itemID: sourceItemID)] = inWindow
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
        case .hero:
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

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        backdropView.applyScrollOffset(scrollView.contentOffset.y)
    }
}
