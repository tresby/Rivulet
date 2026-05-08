//
//  DiscoverView.swift
//  Rivulet
//
//  Top-level Discover page. Fixed TMDB hero backdrop behind a scroll view
//  containing the hero overlay (Add to Watchlist / Play for in-library items)
//  and 8 TMDB curated sections plus For You.
//

import SwiftUI
import Combine

struct DiscoverView: View {
    @StateObject private var viewModel = DiscoverViewModel()
    @StateObject private var watchlist = PlexWatchlistService.shared

    /// Still used by the hero's in-library "Play" path: tapping a hero item
    /// that has a Plex match jumps straight into MediaDetailView bypassing
    /// the carousel (preserves the hero's direct-play affordance).
    @State private var presentedPlexItem: MediaItem?

    @StateObject private var authManager = PlexAuthManager.shared

    @State private var heroCurrentIndex: Int = 0
    @State private var heroScrollOffset: CGFloat = 0

    // Carousel preview — same UIKit-modal pattern as Home/Library.
    @State private var rowPreviewRequest: PreviewRequest?
    @State private var previewRestoreTarget: PreviewSourceTarget?
    @State private var capturedSourceFrames: [PreviewSourceTarget: CGRect] = [:]
    @State private var showPreviewCover = false

    var body: some View {
        mainBody
            .watchlistToast(message: watchlist.transientWriteError)
    }

