//
//  MediaDetailView.swift
//  Rivulet
//
//  Detail view for movies and TV shows with playback options
//

import SwiftUI

enum MediaDetailPresentationMode: Equatable {
    case previewCarousel
    case expandedDetail
}

struct MediaDetailView: View {
    let item: MediaItem
    var presentationMode: MediaDetailPresentationMode = .expandedDetail
    var backgroundParallaxOffset: CGFloat = 0
    var showVignette: Bool = true
    var showMetadata: Bool = true
    var showExpandedChrome: Bool = true
    var showsBackdropLayer: Bool = true
    var allowVerticalScroll: Bool = true
    var allowActionRowInteraction: Bool = true
    var heroBackdropMotionLocked: Bool = false
    var backdropStageSize: CGSize? = nil
    var backdropWindowFrame: CGRect? = nil
    var onPreviewExitRequested: (() -> Void)? = nil
    var onDetailsBecameVisible: (() -> Void)? = nil
    var enableDetailDataLoading: Bool = true
    /// When hosted inside `PreviewOverlayHost`, reflects whether the entry /
    /// paging animation has fully settled. The detail data cascade is deferred
    /// until this flips to `true` so the main thread stays quiet while the
    /// spring + staged fades are running.
    var previewAnimationSettled: Bool = true

    /// Tracks the currently displayed item - allows swapping content in place
    /// When set, this overrides `item` so collection/recommended navigation
    /// replaces content rather than pushing a new view
    @State private var displayedItem: MediaItem?

    /// The item currently being shown - either displayedItem or the original item
    private var currentItem: MediaItem {
        displayedItem ?? item
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.previewMenuBridge) private var menuBridge
    @Environment(MediaProviderRegistry.self) private var providerRegistry
    @Environment(MetadataSourceRegistry.self) private var metadataRegistry
    @StateObject private var authManager = PlexAuthManager.shared
    @State private var seasons: [PlexMetadata] = []
    @State private var selectedSeason: PlexMetadata?
    @State private var episodes: [PlexMetadata] = []
    @State private var isLoadingSeasons = false
    @State private var isLoadingEpisodes = false
    @State private var showPlayer = false
    @State private var selectedEpisode: PlexMetadata?
    @State private var lastPlayedMetadata: PlexMetadata?  // Tracks what was playing when player dismissed (for auto-play)
    @State private var fullEpisodeMetadata: [String: PlexMetadata] = [:]  // Prefetched full metadata keyed by ratingKey
    @State private var nextUpEpisode: PlexMetadata?  // The episode that will play when pressing Play on a show

    // Focus state for restoring focus when returning from nested navigation
    @FocusState private var focusedEpisodeId: String?  // Track focused episode
    @FocusState private var focusedActionButton: String?  // Track focused action button
    @State private var isSummaryExpanded = false  // Expand summary text on focus/click

    // Detail state (replaces fullMetadata)
    @State private var detail: MediaItemDetail?
    @State private var collectionItems: [PlexMetadata] = []
    @State private var collectionName: String?
    @State private var recommendedItems: [PlexMetadata] = []
    @State private var isWatched = false
    @State private var displayedProgress: Double = 0  // For animating progress bar
    @State private var isLoadingExtras = false
    @State private var showTrailerPlayer = false
    @State private var trailerMetadata: PlexMetadata?  // Full metadata for trailer playback
    @State private var playFromBeginning = false  // For "Play from Beginning" button
    @State private var isLoadingShufflePlay = false
    @State private var shuffledEpisodeQueue: [PlexMetadata] = []
    @StateObject private var heroBackdrop = HeroBackdropCoordinator()
    @State private var belowFoldLoaded = false  // Flipped true after the full cascade finishes
    @State private var scrollProgress: CGFloat = 0  // 0 = at rest (peek), 1 = fully scrolled
    @State private var belowFoldTitleOpacity: CGFloat = 0
    @State private var scrollResetID = UUID()
    @State private var kenBurnsOffset: CGFloat = 0
    @State private var retainedLogoURL: URL?
    @State private var hasDisplayedHeroLogoImage = false
    @State private var parentShowLogoPath: String?

    // Navigation state for episode parent navigation
    @State private var navigateToSeason: MediaItem?
    @State private var navigateToShow: MediaItem?
    @State private var navigateToEpisode: MediaItem?
    @State private var isLoadingNavigation = false

    // Unified episode list state (all seasons in one scroll)
    @State private var unifiedEpisodes: [PlexMetadata] = []
    @State private var episodeScrollTarget: String? = nil
    @State private var scrollToTopTrigger = false
    @State private var browseActivity: NSUserActivity?

    private let networkManager = PlexNetworkManager.shared
    private let recommendationService = PersonalizedRecommendationService.shared

    private var provider: (any MediaProvider)? {
        providerRegistry.provider(for: currentItem.ref.providerID)
    }

    private var metadataSource: (any MetadataSource)? {
        metadataRegistry.source(for: currentItem.ref.providerID)
    }
    private var isPreviewCarousel: Bool { presentationMode == .previewCarousel }
    private var isExpandedPreviewFlow: Bool { onPreviewExitRequested != nil && presentationMode == .expandedDetail }
    private var shouldLoadDetailData: Bool {
        if !isPreviewCarousel { return true }
        return enableDetailDataLoading
    }
    /// Cascade work is gated on both `shouldLoadDetailData` (which card is
    /// current) and `previewAnimationSettled` (no animation in flight). Both
    /// must be satisfied before we start hitting the network on MainActor.
    private var canRunDetailCascade: Bool {
        shouldLoadDetailData && previewAnimationSettled
    }
    /// Task ID keyed only on the rating key. We deliberately do *not* include
    /// `shouldLoadDetailData` or `previewAnimationSettled` here — those gates
    /// are checked *inside* the task body via early-return, and a separate
    /// `.onChange` re-invokes `loadDetailData()` when they flip. Including
    /// them in the task ID would cause `.task(id:)` to cancel and restart
    /// mid-paging when `isCurrent` flips, which was the dominant paging-jank
    /// source.
    private var detailLoadTaskID: String {
        currentItem.ref.itemID
    }
    private var effectiveHeroLogoURL: URL? {
        heroBackdrop.session.logoURL ?? retainedLogoURL
    }
    private var heroBackdropScale: CGFloat {
        (isPreviewCarousel || isExpandedPreviewFlow) ? 1.14 : 1.08
    }
    private var heroOverlayHorizontalInset: CGFloat {
        if isPreviewCarousel { return 118 }
        if isExpandedPreviewFlow { return 128 }
        return 140
    }

    private var heroLogoMaxWidth: CGFloat {
        (isPreviewCarousel || isExpandedPreviewFlow) ? 620 : 520
    }

    private var heroLogoSlotHeight: CGFloat {
        (isPreviewCarousel || isExpandedPreviewFlow) ? 138 : 120
    }

    private var heroActionRowTopPadding: CGFloat {
        (isPreviewCarousel || isExpandedPreviewFlow) ? 32 : 24
    }

    /// Effective vignette visibility — vignette fades in before text (Apple TV+ two-phase reveal)
    private var effectiveVignetteVisible: Bool {
        guard showVignette else { return false }
        if !isPreviewCarousel && !isExpandedPreviewFlow { return true }
        return true
    }

    /// Effective metadata visibility — requires both the host's staged fade
    /// timing (`showMetadata`) AND `detail` being loaded, so genres,
    /// cast, and summary all appear together. Because `loadDetail`
    /// fires immediately on appear (not gated by `previewAnimationSettled`),
    /// it typically returns before the text fade at ~750ms.
    private var effectiveMetadataVisible: Bool {
        guard showMetadata else { return false }
        if isPreviewCarousel || isExpandedPreviewFlow {
            return detail != nil
        }
        return true
    }

    private var heroBrandTitle: String {
        if currentItem.kind == .season {
            // TODO(post-wave-1): fetch grandparent show detail for season hero brand
            return currentItem.title
        }
        return currentItem.title
    }

    private var seasonHeroContextLabel: String? {
        guard currentItem.kind == .season else { return nil }
        guard let n = currentItem.seasonNumber else { return nil }
        return "Season \(n)"
    }

    private var relatedShowRatingKey: String? {
        switch currentItem.kind {
        case .episode:
            return currentItem.grandparentRef?.itemID
        case .season:
            return currentItem.parentRef?.itemID
        default:
            return nil
        }
    }

    /// Effective item data - merges detail (progress/viewOffset) over currentItem
    /// This ensures we have the most up-to-date playback position after returning from the player
    private var effectiveViewOffset: TimeInterval {
        // detail?.item has refreshed viewOffset after playback; fall back to currentItem
        return detail?.item.userState.viewOffset ?? currentItem.userState.viewOffset
    }

    private var effectiveIsInProgress: Bool {
        let offset = effectiveViewOffset
        guard let runtime = currentItem.runtime, runtime > 0 else { return false }
        let progress = offset / runtime
        return offset > 0 && progress < 0.98
    }

    private var effectiveWatchProgress: Double? {
        guard let runtime = currentItem.runtime, runtime > 0 else { return nil }
        let offset = effectiveViewOffset
        guard offset > 0 else { return nil }
        return min(1.0, offset / runtime)
    }

    private var effectiveRemainingFormatted: String? {
        guard effectiveIsInProgress, let runtime = currentItem.runtime else { return nil }
        let remaining = max(0, runtime - effectiveViewOffset)
        let minutes = Int(remaining / 60)
        if minutes >= 60 {
            let h = minutes / 60; let m = minutes % 60
            return "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }

    // MARK: - Derived helper properties

    private var currentItemDurationFormatted: String? {
        guard let runtime = currentItem.runtime else { return nil }
        let minutes = Int(runtime / 60)
        if minutes >= 60 {
            let h = minutes / 60; let m = minutes % 60
            return "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }

    private var currentItemEpisodeString: String? {
        guard let s = currentItem.seasonNumber, let e = currentItem.episodeNumber else { return nil }
        return "S\(s)E\(e)"
    }

    private var currentItemSeasonDisplayTitle: String? {
        guard let n = currentItem.seasonNumber else { return nil }
        return "Season \(n)"
    }

    // TODO(post-wave-1): fetch grandparent detail for episode hero brand.
    private var currentItemSeriesTitleForDisplay: String? {
        nil
    }

    /// Play button label for TV shows and seasons
    /// Shows "Continue S02E05" for in-progress episodes, "Play" otherwise
    private var showPlayButtonLabel: String {
        guard let episode = nextUpEpisode else { return "Play" }

        // Check if the episode is in progress
        if episode.isInProgress, let epString = episode.episodeString {
            return "Continue \(epString)"
        }

        return "Play"
    }

    /// Caption shown below the Play button when there's a next episode to play
    /// Returns nil for in-progress episodes (button already shows episode info)
    private var upNextCaption: String? {
        guard let episode = nextUpEpisode else { return nil }

        // Don't show caption if episode is in progress (button already says "Continue S02E05")
        if episode.isInProgress { return nil }

        // Build "Up Next: S02E05 - Title" caption
        let epString = episode.episodeString ?? ""
        let title = episode.title ?? ""

        if !epString.isEmpty && !title.isEmpty {
            // Truncate long titles
            let maxTitleLength = 25
            let truncatedTitle = title.count <= maxTitleLength
                ? title
                : String(title.prefix(maxTitleLength - 1)) + "…"
            return "Up Next: \(epString) - \(truncatedTitle)"
        } else if !epString.isEmpty {
            return "Up Next: \(epString)"
        } else if !title.isEmpty {
            return "Up Next: \(title)"
        }

        return nil
    }

    var body: some View {
        GeometryReader { geo in
            let heroHeight = heroContentHeight(for: geo.size.height)
            let stageSize = backdropStageSize ?? geo.size
            // For preview/expanded-preview flows, keep the backdrop at a fixed
            // screen position so it doesn't drift when the card mask expands.
            // The image is already full-screen-sized; the mask just reveals more.
            // Parallax during paging comes from backgroundParallaxOffset alone.
            let centeredStageBaseOffset: CGPoint = {
                if isPreviewCarousel || isExpandedPreviewFlow {
                    return .zero
                }
                return CGPoint(
                    x: -((stageSize.width - geo.size.width) / 2),
                    y: -((stageSize.height - geo.size.height) / 2)
                )
            }()
            let stageWindowOrigin: CGPoint = {
                if isPreviewCarousel || isExpandedPreviewFlow {
                    return .zero
                }
                return backdropWindowFrame?.origin ?? .zero
            }()
            ZStack {
                if showsBackdropLayer {
                    backdropLayer(stageSize: stageSize, geoSize: geo.size,
                                  stageBaseOffset: centeredStageBaseOffset,
                                  windowOrigin: stageWindowOrigin)
                }

                // Left-side gradient for text readability (Apple TV+ style)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.7), location: 0),
                        .init(color: .black.opacity(0.4), location: 0.25),
                        .init(color: .black.opacity(0.12), location: 0.42),
                        .init(color: .clear, location: 0.55),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(effectiveVignetteVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.6), value: effectiveVignetteVisible)
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Bottom gradient for metadata text readability
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.25), location: 0.2),
                        .init(color: .black.opacity(0.55), location: 0.4),
                        .init(color: .black.opacity(0.8), location: 0.65),
                        .init(color: .black.opacity(0.95), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: geo.size.height * 0.55)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(effectiveVignetteVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.6), value: effectiveVignetteVisible)
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Layer 2: All scrollable content in one continuous flow
                ScrollViewReader { verticalProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Metadata pinned near bottom of visible area.
                        // Scroll fade is applied inside heroMetadataOverlay to
                        // the text only — action buttons stay fully opaque so
                        // they remain in the tvOS focus hierarchy when scrolled off.
                        heroMetadataOverlay
                            .opacity(effectiveMetadataVisible ? 1 : 0)
                            .animation(.easeOut(duration: 0.35), value: effectiveMetadataVisible)
                            .frame(height: heroHeight)
                            .id("scrollTop")

                        // Below-fold page: ZStack decouples min height from content layout.
                        // Color.clear sets the height floor; the VStack sits on top
                        // at its natural size so no extra space leaks into children.
                        ZStack(alignment: .topLeading) {
                            // Invisible rect guarantees at least one screen of scroll room
                            Color.clear.frame(height: geo.size.height)

                            VStack(alignment: .leading, spacing: 0) {
                                VStack(alignment: .leading, spacing: 32) {
                                    // TV Show specific: Seasons and Episodes
                                    if currentItem.kind == .show || currentItem.kind == .episode {
                                        seasonSection
                                    }

                                    // Season specific: Episodes list (no season picker needed)
                                    if currentItem.kind == .season {
                                        episodeSection
                                    }


                                }
                                .padding(.top, belowFoldHeaderReserveHeight)
                                .padding(.horizontal, 48)
                                .allowsHitTesting(!isPreviewCarousel)

                                recommendedRow
                                collectionRow
                                castCrewRow
                            }
                            .fixedSize(horizontal: false, vertical: true)

                            belowFoldTitleLogo
                                .frame(height: 110)
                                .padding(.top, 40)
                                .padding(.bottom, 8)
                                .opacity(belowFoldTitleOpacity)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                        .opacity(belowFoldLoaded ? 1 : 0)
                        .animation(.easeOut(duration: 0.35), value: belowFoldLoaded)
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offset in
                    // Drive scroll progress continuously from offset so the
                    // reserve-height padding grows in lockstep with scrolling.
                    // Episodes stay visually fixed; the logo/material fade in
                    // proportionally without any compound animation overshoot.
                    let reserveDistance: CGFloat = 158
                    scrollProgress = min(1, max(0, offset / reserveDistance))
                    belowFoldTitleOpacity = min(1, max(0, (offset - 30) / 90))
                    if offset > 10 {
                        onDetailsBecameVisible?()
                    }
                }
                .id(scrollResetID)
                .scrollDisabled(isPreviewCarousel || !allowVerticalScroll)
                .defaultScrollAnchor(.top)
                .onChange(of: scrollToTopTrigger) { _, _ in
                    withAnimation(.easeInOut(duration: 0.4)) {
                        verticalProxy.scrollTo("scrollTop", anchor: .top)
                    }
                }
                } // ScrollViewReader
            }
        }
        .ignoresSafeArea()
        .task(id: detailLoadTaskID) {
            // Fetch detail immediately — not gated by
            // `previewAnimationSettled`. This is a single network call
            // with no layout churn, and it needs to land before the
            // text fade at ~750ms so genres/cast/summary are ready
            // when the hero metadata fades in.
            guard shouldLoadDetailData else {
                syncHeroBackdrop()
                return
            }
            detail = nil
            parentShowLogoPath = nil
            syncHeroBackdrop()
            await loadDetail()
            await refreshHeroBackdropAssets()

            // In non-carousel flows (direct navigation), the cascade gate
            // is already open so onChange(of: canRunDetailCascade) won't
            // fire (no change). Run the heavy cascade directly.
            if canRunDetailCascade {
                await loadDetailData()
            }
        }
        .onChange(of: shouldLoadDetailData) { _, isActive in
            // A previously-passive side card just became current. Load its
            // detail so the hero overlay has genres/cast/summary ready.
            guard isActive, detail == nil else { return }
            Task { @MainActor in
                await loadDetail()
                await refreshHeroBackdropAssets()
            }
        }
        .onChange(of: canRunDetailCascade) { _, canRun in
            // When a previously-passive card becomes current, or when the
            // entry animation finishes, re-invoke the cascade. The task
            // ID itself no longer changes on active/passive flips, so this
            // is the only path that promotes a side card's passive stub
            // into a full load.
            guard canRun else { return }
            Task { @MainActor in
                await loadDetailData()
            }
        }
        .task(id: "kenburns-\(currentItem.ref.itemID)") {
            guard !isPreviewCarousel, !isExpandedPreviewFlow else {
                kenBurnsOffset = 0
                return
            }
            // Ken Burns: wait for view to settle, then start slow backdrop drift
            kenBurnsOffset = 0
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 15).repeatForever(autoreverses: true)) {
                kenBurnsOffset = 50
            }
        }
        .onChange(of: presentationMode) { _, newMode in
            if newMode == .previewCarousel {
                displayedItem = nil
                focusedActionButton = nil
                // scrollProgress is scroll-driven; scrollTo resets the offset
                // which drives scrollProgress back to 0 via onScrollGeometryChange.
                scrollToTopTrigger.toggle()
            }
        }
        .onChange(of: heroBackdropMotionLocked) { _, locked in
            heroBackdrop.setMotionLocked(locked)
        }
        .onChange(of: heroBackdrop.session.logoURL) { _, newLogoURL in
            if let newLogoURL {
                retainedLogoURL = newLogoURL
            }
        }
        .onChange(of: currentItem.ref.itemID) { _, _ in
            retainedLogoURL = nil
            hasDisplayedHeroLogoImage = false
            parentShowLogoPath = nil
        }
        .onChange(of: showExpandedChrome) { _, isVisible in
            guard isVisible, isExpandedPreviewFlow else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                focusedActionButton = "play"
            }
        }
        .onChange(of: focusedEpisodeId) { _, newId in
            // Sync season pill when user navigates across season boundary
            guard let newId,
                  let episode = unifiedEpisodes.first(where: { $0.ratingKey == newId }),
                  episode.parentRatingKey != selectedSeason?.ratingKey,
                  let newSeason = seasons.first(where: { $0.ratingKey == episode.parentRatingKey }) else { return }
            selectedSeason = newSeason
        }
        .onAppear {
            guard isExpandedPreviewFlow, let bridge = menuBridge else { return }
            bridge.interceptHandler = { [self] in
                if navigateToSeason != nil {
                    navigateToSeason = nil
                    return true
                } else if navigateToShow != nil {
                    navigateToShow = nil
                    return true
                } else if navigateToEpisode != nil {
                    navigateToEpisode = nil
                    return true
                } else if scrollProgress > 0 || focusedEpisodeId != nil {
                    scrollToTopTrigger.toggle()
                    focusedEpisodeId = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        focusedActionButton = "play"
                    }
                    return true
                }
                return false
            }
        }
        .onDisappear {
            guard isExpandedPreviewFlow else { return }
            menuBridge?.interceptHandler = nil
        }
        .onChange(of: showPlayer) { _, shouldShow in
            if shouldShow {
                presentPlayer()
            }
        }
        .fullScreenCover(isPresented: $showTrailerPlayer) {
            // Play trailer using the same player as regular content
            if let metadata = trailerMetadata {
                UniversalPlayerView(metadata: metadata)
            }
        }
        .onChange(of: showTrailerPlayer) { _, isShowing in
            // Clear trailer metadata when player is dismissed
            if !isShowing {
                trailerMetadata = nil
            }
        }
        .onChange(of: showPlayer) { _, isShowing in
            // Clear selected episode and playFromBeginning when player closes
            if !isShowing {
                // Capture episode ratingKey before clearing for refresh
                let playedEpisodeKey = selectedEpisode?.ratingKey
                let lastPlayed = lastPlayedMetadata

                selectedEpisode = nil
                playFromBeginning = false
                lastPlayedMetadata = nil

                // If we're on an episode detail page and auto-play advanced to a different episode,
                // swap the displayed item so the detail page shows the last-played episode.
                // TODO(post-wave-1): map lastPlayed PlexMetadata → MediaItem for episode auto-advance swap
                if currentItem.kind == .episode,
                   let lastPlayed,
                   lastPlayed.ratingKey != currentItem.ref.itemID {
                    // Silently drop swap; episode-detail auto-advance is a post-wave-1 feature
                    _ = lastPlayed
                }

                // Refresh metadata to get updated viewOffset after playback
                Task {
                    await loadDetail()

                    // Update displayed progress and watched state from refreshed detail
                    if let d = detail {
                        withAnimation(.easeOut(duration: 0.3)) {
                            displayedProgress = effectiveWatchProgress ?? 0
                            isWatched = d.item.userState.isPlayed
                        }
                    }

                    // Also refresh the specific episode if one was played
                    if let episodeKey = playedEpisodeKey {
                        await refreshEpisodeWatchStatus(ratingKey: episodeKey)
                    }

                    // For show/season detail pages, also refresh episode list and next-up
                    if currentItem.kind == .show {
                        await loadAllEpisodes()
                        await loadNextUpEpisode()
                    } else if currentItem.kind == .season {
                        await loadEpisodesForSeason()
                        await loadNextUpEpisode()
                    }
                }
            }
        }
        // Navigation destinations only in standard flow (not preview overlay — no NavigationStack there)
        .modifier(NavigationDestinationsModifier(
            navigateToSeason: $navigateToSeason,
            navigateToShow: $navigateToShow,
            navigateToEpisode: $navigateToEpisode,
            isEnabled: onPreviewExitRequested == nil
        ))
    }

    private func heroContentHeight(for fullHeight: CGFloat) -> CGFloat {
        let shelfPeek: CGFloat
        switch currentItem.kind {
        case .show, .season, .episode:
            // TV detail surfaces should all expose the shelf at the same shallow depth.
            shelfPeek = 160
        default:
            shelfPeek = 220
        }

        return max(0, fullHeight - shelfPeek)
    }

    private var belowFoldHeaderReserveHeight: CGFloat {
        158 * scrollProgress
    }

    // MARK: - Hero Components (Apple TV+ style — backdrop fixed, content scrolls over)

    /// Fixed backdrop layer extracted to help the Swift type-checker.
    private func backdropLayer(stageSize: CGSize, geoSize: CGSize,
                               stageBaseOffset: CGPoint, windowOrigin: CGPoint) -> some View {
        heroBackdropImage
            .frame(width: stageSize.width, height: stageSize.height)
            .offset(
                x: stageBaseOffset.x - windowOrigin.x + backgroundParallaxOffset + kenBurnsOffset,
                y: stageBaseOffset.y - windowOrigin.y
            )
            .scaleEffect(heroBackdropScale)
            .frame(width: geoSize.width, height: geoSize.height)
            .clipped()
            .overlay { backdropScrollOverlay }
    }

    /// Material blur overlay driven by scroll progress.
    /// Extracted to avoid Swift type-checker complexity in the main body.
    @ViewBuilder
    private var backdropScrollOverlay: some View {
        // `.regularMaterial` is backed by `UIVisualEffectView` on tvOS, which runs a
        // blur render pass every frame. Gating on scrollProgress > 0.01 removes the
        // blur view from the tree entirely during the entry/paging animation.
        if scrollProgress > 0.01 {
            Rectangle()
                .fill(.regularMaterial)
                .opacity(scrollProgress)
        }
    }

    /// Fixed backdrop image (behind everything, doesn't scroll)
    private var heroBackdropImage: some View {
        HeroBackdropImage(
            url: heroBackdrop.session.displayedBackdropURL,
            animationDuration: isPreviewCarousel ? 0.38 : 0.26
        ) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    /// Gradient overlay for hero text readability (scrolls with content)
    private var heroGradient: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.5), location: 0.55),
                .init(color: .black.opacity(0.85), location: 0.75),
                .init(color: .black, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Metadata overlay (title, genres, quality, buttons, cast) positioned at bottom of hero
    private var heroMetadataOverlay: some View {
        GeometryReader { metaGeo in
            VStack(alignment: .leading, spacing: 10) {
                Spacer()

                // Text content — fixed height so buttons/peek distance
                // stays constant regardless of description length, logo vs title, etc.
                VStack(alignment: .leading, spacing: 14) {
                    // Plex clearLogo or title — fixed height so content below is always
                    // at the same position regardless of logo aspect ratio
                    Group {
                        if let logoURL = effectiveHeroLogoURL {
                            CachedAsyncImage(url: logoURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        // Shadow is redundant in carousel mode — the bottom
                                        // vignette at lines ~305-321 already hits 95% black
                                        // opacity where the logo sits, so the drop shadow is
                                        // invisible. Removing it during carousel avoids the
                                        // per-frame offscreen compositing pass the shadow forces
                                        // while `heroMetadataOverlay` opacity is animating.
                                        .shadow(
                                            color: .black.opacity(isPreviewCarousel ? 0 : 0.8),
                                            radius: isPreviewCarousel ? 0 : 20,
                                            x: 0,
                                            y: isPreviewCarousel ? 0 : 4
                                        )
                                        .onAppear {
                                            if !hasDisplayedHeroLogoImage {
                                                hasDisplayedHeroLogoImage = true
                                            }
                                        }
                                case .empty:
                                    if hasDisplayedHeroLogoImage {
                                        Color.clear
                                    } else {
                                        heroTitleText
                                    }
                                default:
                                    heroTitleText
                                }
                            }
                        } else {
                            heroTitleText
                        }
                    }
                    .frame(maxWidth: heroLogoMaxWidth, alignment: .leading)
                    .frame(height: heroLogoSlotHeight, alignment: .bottomLeading)

                    // Genre + content rating row
                    heroMetadataRow

                    // Description area (narrower than full metadata block, per Apple TV+ reference)
                    VStack(alignment: .leading, spacing: 4) {
                        if currentItem.kind == .episode {
                            if let epString = currentItemEpisodeString {
                                let title = currentItem.title
                                let header = epString + (title.isEmpty ? "" : " · \(title)")
                                let desc = detail?.item.overview ?? currentItem.overview ?? ""
                                (Text(header).bold() + Text(desc.isEmpty ? "" : ":  \(desc)"))
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .lineLimit(3)
                            }
                        } else if currentItem.kind == .show || currentItem.kind == .season {
                            if let tagline = detail?.tagline {
                                Text(tagline)
                                    .font(.caption)
                                    .italic()
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            if let summary = detail?.item.overview ?? currentItem.overview, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(3)
                            }
                        } else {
                            if let tagline = detail?.tagline {
                                Text(tagline)
                                    .font(.caption)
                                    .italic()
                                    .foregroundStyle(.white.opacity(0.9))
                            } else if let summary = detail?.item.overview ?? currentItem.overview, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(3)
                            }
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)

                    // Year · Duration · Quality badges
                    heroQualityRow

                    // Up Next caption
                    if let caption = upNextCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 420, alignment: .bottomLeading)
                .frame(maxWidth: 760, alignment: .leading)
                .opacity(1 - scrollProgress)

                // Bottom row: buttons (left) + starring (right) — full width
                // Buttons stay fully opaque (not faded by scroll) so tvOS keeps
                // them in the focus hierarchy for Up navigation from below-fold.
                HStack(alignment: .bottom, spacing: 0) {
                    actionButtons
                        .onMoveCommand { direction in
                            if direction == .up,
                               isExpandedPreviewFlow,
                               scrollProgress == 0 {
                                onPreviewExitRequested?()
                            }
                        }

                    Spacer(minLength: 40)

                    // Starring (comma-separated, right-aligned)
                    if let d = detail, !d.cast.isEmpty {
                        let topCast = d.cast.prefix(3).map { $0.name }
                        if !topCast.isEmpty {
                            Text("Starring \(topCast.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(3)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 460, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, heroActionRowTopPadding)
                .focusSection()
                .opacity(effectiveMetadataVisible ? 1 : 0)
                .allowsHitTesting(allowActionRowInteraction)
            }
            .padding(.horizontal, heroOverlayHorizontalInset)
            .animation(isPreviewCarousel ? nil : .easeInOut(duration: 0.3), value: currentItem.ref.itemID)
        }
    }

    // MARK: - Below-fold Title Logo (centered, Apple TV+ style)

    private var belowFoldTitleLogo: some View {
        Group {
            if let logoURL = effectiveHeroLogoURL {
                CachedAsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .onAppear {
                                if !hasDisplayedHeroLogoImage {
                                    hasDisplayedHeroLogoImage = true
                                }
                            }
                    case .empty:
                        if hasDisplayedHeroLogoImage {
                            Color.clear
                        } else {
                            Text(heroBrandTitle)
                                .font(.system(size: 42, weight: .bold))
                                .foregroundStyle(.primary)
                        }
                    default:
                        Text(heroBrandTitle)
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: 680, maxHeight: 126)
            } else {
                Text(heroBrandTitle)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Hero Sub-components

    private var heroTitleText: some View {
        Text(heroBrandTitle)
            .font(.system(size: 52, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
    }

    /// Genre tags + content rating badge (Apple TV+ style: "TV Show · Adventure · Sci-Fi [TV-14]")
    private var heroMetadataRow: some View {
        HStack(spacing: 8) {
            // Build label parts with dot separators
            let parts = heroMetadataParts
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("·")
                }
                Text(part)
            }

            // Content rating badge (bordered, at end)
            if let contentRating = detail?.contentRating {
                Text(contentRating)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.white.opacity(0.5), lineWidth: 1)
                    }
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
    }

    private var heroMetadataParts: [String] {
        var parts: [String] = []

        // Type label from kind
        switch currentItem.kind {
        case .show, .episode, .season:
            parts.append("TV Show")
        case .movie:
            parts.append("Movie")
        default:
            break
        }

        // Genres (up to 2 — keeps the row concise alongside the type label and rating badge)
        let genres = detail?.genres ?? []
        for genre in genres.prefix(2) {
            parts.append(genre)
        }

        return parts
    }

    /// Year, duration, quality badges row (Apple TV+ style: "2023 · 49 min [4K] [DV] [5.1]")
    private var heroQualityRow: some View {
        HStack(spacing: 8) {
            // Year · Duration with dot separator
            let year = currentItem.year
            let duration = currentItemDurationFormatted

            if let year {
                Text(String(year))
            }
            if year != nil && duration != nil {
                Text("·")
            }
            if let duration {
                Text(duration)
            }

            if let rating = detail?.rating {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.1f", rating))
                }
            }

            // Quality badges from MediaSource
            let badges = detail?.mediaSources.first?.qualityBadges() ?? []
            ForEach(badges, id: \.self) { badge in
                QualityBadge(text: badge)
            }
        }
        .font(.caption.bold())
        .foregroundStyle(.white)
    }

    /// Small badge for quality indicators (4K, DV, Atmos, etc.)
    private struct QualityBadge: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.15))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.white.opacity(0.3), lineWidth: 0.5)
                }
        }
    }

    /// Icon for fallback poster based on item kind
    private var iconForType: String {
        switch currentItem.kind {
        case .movie: return "film"
        case .show: return "tv"
        default: return "photo"
        }
    }

    /// Shuffle play all episodes for a show or season
    private func shufflePlay() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        let ratingKey = currentItem.ref.itemID
        isLoadingShufflePlay = true
        defer { isLoadingShufflePlay = false }

        do {
            // For seasons, use getChildren (allLeaves returns empty for seasons)
            // For shows, use getAllLeaves to get episodes across all seasons
            let allEpisodes: [PlexMetadata]
            if currentItem.kind == .season {
                allEpisodes = try await networkManager.getChildren(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
            } else {
                allEpisodes = try await networkManager.getAllLeaves(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
            }

            guard !allEpisodes.isEmpty else { return }

            var shuffled = allEpisodes
            shuffled.shuffle()

            selectedEpisode = shuffled[0]
            shuffledEpisodeQueue = shuffled
            playFromBeginning = true
            showPlayer = true
        } catch {
            print("Failed to load episodes for shuffle play: \(error)")
        }
    }

    // MARK: - Summary Section (Full, below fold)

    @ViewBuilder
    private func fullSummarySection(summary: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isSummaryExpanded.toggle()
            }
        } label: {
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(isSummaryExpanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action Buttons (Apple TV+ style)

    private let pillButtonHeight: CGFloat = 66
    private let circleButtonSize: CGFloat = 66

    private var actionButtons: some View {
        HStack(spacing: 18) {
            // Primary play button with inline progress + time remaining
            if currentItem.kind == .show || currentItem.kind == .season {
                Button {
                    if let episode = nextUpEpisode { selectedEpisode = episode }
                    playFromBeginning = false
                    showPlayer = true
                } label: {
                    playButtonLabel(text: showPlayButtonLabel, isFocused: focusedActionButton == "play")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.horizontal, 32)
                        .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play", cornerRadius: pillButtonHeight / 2))
                .focused($focusedActionButton, equals: "play")
                .disabled(nextUpEpisode == nil)

                // Shuffle
                Button {
                    Task { await shufflePlay() }
                } label: {
                    HStack(spacing: 10) {
                        if isLoadingShufflePlay {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "shuffle")
                        }
                        Text("Shuffle")
                    }
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 32)
                    .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "shuffle", cornerRadius: pillButtonHeight / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "shuffle")
                .disabled(isLoadingShufflePlay)
            } else {
                // Movies/Episodes: Play button with progress bar + time remaining
                Button {
                    playFromBeginning = false
                    showPlayer = true
                } label: {
                    playButtonLabel(text: effectiveIsInProgress ? "Resume" : "Play", isFocused: focusedActionButton == "play")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.horizontal, 32)
                        .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play", cornerRadius: pillButtonHeight / 2))
                .focused($focusedActionButton, equals: "play")
            }

            // Watched toggle — perfect circle checkmark button
            Button {
                Task { await toggleWatched() }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: circleButtonSize, height: circleButtonSize)
            }
            .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "watched", cornerRadius: circleButtonSize / 2, isPrimary: false))
            .focused($focusedActionButton, equals: "watched")

            // Trailer button — perfect circle
            if detail?.trailerURL != nil {
                Button {
                    Task { await loadAndPlayTrailer() }
                } label: {
                    Image(systemName: "film")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "trailer", cornerRadius: circleButtonSize / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "trailer")
            }
        }
        .disabled(!allowActionRowInteraction)
    }

    /// Play button label with inline progress bar + time remaining (Apple TV+ style)
    private func playButtonLabel(text: String, isFocused: Bool = false) -> some View {
        let trackColor = isFocused ? Color.black.opacity(0.2) : Color.white.opacity(0.3)
        let fillColor = isFocused ? Color.black : Color.white

        return HStack(spacing: 10) {
            Image(systemName: "play.fill")

            // Progress bar (always shown — full track for unwatched, partial for in-progress)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(trackColor)
                    .frame(width: 80, height: 5)
                if displayedProgress > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fillColor)
                        .frame(width: 80 * displayedProgress, height: 5)
                }
            }

            // Time: remaining if in progress, total duration otherwise
            if effectiveIsInProgress, let remaining = effectiveRemainingFormatted {
                Text(remaining)
            } else if let duration = currentItemDurationFormatted {
                Text(duration)
            } else {
                Text(text)
            }
        }
    }

    // MARK: - Season Section (TV Shows)

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoadingSeasons {
                ProgressView("Loading seasons...")
            } else if !seasons.isEmpty {
                SeasonPillBar(
                    seasons: seasons,
                    selectedSeason: $selectedSeason,
                    onSeasonSelected: { season in
                        // Scroll episode list to this season's first episode
                        if let firstEp = unifiedEpisodes.first(where: { $0.parentRatingKey == season.ratingKey }),
                           let epKey = firstEp.ratingKey {
                            episodeScrollTarget = epKey
                        }
                    }
                )
                .opacity(scrollProgress)
                .onMoveCommand { direction in
                    if direction == .up {
                        scrollToTopTrigger.toggle()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            focusedActionButton = "play"
                        }
                    }
                }

                // Unified horizontal episode cards across all seasons
                unifiedEpisodeList
            }
        }
    }

    private var shouldUseSingleSeasonPillHeaderInSeasonDetail: Bool {
        currentItem.kind == .season && seasons.count <= 1
    }

    private var seasonDetailHeaderPills: [PlexMetadata] {
        let currentKey = currentItem.ref.itemID
        let matchingSeason = seasons.filter { $0.ratingKey == currentKey }
        if !matchingSeason.isEmpty {
            return matchingSeason
        }
        if let selected = selectedSeason {
            return [selected]
        }
        return []
    }

    /// Unified horizontal episode card row across all seasons
    private var unifiedEpisodeList: some View {
        Group {
            if unifiedEpisodes.isEmpty && isLoadingEpisodes {
                ProgressView("Loading episodes...")
                    .padding(.top, 20)
            } else if !unifiedEpisodes.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 0) {
                            ForEach(Array(unifiedEpisodes.enumerated()), id: \.element.ratingKey) { index, episode in
                                let isSeasonBoundary = index > 0 && episode.parentRatingKey != unifiedEpisodes[index - 1].parentRatingKey
                                let leadingPad: CGFloat = index == 0 ? 48 : (isSeasonBoundary ? 56 : 24)

                                EpisodeCard(
                                    episode: episode,
                                    serverURL: authManager.selectedServerURL ?? "",
                                    authToken: authManager.selectedServerToken ?? "",
                                    focusedEpisodeId: $focusedEpisodeId,
                                    showSeasonPrefix: seasons.count > 1,
                                    onPlay: {
                                        selectedEpisode = episode
                                        playFromBeginning = false
                                        showPlayer = true
                                    },
                                    onRefreshNeeded: {
                                        await refreshEpisodeWatchStatus(ratingKey: episode.ratingKey)
                                    },
                                    onShowInfo: {
                                        let sURL = authManager.selectedServerURL ?? ""
                                        let tok = authManager.selectedServerToken ?? ""
                                        if let prov = providerRegistry.primaryProvider {
                                            navigateToEpisode = PlexMediaMapper.item(
                                                episode, providerID: prov.id,
                                                serverURL: sURL, authToken: tok)
                                        }
                                    }
                                )
                                .padding(.leading, leadingPad)
                                .padding(.trailing, index == unifiedEpisodes.count - 1 ? 48 : 0)
                                .id(episode.ratingKey)
                            }
                        }
                        .padding(.vertical, 16)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                    .onMoveCommand { direction in
                        guard direction == .up, seasons.count <= 1 else { return }
                        scrollToTopTrigger.toggle()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            focusedActionButton = "play"
                        }
                    }
                    .onChange(of: episodeScrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(target, anchor: .leading)
                        }
                        episodeScrollTarget = nil
                    }
                }
            }
        }
    }

    // MARK: - Episode Section (Seasons)

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if isLoadingEpisodes || isLoadingSeasons {
                ProgressView("Loading episodes...")
            } else if !episodes.isEmpty {
                if shouldUseSingleSeasonPillHeaderInSeasonDetail {
                    SeasonPillBar(
                        seasons: seasonDetailHeaderPills,
                        selectedSeason: $selectedSeason,
                        onSeasonSelected: { _ in }
                    )
                    .opacity(scrollProgress)
                } else {
                    Text("Episodes")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.leading, 48)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 24) {
                        ForEach(episodes, id: \.ratingKey) { episode in
                            EpisodeCard(
                                episode: episode,
                                serverURL: authManager.selectedServerURL ?? "",
                                authToken: authManager.selectedServerToken ?? "",
                                focusedEpisodeId: $focusedEpisodeId,
                                onPlay: {
                                    selectedEpisode = episode
                                    playFromBeginning = false
                                    showPlayer = true
                                },
                                onRefreshNeeded: {
                                    await refreshEpisodeWatchStatus(ratingKey: episode.ratingKey)
                                },
                                onShowInfo: {
                                    let sURL = authManager.selectedServerURL ?? ""
                                    let tok = authManager.selectedServerToken ?? ""
                                    if let prov = providerRegistry.primaryProvider {
                                        navigateToEpisode = PlexMediaMapper.item(
                                            episode, providerID: prov.id,
                                            serverURL: sURL, authToken: tok)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.vertical, 16)
                }
                .scrollClipDisabled()
                .focusSection()
                .remembersFocus(key: "detailEpisodes", focusedId: $focusedEpisodeId)
            }
        }
    }

    // MARK: - Player Presentation (tvOS)

    /// Present player using UIViewController to intercept Menu button
    private func presentPlayer() {
        // Get images and metadata, then present player
        Task {
            // Determine which item to play and fetch full metadata if needed (for DV/HDR detection)
            let playItem: PlexMetadata
            if let episode = selectedEpisode {
                // Fetch full metadata on-demand for episodes (avoids N+1 prefetch - Fixes RIVULET-V)
                if let ratingKey = episode.ratingKey, let fullEpisode = fullEpisodeMetadata[ratingKey] {
                    playItem = fullEpisode
                } else if let ratingKey = episode.ratingKey,
                          let serverURL = authManager.selectedServerURL,
                          let token = authManager.selectedServerToken {
                    // Fetch full metadata now (single request vs N+1 prefetch)
                    do {
                        let metadata = try await networkManager.getFullMetadata(
                            serverURL: serverURL,
                            authToken: token,
                            ratingKey: ratingKey
                        )
                        fullEpisodeMetadata[ratingKey] = metadata
                        playItem = metadata
                    } catch {
                        // Fall back to basic metadata if fetch fails
                        playItem = episode
                    }
                } else {
                    playItem = episode
                }
            } else {
                // For main item (movie), ensure full metadata with Stream data for DV/HDR detection.
                // Hub metadata often lacks Stream details needed for Dolby Vision profile detection.
                let ratingKey = item.ref.itemID
                if let serverURL = authManager.selectedServerURL,
                   let token = authManager.selectedServerToken,
                   !ratingKey.isEmpty {
                    do {
                        let metadata = try await networkManager.getFullMetadata(
                            serverURL: serverURL,
                            authToken: token,
                            ratingKey: ratingKey
                        )
                        playItem = metadata
                    } catch {
                        // Fall back to a basic fetch
                        if let meta = try? await networkManager.getMetadata(
                            serverURL: serverURL,
                            authToken: token,
                            ratingKey: ratingKey
                        ) {
                            playItem = meta
                        } else {
                            return  // Can't play without metadata
                        }
                    }
                } else {
                    return  // Can't play without auth
                }
            }

            // Use detail for updated viewOffset when playing the main item (not episodes)
            let viewOffset: Int?
            if selectedEpisode == nil {
                // Convert seconds back to ms for legacy playItem.viewOffset compatibility
                let offsetSeconds = detail?.item.userState.viewOffset ?? playItem.viewOffset.map { Double($0) / 1000.0 } ?? 0
                viewOffset = Int(offsetSeconds * 1000)
            } else {
                viewOffset = playItem.viewOffset
            }
            let resumeOffset = playFromBeginning ? nil : (Double(viewOffset ?? 0) / 1000.0)

            // Get images for loading screen (from cache or fetch if needed)
            let (artImage, thumbImage) = await getPlayerImages(for: playItem)

            await MainActor.run {
                // Create viewModel with cached images for instant loading screen display
                let queue = shuffledEpisodeQueue
                shuffledEpisodeQueue = []

                let viewModel = UniversalPlayerViewModel(
                    metadata: playItem,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? "",
                    startOffset: resumeOffset != nil && resumeOffset! > 0 ? resumeOffset : nil,
                    shuffledQueue: queue,
                    loadingArtImage: artImage,
                    loadingThumbImage: thumbImage
                )

                let useApplePlayer = UserDefaults.standard.bool(forKey: "useApplePlayer")
                let playerVC: UIViewController
                if useApplePlayer {
                    let nativePlayer = NativePlayerViewController(viewModel: viewModel)
                    nativePlayer.onDismiss = { [weak viewModel] in
                        lastPlayedMetadata = viewModel?.metadata
                        showPlayer = false
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
                    container.onDismiss = { [weak viewModel] in
                        lastPlayedMetadata = viewModel?.metadata
                        showPlayer = false
                    }
                    playerVC = container
                }

                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    topVC.present(playerVC, animated: true)
                }
            }
        }
    }

    /// Get art and poster images for the player loading screen (from cache or fetch)
    private func getPlayerImages(for metadata: PlexMetadata) async -> (UIImage?, UIImage?) {
        guard let request = playerHeroBackdropRequest(for: metadata) else {
            return (nil, nil)
        }

        return await HeroBackdropResolver.shared.playerLoadingImages(for: request)
    }

    // MARK: - Data Loading

    /// Hydrates everything the detail view needs beyond the hero surface
    /// (cast, seasons, episodes, recommendations, etc.). Split out of the
    /// inline `.task` body so it can be invoked from both the initial task
    /// and the `canRunDetailCascade` onChange observer without duplicating
    /// the reset/cascade logic.
    ///
    /// The method is gated twice:
    /// 1. `shouldLoadDetailData` — only the *current* carousel card runs.
    ///    Passive side cards still call `syncHeroBackdrop()` so they show
    ///    the correct logo/art, then early-return.
    /// 2. `previewAnimationSettled` — even for the current card, the cascade
    ///    waits for the entry spring + staged fades to finish, and for
    ///    paging motion to stop. This keeps the main thread quiet during
    ///    the ~1.5s animation window.
    private func loadDetailData() async {
        // Passive carousel cards should keep any already-resolved metadata/logo
        // so transitions never swap logo -> title mid-motion.
        guard shouldLoadDetailData else {
            syncHeroBackdrop()
            return
        }

        // Defer network + state-reset churn until the entry/paging animation
        // settles. The onChange(of: canRunDetailCascade) observer will
        // re-invoke this method once `previewAnimationSettled` flips to true.
        guard previewAnimationSettled else {
            syncHeroBackdrop()
            return
        }

        // Reset below-fold state — stays hidden until the full cascade
        // completes so sections don't pop in one at a time.
        // fullMetadata + parentShowLogoPath are reset in the ungated
        // .task above (they run during the entry animation).
        belowFoldLoaded = false
        seasons = []
        episodes = []
        selectedSeason = nil
        unifiedEpisodes = []
        episodeScrollTarget = nil
        collectionItems = []
        collectionName = nil
        recommendedItems = []
        nextUpEpisode = nil
        isSummaryExpanded = false
        scrollProgress = 0
        belowFoldTitleOpacity = 0
        syncHeroBackdrop()

        // Index for Siri search
        browseActivity?.resignCurrent()
        let activity = NSUserActivity(activityType: "com.rivulet.viewMedia")
        activity.title = currentItem.title
        activity.isEligibleForSearch = true
        activity.userInfo = ["ratingKey": currentItem.ref.itemID]
        activity.targetContentIdentifier = "rivulet://detail?ratingKey=\(currentItem.ref.itemID)"
        activity.becomeCurrent()
        browseActivity = activity

        // Initialize watched state
        isWatched = currentItem.userState.isPlayed

        // Initialize progress for animation
        displayedProgress = effectiveWatchProgress ?? 0

        // detail + refreshHeroBackdropAssets are handled by the
        // ungated .task(id: detailLoadTaskID) above so they fire during
        // the entry animation and land before the text fade. By the time
        // we reach here, detail is already populated.

        // Load type-specific data — run independent calls in parallel
        // where possible so the total wall-clock time is the slowest
        // single call, not the sum.
        switch currentItem.kind {
        case .movie:
            // Collection + recommendations are independent of each other
            async let collectionTask: Void = {
                // TODO(post-wave-1): collectionItems returns [] for Wave 1; skip fetch
                // Collection name comes from detail?.collections, but we need a library
                // context to call collectionItems(matching:in:) — not available yet.
                _ = detail?.collections
            }()
            async let recommendTask: Void = loadRecommendedItems()
            _ = await (collectionTask, recommendTask)

        case .show:
            // Seasons and all-episodes are independent network calls
            async let seasonsTask: Void = loadSeasons()
            async let episodesTask: Void = loadAllEpisodes()
            async let nextUpTask: Void = loadNextUpEpisode()
            _ = await (seasonsTask, episodesTask, nextUpTask)

        case .season:
            async let seasonsTask: Void = loadSeasonsForCurrentSeason()
            async let episodesTask: Void = loadEpisodesForSeason()
            async let nextUpTask: Void = loadNextUpEpisode()
            _ = await (seasonsTask, episodesTask, nextUpTask)

        case .episode:
            async let seasonsTask: Void = loadSeasonsForEpisode()
            async let episodesTask: Void = loadAllEpisodes()
            _ = await (seasonsTask, episodesTask)

        default:
            break
        }

        // Warm the first batch of episode/recommendation thumbnails into the
        // image cache so they're instant when the below-fold fades in.
        // CachedAsyncImage checks the memory cache synchronously — if the
        // image is there, it renders on the first frame with no flash.
        await prefetchBelowFoldThumbnails()

        // All below-fold data + thumbnails are now populated — fade in.
        belowFoldLoaded = true
    }

    /// Warms the first visible episode / recommendation / collection
    /// thumbnails into the memory cache so `CachedAsyncImage` hits the
    /// synchronous path on first render — no flash, no placeholder frame.
    /// Caps at ~10 images to avoid delaying the below-fold reveal.
    private func prefetchBelowFoldThumbnails() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        var urls: [URL] = []

        // Episode thumbnails (first ~8 visible in the horizontal scroll)
        let visibleEpisodes = Array(unifiedEpisodes.prefix(8)) + Array(episodes.prefix(8))
        for ep in visibleEpisodes {
            if let thumb = ep.thumb, let url = URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)") {
                urls.append(url)
            }
        }

        // Recommendation / collection poster thumbnails (first ~6)
        let posterItems = Array(recommendedItems.prefix(6)) + Array(collectionItems.prefix(6))
        for item in posterItems {
            if let thumb = item.thumb ?? item.bestThumb,
               let url = URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)") {
                urls.append(url)
            }
        }

        guard !urls.isEmpty else { return }

        // Load concurrently (up to 8 at a time via the cache's coalescing)
        await withTaskGroup(of: Void.self) { group in
            for url in urls.prefix(12) {
                group.addTask {
                    _ = await ImageCacheManager.shared.image(for: url)
                }
            }
        }
    }

    /// Fetch detail via provider (or fallback metadataSource). Also pre-warms stream URL.
    private func loadDetail() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        let ratingKey = currentItem.ref.itemID
        isLoadingExtras = true

        if let prov = provider {
            do {
                let d = try await prov.fullDetail(for: currentItem.ref)
                detail = d
                // TODO(post-wave-1): pre-warm stream URL via provider.resolveStream(for:)
                // MediaSource no longer exposes a Plex part key — keep this as a no-op for now.
                _ = serverURL; _ = token
            } catch {
                print("[MediaDetailView] provider.fullDetail failed: \(error)")
            }
        } else if let metaSrc = metadataSource {
            do {
                detail = try await metaSrc.itemDetail(currentItem.ref)
            } catch {
                print("[MediaDetailView] metadataSource.itemDetail failed: \(error)")
            }
        }

        isLoadingExtras = false
    }

    private func syncHeroBackdrop() {
        let request = currentHeroBackdropRequest()
        heroBackdrop.load(request: request, motionLocked: heroBackdropMotionLocked)
    }

    /// Re-syncs the hero backdrop after detail has loaded. For episodes
    /// and seasons, also fetches the parent show's metadata so its `clearLogo`
    /// can be folded into the request.
    private func refreshHeroBackdropAssets() async {
        if currentItem.kind == .episode || currentItem.kind == .season {
            await loadParentShowLogoPath()
        }
        syncHeroBackdrop()
    }

    private func currentHeroBackdropRequest() -> HeroBackdropRequest? {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }

        // Build a HeroBackdropRequest from the MediaItem's artwork URLs.
        // detail.item has fresher data when available; fall back to currentItem.
        let sourceItem = detail?.item ?? currentItem
        let backdropURL = sourceItem.artwork.backdrop
        let thumbURL = sourceItem.artwork.thumbnail ?? sourceItem.artwork.poster
        let logoURL = sourceItem.artwork.logo.flatMap { url -> URL? in
            // Logo path stored as relative in artwork.logo? No — it's already a URL.
            return url
        }

        // For episodes/seasons, grandparentArtwork carries the show backdrop.
        let effectiveBackdrop = backdropURL
            ?? sourceItem.grandparentArtwork?.backdrop
            ?? sourceItem.parentArtwork?.backdrop

        // parentShowLogoPath is a Plex-relative path; convert to URL if present.
        var effectiveLogoURL = logoURL
        if let logoPath = parentShowLogoPath,
           let url = URL(string: "\(serverURL)\(logoPath)?X-Plex-Token=\(token)") {
            effectiveLogoURL = url
        }

        return HeroBackdropRequest(
            cacheKey: currentItem.ref.itemID,
            plexBackdropURL: effectiveBackdrop,
            plexThumbnailURL: thumbURL,
            plexLogoURL: effectiveLogoURL
        )
    }

    private func playerHeroBackdropRequest(for metadata: PlexMetadata) -> HeroBackdropRequest? {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }

        let backdropSource = (metadata.type == "episode" && selectedEpisode != nil) ? currentItem : nil
        if let plexMeta = backdropSource {
            // currentItem is a MediaItem — build from artwork
            let backdropURL = plexMeta.artwork.backdrop ?? plexMeta.grandparentArtwork?.backdrop
            let thumbURL = plexMeta.artwork.thumbnail ?? plexMeta.artwork.poster
            var effectiveLogoURL: URL? = nil
            if let logoPath = parentShowLogoPath,
               let url = URL(string: "\(serverURL)\(logoPath)?X-Plex-Token=\(token)") {
                effectiveLogoURL = url
            }
            return HeroBackdropRequest(
                cacheKey: plexMeta.ref.itemID,
                plexBackdropURL: backdropURL,
                plexThumbnailURL: thumbURL,
                plexLogoURL: effectiveLogoURL
            )
        }

        let thumbPath = metadata.thumb ?? metadata.bestThumb
        let thumbURL = thumbPath.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }
        let backdropURL = metadata.bestArt.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }
        return HeroBackdropRequest(
            cacheKey: metadata.ratingKey ?? currentItem.ref.itemID,
            plexBackdropURL: backdropURL,
            plexThumbnailURL: thumbURL,
            plexLogoURL: nil
        )
    }

    /// Fetches the parent show's full metadata (using the cached copy when
    /// fresh) and extracts its clearLogo path for use on episode/season views.
    private func loadParentShowLogoPath() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showRatingKey = relatedShowRatingKey else {
            return
        }

        if let cached = PlexDataStore.shared.getCachedFullMetadata(for: showRatingKey),
           PlexDataStore.shared.isFullMetadataFresh(for: showRatingKey) {
            parentShowLogoPath = cached.clearLogoPath
            return
        }

        do {
            let showMetadata = try await networkManager.getFullMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showRatingKey
            )
            PlexDataStore.shared.cacheFullMetadata(showMetadata, for: showRatingKey)
            parentShowLogoPath = showMetadata.clearLogoPath
        } catch {
            print("🎨 [Logo] Failed to fetch parent show metadata: \(error)")
        }
    }

    /// Pre-compute and cache stream URL to reduce player startup latency
    private func preWarmStreamURL(for metadata: PlexMetadata, serverURL: String, authToken: String) {
        guard let ratingKey = metadata.ratingKey,
              let partKey = metadata.Media?.first?.Part?.first?.key else { return }

        // Build direct play URL for playback prewarming
        if let url = networkManager.buildPlaybackDirectPlayURL(
            serverURL: serverURL,
            authToken: authToken,
            partKey: partKey
        ) {
            let headers = [
                "X-Plex-Token": authToken,
                "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
                "X-Plex-Platform": PlexAPI.platform,
                "X-Plex-Device": PlexAPI.deviceName,
                "X-Plex-Product": PlexAPI.productName
            ]
            StreamURLCache.shared.set(ratingKey: ratingKey, url: url, headers: headers)
            Task(priority: .utility) {
                await networkManager.warmDirectPlayStream(url: url, headers: headers)
            }
        }
    }

    private func loadCollectionItems(sectionId: String, collectionId: String, name: String) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        do {
            let items = try await networkManager.getCollectionItems(
                serverURL: serverURL,
                authToken: token,
                sectionId: sectionId,
                collectionId: collectionId,
                excludeRatingKey: currentItem.ref.itemID
            )
            collectionItems = items
            collectionName = name
        } catch {
            print("Failed to load collection items: \(error)")
        }
    }

    private func loadRecommendedItems() async {
        // Fetch recommendations via the provider when available.
        // TODO(post-wave-1): replace PersonalizedRecommendationService with provider.relatedItems
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let ratingKey = currentItem.ref.itemID
        do {
            // Build a minimal PlexMetadata shell for the recommendation service
            let shellMeta = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            let items = try await recommendationService.recommendationsForItem(shellMeta, blendWithHistory: true, limit: 12)
            recommendedItems = items
        } catch {
            print("Failed to load recommended items: \(error)")
        }
    }

    /// Determine the "next up" episode for the Play button on TV shows and seasons
    /// Uses detail?.nextEpisode if available, otherwise falls back to first unwatched episode
    private func loadNextUpEpisode() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // For seasons, find the next up episode from the loaded episodes
        if currentItem.kind == .season {
            await loadNextUpEpisodeForSeason()
            return
        }

        guard currentItem.kind == .show else { return }

        // Try to get nextEpisode from detail (replaces OnDeck.Metadata.first)
        if let nextItem = detail?.nextEpisode,
           let ratingKey = URL(string: nextItem.ref.itemID).map({ _ in nextItem.ref.itemID }) ?? Optional(nextItem.ref.itemID) {
            // Fetch full PlexMetadata for the episode (includes Stream data for DV detection)
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
                return
            } catch {
                // Fall back to building a basic PlexMetadata-like episode from the MediaItem
                // by fetching the basic metadata
                if let basicMeta = try? await networkManager.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                ) {
                    nextUpEpisode = basicMeta
                }
                return
            }
        }

        // No OnDeck episode - search unifiedEpisodes if available
        if !unifiedEpisodes.isEmpty {
            let candidate = unifiedEpisodes.first(where: { $0.isInProgress })
                ?? unifiedEpisodes.first(where: { !$0.isWatched })
                ?? unifiedEpisodes.first

            if let candidate, let ratingKey = candidate.ratingKey {
                do {
                    nextUpEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL, authToken: token, ratingKey: ratingKey
                    )
                } catch {
                    nextUpEpisode = candidate
                }
            }
            return
        }

        // Fallback: per-season API calls (unifiedEpisodes not yet loaded)
        for season in seasons {
            guard let seasonRatingKey = season.ratingKey else { continue }

            do {
                let seasonEpisodes = try await networkManager.getChildren(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: seasonRatingKey
                )

                // First, look for an in-progress episode in this season
                if let inProgressEpisode = seasonEpisodes.first(where: { $0.isInProgress }),
                   let ratingKey = inProgressEpisode.ratingKey {
                    let fullEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                    nextUpEpisode = fullEpisode
                    return
                }

                // Next, look for first unwatched episode in this season
                if let unwatchedEpisode = seasonEpisodes.first(where: { !$0.isWatched }),
                   let ratingKey = unwatchedEpisode.ratingKey {
                    let fullEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                    nextUpEpisode = fullEpisode
                    return
                }
            } catch {
                print("Failed to load episodes for season: \(error)")
            }
        }

        // All episodes watched - fall back to first episode of first season
        if let firstSeason = seasons.first,
           let seasonRatingKey = firstSeason.ratingKey {
            do {
                let seasonEpisodes = try await networkManager.getChildren(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: seasonRatingKey
                )
                if let firstEpisode = seasonEpisodes.first,
                   let ratingKey = firstEpisode.ratingKey {
                    let fullEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                    nextUpEpisode = fullEpisode
                }
            } catch {
                print("Failed to load first episode: \(error)")
            }
        }
    }

    /// Determine the "next up" episode for seasons
    /// Finds the first in-progress or unwatched episode, falls back to first episode
    private func loadNextUpEpisodeForSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // First, look for an in-progress episode
        if let inProgressEpisode = episodes.first(where: { $0.isInProgress }),
           let ratingKey = inProgressEpisode.ratingKey {
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
                return
            } catch {
                nextUpEpisode = inProgressEpisode
                return
            }
        }

        // Next, look for the first unwatched episode
        if let unwatchedEpisode = episodes.first(where: { !$0.isWatched }),
           let ratingKey = unwatchedEpisode.ratingKey {
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
                return
            } catch {
                nextUpEpisode = unwatchedEpisode
                return
            }
        }

        // All episodes watched - fall back to first episode
        if let firstEpisode = episodes.first,
           let ratingKey = firstEpisode.ratingKey {
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
            } catch {
                nextUpEpisode = firstEpisode
            }
        }
    }

    private func loadAndPlayTrailer() async {
        // detail?.trailerURL is already a playable URL
        // TODO(post-wave-1): stream trailer directly via trailerURL instead of fetching PlexMetadata
        // For now, derive ratingKey from URL path if it's a Plex trailer reference
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let trailerURL = detail?.trailerURL else { return }

        // Extract ratingKey from Plex trailer URL (e.g. /library/metadata/12345/extras/...)
        // If not a Plex URL, skip for now
        let path = trailerURL.path
        let components = path.split(separator: "/")
        if let metaIndex = components.firstIndex(of: "metadata"),
           metaIndex + 1 < components.endIndex {
            let ratingKey = String(components[metaIndex + 1])
            do {
                let metadata = try await networkManager.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                trailerMetadata = metadata
                showTrailerPlayer = true
            } catch {
                print("Failed to load trailer metadata: \(error)")
            }
        }
    }

    private func toggleWatched() async {
        let ratingKey = currentItem.ref.itemID

        do {
            if isWatched {
                if let prov = provider {
                    try await prov.markUnplayed(currentItem.ref)
                } else if let serverURL = authManager.selectedServerURL,
                          let token = authManager.selectedServerToken {
                    try await networkManager.markUnwatched(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                }
                isWatched = false
            } else {
                if let prov = provider {
                    try await prov.markPlayed(currentItem.ref)
                } else if let serverURL = authManager.selectedServerURL,
                          let token = authManager.selectedServerToken {
                    try await networkManager.markWatched(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                }
                // Animate progress bar to 100% before marking as watched
                withAnimation(.easeOut(duration: 0.5)) {
                    displayedProgress = 1.0
                }
                // After animation, mark as watched and hide progress
                try? await Task.sleep(nanoseconds: 500_000_000)
                isWatched = true
            }
            // Notify home screen to refresh Continue Watching
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
        } catch {
            print("Failed to toggle watched status: \(error)")
        }
    }

    // MARK: - Episode Navigation

    /// Navigate to the parent season of the current episode
    private func navigateToParentSeason() async {
        guard let seasonRef = currentItem.parentRef else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            if let prov = provider {
                let d = try await prov.fullDetail(for: seasonRef)
                navigateToSeason = d.item
            } else if let serverURL = authManager.selectedServerURL,
                      let token = authManager.selectedServerToken {
                let seasonMetadata = try await networkManager.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: seasonRef.itemID
                )
                let prov0 = providerRegistry.primaryProvider
                navigateToSeason = prov0.map {
                    PlexMediaMapper.item(seasonMetadata, providerID: $0.id,
                                        serverURL: serverURL, authToken: token)
                }
            }
        } catch {
            print("Failed to load season metadata: \(error)")
        }
    }

    /// Navigate to the parent show of the current episode
    private func navigateToParentShow() async {
        guard let showRef = currentItem.grandparentRef else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            if let prov = provider {
                let d = try await prov.fullDetail(for: showRef)
                navigateToShow = d.item
            } else if let serverURL = authManager.selectedServerURL,
                      let token = authManager.selectedServerToken {
                let showMetadata = try await networkManager.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: showRef.itemID
                )
                let prov0 = providerRegistry.primaryProvider
                navigateToShow = prov0.map {
                    PlexMediaMapper.item(showMetadata, providerID: $0.id,
                                        serverURL: serverURL, authToken: token)
                }
            }
        } catch {
            print("Failed to load show metadata: \(error)")
        }
    }

    /// Navigate to the parent show from a season (season's parent is the show)
    private func navigateToParentShowFromSeason() async {
        guard let showRef = currentItem.parentRef else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            if let prov = provider {
                let d = try await prov.fullDetail(for: showRef)
                navigateToShow = d.item
            } else if let serverURL = authManager.selectedServerURL,
                      let token = authManager.selectedServerToken {
                let showMetadata = try await networkManager.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: showRef.itemID
                )
                let prov0 = providerRegistry.primaryProvider
                navigateToShow = prov0.map {
                    PlexMediaMapper.item(showMetadata, providerID: $0.id,
                                        serverURL: serverURL, authToken: token)
                }
            }
        } catch {
            print("Failed to load show metadata: \(error)")
        }
    }

    private func loadSeasons() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        let ratingKey = currentItem.ref.itemID
        isLoadingSeasons = true

        do {
            let fetchedSeasons = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            seasons = fetchedSeasons

            // Auto-select first season
            if let first = fetchedSeasons.first {
                selectedSeason = first
            }
        } catch {
            print("Failed to load seasons: \(error)")
        }

        isLoadingSeasons = false
    }

    /// Load seasons when viewing an episode - displays the parent show's seasons inline
    private func loadSeasonsForEpisode() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showRatingKey = currentItem.grandparentRef?.itemID else { return }

        isLoadingSeasons = true

        do {
            let fetchedSeasons = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showRatingKey
            )
            seasons = fetchedSeasons

            // Select the season this episode belongs to
            // Note: We don't set focusedSeasonId here - focus should stay on action buttons
            // The ScrollViewReader will scroll the season into view when user navigates down
            if let currentSeasonKey = currentItem.parentRef?.itemID,
               let currentSeason = fetchedSeasons.first(where: { $0.ratingKey == currentSeasonKey }) {
                selectedSeason = currentSeason
            } else if let first = fetchedSeasons.first {
                // Fallback to first season
                selectedSeason = first
            }
        } catch {
            print("Failed to load seasons for episode: \(error)")
        }

        isLoadingSeasons = false
    }

    /// Load sibling seasons when viewing a season so single-season shows can
    /// keep the season-pill header pattern instead of falling back to `Episodes`.
    private func loadSeasonsForCurrentSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showRatingKey = currentItem.parentRef?.itemID else { return }

        isLoadingSeasons = true

        do {
            let fetchedSeasons = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showRatingKey
            )
            seasons = fetchedSeasons

            let currentSeasonKey = currentItem.ref.itemID
            if let currentSeason = fetchedSeasons.first(where: { $0.ratingKey == currentSeasonKey }) {
                selectedSeason = currentSeason
            } else if let first = fetchedSeasons.first {
                selectedSeason = first
            }
        } catch {
            print("Failed to load sibling seasons for season detail: \(error)")
        }

        isLoadingSeasons = false
    }

    /// Load all episodes across all seasons using getAllLeaves (single API call)
    private func loadAllEpisodes() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        let ratingKey: String
        if currentItem.kind == .show {
            ratingKey = currentItem.ref.itemID
        } else if currentItem.kind == .episode {
            guard let showKey = currentItem.grandparentRef?.itemID else { return }
            ratingKey = showKey
        } else {
            return
        }

        isLoadingEpisodes = true

        do {
            let allEps = try await networkManager.getAllLeaves(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            unifiedEpisodes = allEps

            // When opened from a specific episode, scroll the unified list to that episode.
            // Defer one run loop so the ScrollViewReader mounts with the new list before
            // its .onChange(episodeScrollTarget) observer fires.
            if currentItem.kind == .episode {
                let targetKey = currentItem.ref.itemID
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                episodeScrollTarget = targetKey
            }
        } catch {
            print("Failed to load all episodes: \(error)")
        }

        isLoadingEpisodes = false
    }

    /// Load episodes for a season.
    /// - Parameter crossfade: When true, keeps old episodes visible and crossfades to new ones
    ///   instead of showing a loading indicator. Used for season switching.
    private func loadEpisodes(for season: PlexMetadata, crossfade: Bool = false) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = season.ratingKey else { return }

        if !crossfade {
            isLoadingEpisodes = true
        }

        do {
            let fetchedEpisodes = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            if crossfade {
                withAnimation(.easeInOut(duration: 0.35)) {
                    episodes = fetchedEpisodes
                }
            } else {
                episodes = fetchedEpisodes
            }
            // Note: Full metadata is fetched on-demand when user plays an episode
            // to avoid N+1 API calls (Fixes RIVULET-V)
        } catch {
            print("Failed to load episodes: \(error)")
        }

        isLoadingEpisodes = false
    }

    /// Load episodes when viewing a season directly
    private func loadEpisodesForSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        let ratingKey = currentItem.ref.itemID
        guard !ratingKey.isEmpty else { return }

        isLoadingEpisodes = true

        do {
            let fetchedEpisodes = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            episodes = fetchedEpisodes
            // Note: Full metadata is fetched on-demand when user plays an episode
            // to avoid N+1 API calls (Fixes RIVULET-V)
        } catch {
            print("Failed to load episodes for season: \(error)")
        }

        isLoadingEpisodes = false
    }

    /// Refresh a single episode's watch status without reloading the entire list
    /// This preserves focus position in the episode list
    private func refreshEpisodeWatchStatus(ratingKey: String?) async {
        guard let ratingKey = ratingKey,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        do {
            // Fetch fresh metadata for just this episode
            let updatedMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )

            // Update the episode in place
            if let index = episodes.firstIndex(where: { $0.ratingKey == ratingKey }) {
                episodes[index].viewCount = updatedMetadata.viewCount
                episodes[index].viewOffset = updatedMetadata.viewOffset
            }

            // Also update in unified episodes
            if let index = unifiedEpisodes.firstIndex(where: { $0.ratingKey == ratingKey }) {
                unifiedEpisodes[index].viewCount = updatedMetadata.viewCount
                unifiedEpisodes[index].viewOffset = updatedMetadata.viewOffset
            }

            // Also update prefetched metadata
            fullEpisodeMetadata[ratingKey] = updatedMetadata
        } catch {
            print("Failed to refresh episode watch status: \(error)")
        }
    }

    // MARK: - Below-fold Row Helpers (extracted for Swift type-checker)

    @ViewBuilder
    private var recommendedRow: some View {
        if !recommendedItems.isEmpty {
            let sURL = authManager.selectedServerURL ?? ""
            let tok = authManager.selectedServerToken ?? ""
            MediaItemRow(
                title: "Related",
                items: recommendedItems,
                serverURL: sURL,
                authToken: tok,
                onItemSelected: { [self] selectedPlexMeta in
                    guard let prov = providerRegistry.primaryProvider else { return }
                    let mediaItem = PlexMediaMapper.item(
                        selectedPlexMeta, providerID: prov.id,
                        serverURL: sURL, authToken: tok)
                    withAnimation(.easeInOut(duration: 0.35)) {
                        displayedItem = mediaItem
                    }
                }
            )
            .padding(.top, 32)
        }
    }

    @ViewBuilder
    private var collectionRow: some View {
        if !collectionItems.isEmpty, let name = collectionName {
            let sURL = authManager.selectedServerURL ?? ""
            let tok = authManager.selectedServerToken ?? ""
            MediaItemRow(
                title: name,
                items: collectionItems,
                serverURL: sURL,
                authToken: tok,
                onItemSelected: { [self] selectedPlexMeta in
                    guard let prov = providerRegistry.primaryProvider else { return }
                    let mediaItem = PlexMediaMapper.item(
                        selectedPlexMeta, providerID: prov.id,
                        serverURL: sURL, authToken: tok)
                    withAnimation(.easeInOut(duration: 0.35)) {
                        displayedItem = mediaItem
                    }
                }
            )
            .padding(.top, 32)
        }
    }

    @ViewBuilder
    private var castCrewRow: some View {
        if let d = detail, (!d.cast.isEmpty || !d.directors.isEmpty) {
            CastCrewRow(
                cast: d.cast,
                directors: d.directors
            )
            .padding(.top, 32)
        }
    }

    // MARK: - URL Helpers

    /// Poster URL - uses grandparent poster for episodes (series poster)
    private var posterURL: URL? {
        // For TV show episodes/seasons, prefer the series poster (grandparentArtwork)
        if currentItem.kind == .episode || currentItem.kind == .season {
            return currentItem.grandparentArtwork?.poster
                ?? currentItem.parentArtwork?.poster
                ?? currentItem.artwork.poster
        }
        return currentItem.artwork.poster
    }

    private var thumbURL: URL? {
        return currentItem.artwork.thumbnail ?? currentItem.artwork.poster
    }
}