    private var mainBody: some View {
        let screenHeight = UIScreen.main.bounds.height
        let heroSectionHeight = screenHeight - 200
        let heroActive = !viewModel.heroItems.isEmpty
        let currentHeroItem: TMDBListItem? = {
            guard heroActive else { return nil }
            let clamped = max(0, min(heroCurrentIndex, viewModel.heroItems.count - 1))
            return viewModel.heroItems[clamped]
        }()

        return ZStack(alignment: .top) {
            // Fixed backdrop — fills the screen, parallaxes with scroll.
            if heroActive {
                DiscoverHeroBackdrop(currentItem: currentHeroItem)
                    .ignoresSafeArea()
                    // Shared parallax with PlexHomeView / PlexLibraryView so
                    // the hero surface feels identical across the three.
                    .offset(y: -heroScrollOffset * 1.3 - min(72, heroScrollOffset * 0.72))
                    .allowsHitTesting(false)
            }

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if heroActive {
                            DiscoverHeroOverlay(
                                items: viewModel.heroItems,
                                currentIndex: $heroCurrentIndex,
                                inLibraryTMDBIds: viewModel.inLibraryTMDBIds,
                                libraryMatch: { item in
                                    await viewModel.libraryMatch(for: item)
                                },
                                onPresentPlex: { metadata in
                                    guard let serverURL = authManager.selectedServerURL,
                                          let token = authManager.selectedServerToken else { return }
                                    let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
                                    presentedPlexItem = PlexMediaMapper.item(metadata, providerID: providerID, serverURL: serverURL, authToken: token)
                                },
                                onInfo: { item in
                                    Task { await handleSelection(item) }
                                },
                                onHeroFocused: {
                                    withAnimation(.smooth(duration: 0.8)) {
                                        scrollProxy.scrollTo("discoverHero", anchor: .top)
                                    }
                                }
                            )
                            .frame(height: heroSectionHeight)
                            .focusSection()
                            .id("discoverHero")
                        }

                        VStack(alignment: .leading, spacing: 48) {
                            // Zero-height anchor matches PlexHomeView so the first
                            // row sits 48pt below the hero (VStack spacing applies
                            // between children) — keeps focus-driven scroll offsets
                            // identical across the three hero surfaces.
                            Color.clear
                                .frame(height: 0)
                                .id("discoverContentRowsAnchor")
                            ForEach(TMDBDiscoverSection.allCases) { section in
                                let items = viewModel.items(for: section)
                                if !items.isEmpty {
                                    let rowID = "discover.\(section.rawValue)"
                                    DiscoverRow(
                                        rowID: rowID,
                                        title: section.title,
                                        items: items,
                                        isInLibrary: { viewModel.inLibraryTMDBIds.contains($0.id) },
                                        isOnWatchlist: { watchlist.contains(tmdbId: $0.id) },
                                        onSelect: { item in
                                            Task { await handleSelection(item) }
                                        },
                                        onPreviewRequested: { request in
                                            rowPreviewRequest = request
                                            showPreviewCover = true
                                        },
                                        libraryMatch: { await viewModel.libraryMatch(for: $0) },
                                        onRowFocused: {
                                            withAnimation(.smooth(duration: 0.8)) {
                                                scrollProxy.scrollTo(rowID, anchor: UnitPoint(x: 0.5, y: 0.5))
                                            }
                                        }
                                    )
                                    .id(rowID)
                                }
                            }

                            // "For You" trails the curated sections.
                            if !viewModel.forYou.isEmpty {
                                let forYouRowID = "discover.forYou"
                                DiscoverRow(
                                    rowID: forYouRowID,
                                    title: "For You",
                                    items: viewModel.forYou,
                                    isInLibrary: { _ in false },
                                    isOnWatchlist: { watchlist.contains(tmdbId: $0.id) },
                                    onSelect: { item in
                                        Task { await handleSelection(item) }
                                    },
                                    onPreviewRequested: { request in
                                        rowPreviewRequest = request
                                        showPreviewCover = true
                                    },
                                    libraryMatch: { _ in nil },
                                    onRowFocused: {
                                        withAnimation(.smooth(duration: 0.8)) {
                                            scrollProxy.scrollTo(forYouRowID, anchor: UnitPoint(x: 0.5, y: 0.5))
                                        }
                                    }
                                )
                                .id(forYouRowID)
                            }
                        }
                        .padding(.top, heroActive ? 0 : 48)
                        .padding(.bottom, 40)
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offset in
                    heroScrollOffset = max(0, offset)
                }
                .scrollClipDisabled()
                .ignoresSafeArea(.container, edges: heroActive ? [.top, .horizontal] : [])
            }
        }
        .task { await viewModel.load() }
        .fullScreenCover(item: $presentedPlexItem) { metadata in
            MediaDetailView(item: metadata)
                .presentationBackground(.black)
        }
        .overlayPreferenceValue(PreviewSourceFramePreferenceKey.self) { anchors in
            GeometryReader { proxy in
                Color.clear
                    .hidden()
                    .task(id: anchors.count) {
                        capturedSourceFrames = Dictionary(uniqueKeysWithValues: anchors.map { ($0.key, proxy[$0.value]) })
                    }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: showPreviewCover) { _, isShowing in
            if isShowing, let request = rowPreviewRequest {
                presentPreview(request: request)
            }
        }
    }

    // MARK: - Selection handlers

    /// Context-menu "Info" / hero fallback — skips the carousel and jumps
    /// straight to detail. In-library items open via MediaDetailView; TMDB-
    /// only items wrap through TMDBMediaMapper so they flow through
    /// MediaDetailView too (using the metadataSource branch of loadDetail).
    private func handleSelection(_ item: TMDBListItem) async {
        if let plex = await viewModel.libraryMatch(for: item) {
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }
            let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
            presentedPlexItem = PlexMediaMapper.item(plex, providerID: providerID, serverURL: serverURL, authToken: token)
        } else {
            presentedPlexItem = TMDBMediaMapper.item(item)
        }
    }

    // MARK: - Preview Presentation (UIKit Modal)

    private func presentPreview(request: PreviewRequest) {
        let menuBridge = PreviewMenuBridge()

        let previewContent = PreviewOverlayHost(
            request: request,
            sourceFrames: capturedSourceFrames,
            onDismiss: { sourceTarget in
                previewRestoreTarget = sourceTarget
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = scene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    if let previewVC = topVC as? PreviewContainerViewController {
                        previewVC.dismissPreview()
                    }
                }
            },
            onSubItemNavigation: { item in
                // Stage the sub-item into the existing fullScreenCover
                // binding, then dismiss the modal overlay so the cover
                // is revealed underneath showing the new item's detail.
                presentedPlexItem = item
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = scene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    if let previewVC = topVC as? PreviewContainerViewController {
                        previewVC.dismissPreview()
                    }
                }
            },
            menuBridge: menuBridge
        )

        // UIKit present bypasses the SwiftUI environment — re-inject the
        // registries that MediaDetailView reads.
        let contentWithRegistries = previewContent
            .environment(MediaProviderRegistry.shared)
            .environment(MusicProviderRegistry.shared)
            .environment(MetadataSourceRegistry.shared)

        let container = PreviewContainerViewController(
            content: contentWithRegistries,
            menuHandler: { menuBridge.triggerMenu() }
        )
        container.onDismiss = {
            showPreviewCover = false
            rowPreviewRequest = nil
        }

        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = scene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(container, animated: false)
        }
    }
}