// MARK: - Season Poster Bar (tvOS)


/// Season poster card for the horizontal bar. Click selects, focus only highlights.
struct SeasonBarCard: View {
    let season: PlexMetadata
    let isSelected: Bool
    let serverURL: String
    let authToken: String
    let onSelect: () -> Void

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }
    private var titleSize: CGFloat { ScaledDimensions.posterTitleSize * scale }
    private var subtitleSize: CGFloat { ScaledDimensions.posterSubtitleSize * scale }

    @FocusState private var isFocused: Bool

    private var isFullyWatched: Bool {
        guard let leafCount = season.leafCount,
              let viewedLeafCount = season.viewedLeafCount,
              leafCount > 0 else { return false }
        return viewedLeafCount >= leafCount
    }

    private var seasonLabel: String {
        if let index = season.index {
            if index == 0 { return "Specials" }
            return "Season \(index)"
        }
        return season.title ?? "Season"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 10) {
                // Season poster
                posterImage
                    .frame(width: posterWidth, height: posterHeight)
                    .overlay(alignment: .topTrailing) {
                        if isFullyWatched {
                            WatchedCornerTag()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(isSelected ? .white : .clear, lineWidth: 3)
                    )

                // Season label
                Text(seasonLabel)
                    .font(.system(size: titleSize, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isSelected || isFocused ? 1.0 : 0.6))
                    .lineLimit(1)
            }
        }
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
        .hoverEffect(.highlight)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    private var posterImage: some View {
        CachedAsyncImage(url: posterURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty:
                Rectangle()
                    .fill(Color(white: 0.15))
                    .overlay { ProgressView().tint(.white.opacity(0.3)) }
            case .failure:
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.18), Color(white: 0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Image(systemName: "number.square")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
    }

    private var posterURL: URL? {
        guard let thumb = season.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}

/// Horizontal scrollable row of season poster cards. Click-to-select only.
struct SeasonPosterBar: View {
    let seasons: [PlexMetadata]
    @Binding var selectedSeason: PlexMetadata?
    let serverURL: String
    let authToken: String
    let onSeasonSelected: (PlexMetadata) -> Void

    @FocusState private var focusedSeasonId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(seasons, id: \.ratingKey) { season in
                        SeasonBarCard(
                            season: season,
                            isSelected: selectedSeason?.ratingKey == season.ratingKey,
                            serverURL: serverURL,
                            authToken: authToken,
                            onSelect: {
                                selectedSeason = season
                                onSeasonSelected(season)
                            }
                        )
                        .focused($focusedSeasonId, equals: season.ratingKey)
                        .id(season.ratingKey)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
            .scrollClipDisabled()
            .focusSection()
            .remembersFocus(key: "seasonPosters", focusedId: $focusedSeasonId)
            .onChange(of: selectedSeason?.ratingKey) { _, newKey in
                guard let key = newKey else { return }
                withAnimation {
                    proxy.scrollTo(key, anchor: .center)
                }
            }
        }
    }
}


// MARK: - Season Poster Card

struct SeasonPosterCard: View {
    let season: PlexMetadata
    let isSelected: Bool
    let serverURL: String
    let authToken: String
    var focusedSeasonId: FocusState<String?>.Binding?
    let onSelect: () -> Void

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }
    private var titleSize: CGFloat { ScaledDimensions.posterTitleSize * scale }
    private var subtitleSize: CGFloat { ScaledDimensions.posterSubtitleSize * scale }

    /// Season is fully watched when all episodes have been viewed
    private var isFullyWatched: Bool {
        guard let leafCount = season.leafCount,
              let viewedLeafCount = season.viewedLeafCount,
              leafCount > 0 else { return false }
        return viewedLeafCount >= leafCount
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .center, spacing: 12) {
                // Season poster - structure matches MediaPosterCard
                posterImage
                    .frame(width: posterWidth, height: posterHeight)
                    .overlay(alignment: .topTrailing) {
                        // Watched indicator (corner triangle tag) - inside clipShape so it curves
                        if isFullyWatched {
                            WatchedCornerTag()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 4)
                    )
                    .hoverEffect(.highlight)  // Native tvOS focus effect - scales poster AND badge
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
                    .padding(.bottom, 10)  // Space for hover scale effect

                // Season label
                VStack(spacing: 4) {
                    Text(seasonLabel)
                        .font(.system(size: titleSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))

                    if let leafCount = season.leafCount {
                        Text("\(leafCount) episodes")
                            .font(.system(size: subtitleSize))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .modifier(SeasonFocusModifier(focusedSeasonId: focusedSeasonId, seasonRatingKey: season.ratingKey))
    }

    private var seasonLabel: String {
        // Format as "Season 01", "Season 02", etc.
        if let index = season.index {
            return String(format: "Season %02d", index)
        }
        return season.title ?? "Season"
    }

    private var posterImage: some View {
        CachedAsyncImage(url: posterURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty:
                Rectangle()
                    .fill(Color(white: 0.15))
                    .overlay { ProgressView().tint(.white.opacity(0.3)) }
            case .failure:
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.18), Color(white: 0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Image(systemName: "number.square")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
    }

    private var posterURL: URL? {
        guard let thumb = season.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}

// MARK: - Scroll Offset Tracking

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Season Pill Bar

/// Horizontal row of capsule/pill buttons for season selection (Apple TV+ style)
struct SeasonPillBar: View {
    let seasons: [PlexMetadata]
    @Binding var selectedSeason: PlexMetadata?
    let onSeasonSelected: (PlexMetadata) -> Void

    @FocusState private var focusedSeasonId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(seasons, id: \.ratingKey) { season in
                        let isSelected = selectedSeason?.ratingKey == season.ratingKey
                        SeasonPillButton(
                            label: seasonLabel(for: season),
                            isSelected: isSelected,
                            action: {
                                selectedSeason = season
                                onSeasonSelected(season)
                            }
                        )
                        .focused($focusedSeasonId, equals: season.ratingKey)
                        .id(season.ratingKey)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
            .focusSection()
            .onAppear {
                // Initial scroll to selected season (handles "open show from specific episode")
                guard let key = selectedSeason?.ratingKey else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(key, anchor: .center)
                }
            }
            .onChange(of: selectedSeason?.ratingKey) { _, newKey in
                guard let newKey else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newKey, anchor: .center)
                }
            }
        }
    }

    private func seasonLabel(for season: PlexMetadata) -> String {
        if let index = season.index {
            if index == 0 { return "Specials" }
            return "Season \(index)"
        }
        return season.title ?? "Season"
    }
}