// MARK: - View Model

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published private(set) var sectionItems: [TMDBDiscoverSection: [TMDBListItem]] = [:]
    @Published private(set) var forYou: [TMDBListItem] = []
    @Published private(set) var inLibraryTMDBIds: Set<Int> = []
    @Published private(set) var heroItems: [TMDBListItem] = []
    @Published private(set) var loading = false

    private let discoverService = TMDBDiscoverService.shared
    private let recommendationService = DiscoverRecommendationService.shared
    private let libraryIndex = LibraryGUIDIndex.shared

    /// Minimum watched items required before we try to personalize the "For You"
    /// row. Fewer watches produce noisy recommendations that feel random.
    private let forYouColdStartMinWatched = 5

    /// Cap on hero carousel items. Matches the home page's cap.
    private let heroItemCap = 9

    func load() async {
        loading = true
        defer { loading = false }

        // Fetch all 8 sections in parallel.
        await withTaskGroup(of: (TMDBDiscoverSection, [TMDBListItem]).self) { group in
            for section in TMDBDiscoverSection.allCases {
                group.addTask { [discoverService] in
                    let items = await discoverService.fetchSection(section)
                    return (section, items)
                }
            }
            for await (section, items) in group {
                sectionItems[section] = items
            }
        }

        // Precompute the in-library TMDB id set for sync lookup from row closures.
        await recomputeInLibrarySet()

        // Pick hero items from the same popular sources the home page uses.
        heroItems = computeHeroItems(cap: heroItemCap)

        // Warm the image cache for every hero backdrop/poster so paging the
        // carousel doesn't flash a blank frame while the image downloads.
        prefetchHeroAssets(heroItems)

        // "For You" appends below the curated sections once watch-history
        // features resolve, so it doesn't shift the layout out from under
        // the user. Hides itself on cold-start (too few watched items to
        // produce a meaningful profile).
        let watchedItems = await collectWatchHistory()
        if watchedItems.count >= forYouColdStartMinWatched {
            let profile = await WatchProfileBuilder.build(from: watchedItems)
            forYou = await recommendationService.forYouRow(profile: profile)
        } else {
            forYou = []
        }
    }

    func items(for section: TMDBDiscoverSection) -> [TMDBListItem] {
        sectionItems[section] ?? []
    }

    func libraryMatch(for item: TMDBListItem) async -> PlexMetadata? {
        await libraryIndex.lookup(tmdbId: item.id, type: item.mediaType)
    }

    /// Warm the image cache for the full hero carousel so paging doesn't
    /// trigger a blank flash. Larger `w1280` size is what `HeroBackdropImage`
    /// will resolve from the `original` URL — using `original` for prefetch
    /// matches what the view requests.
    private func prefetchHeroAssets(_ items: [TMDBListItem]) {
        let backdropBase = "https://image.tmdb.org/t/p/original"
        let posterBase = "https://image.tmdb.org/t/p/w500"
        var urls: [URL] = []
        for item in items {
            if let path = item.backdropPath,
               let url = URL(string: "\(backdropBase)\(path)") {
                urls.append(url)
            }
            if let path = item.posterPath,
               let url = URL(string: "\(posterBase)\(path)") {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        Task { await ImageCacheManager.shared.prefetch(urls: urls) }
    }

    /// Interleave Popular Movies + Popular TV (which we've already fetched for
    /// the curated rows) to seed the hero carousel. Prefers items with backdrops.
    private func computeHeroItems(cap: Int) -> [TMDBListItem] {
        let movies = sectionItems[.moviePopular] ?? []
        let shows = sectionItems[.tvPopular] ?? []

        var interleaved: [TMDBListItem] = []
        let count = max(movies.count, shows.count)
        for i in 0..<count {
            if i < movies.count { interleaved.append(movies[i]) }
            if i < shows.count { interleaved.append(shows[i]) }
            if interleaved.count >= cap * 2 { break }
        }

        // Prefer items with a backdrop so the hero never shows the fallback gradient.
        let ranked = interleaved.sorted { (a, b) in
            let aHas = (a.backdropPath?.isEmpty == false) ? 1 : 0
            let bHas = (b.backdropPath?.isEmpty == false) ? 1 : 0
            return aHas > bHas
        }

        return Array(ranked.prefix(cap))
    }

    /// Rebuild `inLibraryTMDBIds` by asking the library index for each fetched item.
    /// This runs after section items load. Single pass, one actor hop per id — cheap.
    private func recomputeInLibrarySet() async {
        let allIds = sectionItems.values.flatMap { $0.map { ($0.id, $0.mediaType) } }
        var newSet: Set<Int> = []
        for (id, mediaType) in allIds {
            if await libraryIndex.lookup(tmdbId: id, type: mediaType) != nil {
                newSet.insert(id)
            }
        }
        inLibraryTMDBIds = newSet
    }

    private func collectWatchHistory() async -> [PlexMetadata] {
        let dataStore = PlexDataStore.shared
        let auth = PlexAuthManager.shared
        guard let serverURL = auth.selectedServerURL,
              let token = auth.selectedServerToken else { return [] }
        await dataStore.loadLibrariesIfNeeded()
        let visibleLibraries = dataStore.visibleVideoLibraries

        var watched: [PlexMetadata] = []
        for library in visibleLibraries.prefix(3) {  // Cap to keep latency sane
            if let result = try? await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: library.key,
                start: 0,
                size: 200
            ) {
                watched.append(contentsOf: result.items.filter { ($0.viewCount ?? 0) > 0 })
            }
        }
        return Array(watched.prefix(120))
    }
}