/// Individual season pill button
struct SeasonPillButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 24, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isFocused ? .black : .white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isFocused ? .white : (isSelected ? .white.opacity(0.2) : .clear))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected && !isFocused ? .white.opacity(0.4) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .hoverEffectDisabled()
        .focusEffectDisabled()
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}

// MARK: - Episode Card (Horizontal)

/// Apple TV+ style episode card for horizontal scrolling rows
struct EpisodeCard: View {
    let episode: PlexMetadata
    let serverURL: String
    let authToken: String
    var focusedEpisodeId: FocusState<String?>.Binding?
    var showSeasonPrefix: Bool = false
    let onPlay: () -> Void
    var onRefreshNeeded: MediaItemRefreshCallback? = nil
    var onShowInfo: MediaItemNavigationCallback? = nil

    @FocusState private var isFocused: Bool

    private let cardWidth: CGFloat = 340
    private let thumbHeight: CGFloat = 192

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail
                CachedAsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty:
                        Rectangle()
                            .fill(Color(white: 0.15))
                            .overlay { ProgressView().tint(.white.opacity(0.3)) }
                    case .failure:
                        Rectangle()
                            .fill(Color(white: 0.15))
                            .overlay {
                                Image(systemName: "play.rectangle")
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                    }
                }
                .frame(width: cardWidth, height: thumbHeight)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    // Duration pill
                    if let duration = episode.durationFormatted {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text(duration)
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    // Progress bar
                    if let progress = episode.watchProgress, progress > 0 && progress < 1 {
                        GeometryReader { geo in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.black.opacity(0.5)).frame(height: 3)
                                    Rectangle().fill(.blue).frame(width: geo.size.width * progress, height: 3)
                                }
                            }
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Watched indicator — same corner tag used on poster cards.
                    // In-progress episodes show the bottom bar instead (isWatched excludes that).
                    if episode.isWatched {
                        WatchedCornerTag()
                            .accessibilityLabel("Watched")
                    }
                }

                // Metadata below thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    // Episode label
                    Text(episodeLabel)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isFocused ? .black.opacity(0.6) : .white.opacity(0.6))
                        .textCase(.uppercase)
                        .padding(.top, 10)

                    // Title
                    Text(episode.title ?? "Episode")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(isFocused ? .black : .white)
                        .lineLimit(1)

                    // Summary
                    if let summary = episode.summary {
                        Text(summary)
                            .font(.system(size: 16))
                            .foregroundStyle(isFocused ? .black.opacity(0.7) : .white.opacity(0.7))
                            .lineLimit(3)
                            .padding(.top, 1)
                    }

                    // Date + Content Rating
                    HStack(spacing: 6) {
                        if let date = episode.originallyAvailableAt {
                            Text(formattedDate(date))
                                .font(.system(size: 14))
                                .foregroundStyle(isFocused ? .black.opacity(0.5) : .white.opacity(0.5))
                        }
                        if let rating = episode.contentRating {
                            Text(rating)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isFocused ? .black.opacity(0.5) : .white.opacity(0.5))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(isFocused ? .black.opacity(0.3) : .white.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .frame(width: cardWidth)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .modifier(EpisodeFocusModifier(focusedEpisodeId: focusedEpisodeId, episodeRatingKey: episode.ratingKey))
        .hoverEffect(.highlight)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isFocused)
        .mediaItemContextMenu(
            item: episode,
            serverURL: serverURL,
            authToken: authToken,
            source: .other,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo
        )
    }

    private var episodeLabel: String {
        if showSeasonPrefix, let epString = episode.episodeString {
            return epString
        }
        if let index = episode.index {
            return "Episode \(index)"
        }
        return episode.episodeString ?? "Episode"
    }

    private var thumbURL: URL? {
        guard let thumb = episode.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }

    private func formattedDate(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return dateString }
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let episode: PlexMetadata
    let serverURL: String
    let authToken: String
    var isCurrent: Bool = false  // Indicates this is the episode currently being viewed
    var focusedEpisodeId: FocusState<String?>.Binding?
    let onPlay: () -> Void
    var onPlayFromBeginning: (() -> Void)? = nil
    var onRefreshNeeded: MediaItemRefreshCallback? = nil
    var onShowInfo: MediaItemNavigationCallback? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 16) {
                // Thumbnail
                CachedAsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty, .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay {
                                Image(systemName: "play.rectangle")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottom) {
                    // Progress bar
                    if let progress = episode.watchProgress, progress > 0 && progress < 1 {
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.black.opacity(0.5))
                            Color.blue
                                .scaleEffect(x: progress, anchor: .leading)
                        }
                        .frame(height: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    if let epString = episode.episodeString {
                        Text(epString)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }

                    Text(episode.title ?? "Episode")
                        .font(.system(size: 30, weight: .medium))
                        .lineLimit(1)

                    if let duration = episode.durationFormatted {
                        Text(duration)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }

                    if let summary = episode.summary {
                        Text(summary)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Current episode indicator (when viewing episode detail)
                if isCurrent {
                    Text("VIEWING")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.blue)
                        )
                }

                // Watched indicator
                if episode.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 24))
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 22)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
        .modifier(EpisodeFocusModifier(focusedEpisodeId: focusedEpisodeId, episodeRatingKey: episode.ratingKey))
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .mediaItemContextMenu(
            item: episode,
            serverURL: serverURL,
            authToken: authToken,
            source: .other,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo
        )
    }

    private var thumbURL: URL? {
        guard let thumb = episode.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}

/// Helper modifier to apply focus binding to episode rows
struct EpisodeFocusModifier: ViewModifier {
    var focusedEpisodeId: FocusState<String?>.Binding?
    let episodeRatingKey: String?

    func body(content: Content) -> some View {
        if let binding = focusedEpisodeId, let key = episodeRatingKey {
            content.focused(binding, equals: key)
        } else {
            content
        }
    }
}

// MARK: - Skeleton Episode Row

/// Loading placeholder for episode rows - shows while fetching episode data
struct SkeletonEpisodeRow: View {
    let episodeNumber: Int

    var body: some View {
        HStack(spacing: 16) {
            // Placeholder thumbnail
            Rectangle()
                .fill(Color(white: 0.15))
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    ProgressView()
                        .tint(.white.opacity(0.3))
                }

            VStack(alignment: .leading, spacing: 5) {
                // Episode number placeholder
                Text("Episode \(episodeNumber)")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.3))

                // Title placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 220, height: 26)

                // Duration placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 90, height: 22)
            }

            Spacer()
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

/// Helper modifier to apply focus binding to season cards
struct SeasonFocusModifier: ViewModifier {
    var focusedSeasonId: FocusState<String?>.Binding?
    let seasonRatingKey: String?

    func body(content: Content) -> some View {
        if let binding = focusedSeasonId, let key = seasonRatingKey {
            content.focused(binding, equals: key)
        } else {
            content
        }
    }
}



// MARK: - Player View Wrapper (non-tvOS)


#Preview {
    let sampleRef = MediaItemRef(providerID: "plex:preview", itemID: "123")
    let sampleMovie = MediaItem(
        ref: sampleRef,
        kind: .movie,
        title: "Sample Movie",
        sortTitle: nil,
        overview: "This is a sample movie summary that describes the plot and gives viewers an idea of what to expect.",
        year: 2024,
        runtime: 7200,
        parentRef: nil,
        grandparentRef: nil,
        episodeNumber: nil,
        seasonNumber: nil,
        childProgress: nil,
        userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
        artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
        parentArtwork: nil,
        grandparentArtwork: nil
    )

    MediaDetailView(item: sampleMovie)
}

// MARK: - Navigation Destinations Modifier

/// Conditionally applies .navigationDestination modifiers.
/// Disabled in preview overlay flow (no NavigationStack ancestor).
private struct NavigationDestinationsModifier: ViewModifier {
    @Binding var navigateToSeason: MediaItem?
    @Binding var navigateToShow: MediaItem?
    @Binding var navigateToEpisode: MediaItem?
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .navigationDestination(item: $navigateToSeason) { season in
                    MediaDetailView(item: season)
                }
                .navigationDestination(item: $navigateToShow) { show in
                    MediaDetailView(item: show)
                }
                .navigationDestination(item: $navigateToEpisode) { episode in
                    MediaDetailView(item: episode)
                }
        } else {
            content
        }
    }
}
