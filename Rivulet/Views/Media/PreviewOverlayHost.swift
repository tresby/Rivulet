//
//  PreviewOverlayHost.swift
//  Rivulet
//
//  In-tree Apple TV-style preview overlay for hub rows.
//

import SwiftUI
import Combine
import os.log

private let previewHostLog = Logger(subsystem: "com.rivulet.app", category: "PreviewHost")

let previewEntryAnimation = Animation.spring(response: 0.45, dampingFraction: 0.88)
let previewPagingDuration: Double = 0.78
let previewPagingAnimation = Animation.timingCurve(0.40, 0.02, 0.18, 1.0, duration: previewPagingDuration)
let previewExpandAnimation = Animation.easeInOut(duration: 0.35)

/// Bridge object that allows PreviewContainerViewController to trigger Menu actions
/// on the SwiftUI PreviewOverlayHost.
@MainActor
class PreviewMenuBridge: ObservableObject {
    @Published var menuPressCount: Int = 0

    /// Optional intercept handler set by the expanded detail view.
    /// Returns true if the press was consumed (e.g., popping internal navigation).
    var interceptHandler: (() -> Bool)?

    func triggerMenu() {
        if let handler = interceptHandler, handler() {
            return  // Consumed by detail view's internal nav
        }
        menuPressCount += 1
    }
}

private struct PreviewMenuBridgeKey: EnvironmentKey {
    static let defaultValue: PreviewMenuBridge? = nil
}

extension EnvironmentValues {
    var previewMenuBridge: PreviewMenuBridge? {
        get { self[PreviewMenuBridgeKey.self] }
        set { self[PreviewMenuBridgeKey.self] = newValue }
    }
}

struct PreviewOverlayHost: View {
    let request: PreviewRequest
    let sourceFrames: [PreviewSourceTarget: CGRect]
    let onDismiss: (PreviewSourceTarget) -> Void
    /// Called when a hosted `MediaDetailView` wants to navigate to a
    /// sub-item (e.g. the user clicked an episode's description tile to
    /// open the episode detail page). Required because the preview is
    /// presented via UIKit modal, so the SwiftUI view tree inside has no
    /// `NavigationStack` ancestor — `.navigationDestination` is a no-op.
    /// The host (typically `PlexHomeView`) handles the dismissal of this
    /// modal and pushes the destination onto its own `NavigationStack`.
    var onSubItemNavigation: ((MediaItem) -> Void)? = nil
    @ObservedObject var menuBridge: PreviewMenuBridge

    /// Carousel-local copy of the request's items. Mutable so the prefetch
    /// loop can enrich TMDB stubs with real backdrop/overview/etc. as their
    /// detail payload resolves. Seeded in init from `request.items` so the
    /// very first body render (which happens BEFORE onAppear fires) sees
    /// the populated array — otherwise `items[selectedIndex]` in the
    /// entry-morph ForEach would index an empty array and trap.
    @State private var items: [MediaItem]

    @State private var selectedIndex: Int
    @State private var stateMachine = PreviewStateMachine()
    @State private var vignetteVisible = false
    @State private var metadataVisible = false
    @State private var expandedChromeVisible = false
    @State private var verticalScrollEnabled = false
    @State private var capturedSourceFrame: CGRect?
    @State private var pagingMotionActive = false
    @State private var pagingFromIndex: Int?
    @State private var pagingProgress: CGFloat = 0
    @State private var metadataGate = PreviewLoadGate()
    /// Flipped to `true` once the entry/paging animation cascade has fully
    /// settled. `PreviewCarouselCard` forwards it into `MediaDetailView` so
    /// the detail data cascade only runs after the spring + staged fades
    /// have finished — keeping the main thread quiet during animation.
    @State private var previewAnimationSettled = false
    @FocusState private var focusedArea: PreviewFocusArea?

    private let topInset: CGFloat = 52
    private let cornerRadius: CGFloat = 28
    private let centeredHorizontalInset: CGFloat = 88
    private let sideCardGap: CGFloat = 14
    private let carouselParallaxFactor: CGFloat = 0.70

    init(
        request: PreviewRequest,
        sourceFrames: [PreviewSourceTarget: CGRect],
        onDismiss: @escaping (PreviewSourceTarget) -> Void,
        onSubItemNavigation: ((MediaItem) -> Void)? = nil,
        menuBridge: PreviewMenuBridge
    ) {
        self.request = request
        self.sourceFrames = sourceFrames
        self.onDismiss = onDismiss
        self.onSubItemNavigation = onSubItemNavigation
        self.menuBridge = menuBridge
        self._selectedIndex = State(initialValue: request.selectedIndex)
        self._items = State(initialValue: request.items)
    }

    private var visibleIndices: [Int] {
        switch stateMachine.phase {
        case .entryMorph:
            return [selectedIndex].filter { items.indices.contains($0) }
        case .carouselStable, .expandingHero, .expandedHero, .detailsStable, .exiting:
            return [selectedIndex - 1, selectedIndex, selectedIndex + 1]
                .filter { items.indices.contains($0) }
        }
    }

    var body: some View {
        GeometryReader { geo in
            // Card extends from topInset to below the screen bottom (overflows by cornerRadius to hide bottom corners)
            let cardWidth = max(0, geo.size.width - (centeredHorizontalInset * 2))
            let cardHeight = geo.size.height - topInset + cornerRadius
            let centeredFrame = CGRect(
                x: (geo.size.width - cardWidth) / 2,
                y: topInset,
                width: cardWidth,
                height: cardHeight
            )
            let fullFrame = CGRect(origin: .zero, size: geo.size)
            let entryFrame = sanitizedSourceFrame(
                capturedSourceFrame ?? sourceFrames[request.sourceTarget],
                fallback: centeredFrame,
                in: geo.size
            )

            ZStack {
                Color.black.ignoresSafeArea()

                ForEach(visibleIndices, id: \.self) { index in
                    let cardFrame = frame(
                        for: index,
                        centeredFrame: centeredFrame,
                        fullFrame: fullFrame,
                        entryFrame: entryFrame
                    )
                    PreviewCarouselCard(
                        item: items[index],
                        frame: cardFrame,
                        stageSize: geo.size,
                        stageWindowFrame: cardFrame,
                        phase: stateMachine.phase,
                        isCurrent: index == selectedIndex,
                        vignetteVisible: index == selectedIndex && vignetteVisible && !pagingMotionActive,
                        metadataVisible: index == selectedIndex && metadataVisible && !pagingMotionActive,
                        showExpandedChrome: expandedChromeVisible,
                        allowVerticalScroll: verticalScrollEnabled,
                        allowActionRowInteraction: expandedChromeVisible,
                        motionLocked: stateMachine.motionLocked,
                        backgroundParallaxOffset: parallaxOffset(for: index, centeredFrame: centeredFrame),
                        previewAnimationSettled: previewAnimationSettled,
                        onPreviewExitRequested: handleExpandedExit,
                        onDetailsBecameVisible: {
                            if index == selectedIndex {
                                stateMachine.markDetailsStable()
                            }
                        },
                        onSubItemNavigation: onSubItemNavigation,
                        cornerRadius: cardCornerRadius(for: index),
                        opacity: cardOpacity(for: index)
                    )
                    .zIndex(cardZIndex(for: index))
                }

                if stateMachine.isCarouselInputEnabled {
                    Color.clear
                        .focusable(true)
                        .focused($focusedArea, equals: .carousel)
                        .focusSection()
                        .contentShape(Rectangle())
                        .onMoveCommand(perform: performCarouselMove)
                        .onTapGesture {
                            expandCurrentCard()
                        }
                        .onKeyPress(.return) {
                            expandCurrentCard()
                            return .handled
                        }
                        .onPlayPauseCommand {
                            expandCurrentCard()
                        }
                }
            }
            .ignoresSafeArea()
            .onAppear {
                capturedSourceFrame = sourceFrames[request.sourceTarget]
                focusedArea = .carousel
                // `items` is seeded in init so the first body render sees
                // a populated array. Don't re-seed here — re-entry into
                // onAppear (e.g. parent re-mount) would clobber any
                // prefetch enrichment that already landed.

                // Kick off a logo-only fetch for the selected card immediately.
                // Full prefetch is gated on `previewAnimationSettled` to avoid
                // contending with the entry spring, but logos are a tiny side-
                // channel call and missing them on first render causes a visible
                // title → logo swap once the user navigates and returns.
                prefetchLogoForSelectedItem()

                // Skip the initial prefetch until the entry animation completes —
                // the `onChange(of: previewAnimationSettled)` below picks it up
                // once the flag flips true. Paging prefetches (in `onChange(of:
                // selectedIndex)`) still fire immediately because they're
                // backgrounded and wouldn't contend with the spring.
                startEntryAnimation()
            }
            .onChange(of: previewAnimationSettled) { _, settled in
                if settled {
                    prefetchAssets(around: selectedIndex)
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                prefetchAssets(around: newIndex)
            }
            .onChange(of: sourceFrames[request.sourceTarget]) { _, newFrame in
                if capturedSourceFrame == nil {
                    capturedSourceFrame = newFrame
                }
            }
            .onChange(of: menuBridge.menuPressCount) { _, _ in
                handleExit()
            }
        }
        .environment(\.previewMenuBridge, menuBridge)
        .ignoresSafeArea()
    }

    private func performCarouselMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            page(by: -1)
        case .right:
            page(by: 1)
        case .down:
            expandCurrentCard()
        default:
            break
        }
    }

    private func startEntryAnimation() {
        vignetteVisible = false
        metadataVisible = false
        expandedChromeVisible = false
        verticalScrollEnabled = false
        pagingMotionActive = false
        pagingFromIndex = nil
        pagingProgress = 0
        // Reset the settle flag so the detail cascade is suspended for the
        // duration of the entry animation.
        previewAnimationSettled = false
        let token = metadataGate.begin()

        Task { @MainActor in
            await Task.yield()
            withAnimation(previewEntryAnimation) {
                stateMachine.completeEntryMorph()
            }

            // Phase 1: Vignette fades in after card settles
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard metadataGate.isCurrent(token) else { return }
            stateMachine.setMotionLocked(false)
            withAnimation(.easeOut(duration: 0.6)) {
                vignetteVisible = true
            }

            // Phase 2: Text fades in after vignette established
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(.easeOut(duration: 0.34)) {
                metadataVisible = true
            }

            // Phase 3: Text fade finishes — unblock MediaDetailView's data
            // cascade. The 0.34s duration matches the withAnimation above;
            // waiting for the fade to visually complete means any view
            // invalidations the cascade causes land after the user perceives
            // the animation as "done".
            try? await Task.sleep(nanoseconds: 340_000_000)
            guard metadataGate.isCurrent(token) else { return }
            previewAnimationSettled = true
        }
    }

    private func page(by delta: Int) {
        guard stateMachine.isCarouselInputEnabled else { return }
        guard !pagingMotionActive else { return }

        let nextIndex = selectedIndex + delta
        guard items.indices.contains(nextIndex) else { return }

        // Fade text + vignette out quickly before horizontal travel
        metadataVisible = false
        vignetteVisible = false
        expandedChromeVisible = false
        verticalScrollEnabled = false
        pagingMotionActive = true
        pagingFromIndex = selectedIndex
        pagingProgress = 0
        // Resuspend the detail cascade while the card travels. Rapid paging
        // (left-left-left) keeps the flag false until the user stops, so the
        // cascade only fires once — on the card they finally land on.
        previewAnimationSettled = false

        let token = metadataGate.begin()
        stateMachine.beginPaging()

        // Drive both card motion and inner-image parallax from one progress track.
        withAnimation(previewPagingAnimation) {
            selectedIndex = nextIndex
            pagingProgress = 1
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(previewPagingDuration * 1_000_000_000))
            guard metadataGate.isCurrent(token) else { return }
            stateMachine.finishPaging()
            pagingMotionActive = false
            pagingFromIndex = nil
            pagingProgress = 0

            // Brief settle, then staged in-place fade for vignette then text.
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(.easeOut(duration: 0.26)) {
                vignetteVisible = true
            }

            try? await Task.sleep(nanoseconds: 70_000_000)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(.easeOut(duration: 0.48)) {
                metadataVisible = true
            }

            // Wait for the text fade to complete visually, then release the
            // cascade on the new current card.
            try? await Task.sleep(nanoseconds: 480_000_000)
            guard metadataGate.isCurrent(token) else { return }
            previewAnimationSettled = true
        }
    }

    private func expandCurrentCard() {
        guard !stateMachine.isExpanded else { return }

        let itemRef = items.indices.contains(selectedIndex) ? items[selectedIndex].ref.itemID : "?"
        previewHostLog.info("[Expand] BEGIN idx=\(self.selectedIndex) ref=\(itemRef, privacy: .public)")

        pagingMotionActive = false
        pagingFromIndex = nil
        pagingProgress = 0
        expandedChromeVisible = false
        verticalScrollEnabled = false
        let token = metadataGate.begin()

        // Ensure vignette is showing during expansion
        if !vignetteVisible {
            withAnimation(.easeOut(duration: 0.3)) {
                vignetteVisible = true
            }
        }

        withAnimation(previewExpandAnimation) {
            stateMachine.beginExpand()
            focusedArea = nil
        }
        previewHostLog.info("[Expand] beginExpand phase=expandingHero focusedArea=nil")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard metadataGate.isCurrent(token) else { return }
            if !metadataVisible {
                withAnimation(.easeOut(duration: 0.22)) {
                    metadataVisible = true
                }
            }

            // Finish expand BEFORE showing chrome so presentationMode is
            // .expandedDetail when the showExpandedChrome onChange fires
            // (MediaDetailView uses isExpandedPreviewFlow to set focus).
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard metadataGate.isCurrent(token) else { return }
            stateMachine.finishExpand()
            previewHostLog.info("[Expand] finishExpand phase=expandedHero")

            try? await Task.sleep(nanoseconds: 60_000_000)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                expandedChromeVisible = true
            }
            verticalScrollEnabled = true
            previewHostLog.info("[Expand] expandedChromeVisible=true verticalScrollEnabled=true")

            // Release the detail cascade AFTER the chrome is visible and
            // focus has been set on the play button. Firing it earlier
            // caused the cascade's state resets to trigger a view tree
            // rebuild that could race with the focus-set timing.
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard metadataGate.isCurrent(token) else { return }
            previewAnimationSettled = true
            previewHostLog.info("[Expand] previewAnimationSettled=true")
        }
    }

    private func handleExpandedExit() {
        handleExit()
    }

    private func handleExit() {
        var nextState = stateMachine
        let action = nextState.exitAction()

        switch action {
        case .dismissOverlay:
            pagingMotionActive = false
            pagingFromIndex = nil
            pagingProgress = 0
            stateMachine.beginExit()
            onDismiss(request.sourceTarget)

        case .collapseToCarousel:
            let token = metadataGate.begin()
            pagingMotionActive = false
            pagingFromIndex = nil
            pagingProgress = 0
            verticalScrollEnabled = false

            // Phase 1: Fade out expanded chrome (reverse of expand)
            withAnimation(.easeIn(duration: 0.18)) {
                expandedChromeVisible = false
            }

            Task { @MainActor in
                // Phase 2: After chrome fades, animate card back to carousel
                try? await Task.sleep(nanoseconds: 140_000_000)
                guard metadataGate.isCurrent(token) else { return }

                var collapsedState = nextState
                collapsedState.setMotionLocked(true)
                withAnimation(previewExpandAnimation) {
                    stateMachine = collapsedState
                }

                // Phase 3: After card settles, unlock motion and restore focus
                try? await Task.sleep(nanoseconds: 380_000_000)
                guard metadataGate.isCurrent(token) else { return }
                stateMachine.setMotionLocked(false)
                if !vignetteVisible {
                    withAnimation(.easeOut(duration: 0.4)) {
                        vignetteVisible = true
                    }
                }
                withAnimation(.easeOut(duration: 0.25)) {
                    metadataVisible = true
                }
                focusedArea = .carousel
            }
        }
    }

    @MainActor
    private func prefetchAssets(around index: Int) {
        // Snapshot the ref + index pairs we want to prefetch. We rebuild the
        // HeroBackdropRequests from the current `items` array AFTER each
        // enrichment step so we pick up backdrops that just landed.
        //
        // Window: n±2 (five items centered on the current card). Paging one
        // step is already pre-warmed; paging two steps finds its target
        // ready instead of fetching on scroll. Three would add another TMDB
        // round-trip per paging event for marginal perceived benefit.
        let indices = ((index - 2)...(index + 2)).filter { items.indices.contains($0) }
        let snapshotRefs: [(Int, MediaItemRef, MediaKind)] = indices.map { (i: $0, ref: items[$0].ref, kind: items[$0].kind) }
            .map { ($0.i, $0.ref, $0.kind) }

        // Warm the backdrop image cache for whatever URLs we have *right now*
        // (stubs may have nil backdrops — the TMDB-detail fetch below will
        // enrich them and re-trigger resolution).
        let initialRequests = indices.map { items[$0].heroBackdropRequest() }
        Task.detached(priority: .utility) { [initialRequests] in
            for request in initialRequests {
                _ = await HeroBackdropResolver.shared.resolveAssets(for: request)
            }
        }

        guard !snapshotRefs.isEmpty else { return }

        // Provider/metadata warm-up in parallel. For each neighbor we:
        //   1. Hit the right backend (MediaProvider for Plex; MetadataSource
        //      for TMDB) to get its full detail — this warms any internal
        //      cache AND gives us the enriched MediaItem (with real backdrop
        //      for TMDB stubs). We splice that back into `items` on main.
        //   2. For shows: warm the episode-thumbnail image cache.
        Task.detached(priority: .utility) { [snapshotRefs] in
            await withTaskGroup(of: (Int, MediaItem?).self) { group in
                for (i, ref, _) in snapshotRefs {
                    group.addTask {
                        // Prefer MediaProvider (library/music backends); fall
                        // back to MetadataSource (TMDB) for catalog-only items.
                        // For TMDB refs we also kick off a parallel logo-cache
                        // lookup so artwork.logo is populated by the time the
                        // carousel reads it.
                        async let logoURLTask: URL? = Self.fetchTMDBLogo(ref: ref)

                        let detail: MediaItemDetail? = await {
                            if let provider = await MainActor.run(body: {
                                MediaProviderRegistry.shared.provider(for: ref.providerID)
                            }) {
                                return try? await provider.fullDetail(for: ref)
                            }
                            if let source = await MainActor.run(body: {
                                MetadataSourceRegistry.shared.source(for: ref.providerID)
                            }) {
                                return try? await source.itemDetail(ref)
                            }
                            return nil
                        }()

                        let logoURL = await logoURLTask
                        let enriched = detail?.item.withLogoIfMissing(logoURL)
                        return (i, enriched)
                    }
                }
                for await (i, enriched) in group {
                    guard let enriched else { continue }
                    await MainActor.run {
                        // Only replace if the slot still holds the same ref —
                        // protects against races where the carousel scrolled
                        // past this index.
                        if items.indices.contains(i), items[i].ref == enriched.ref {
                            items[i] = enriched
                        }
                    }
                    // Re-request the backdrop resolver with the now-real URL.
                    _ = await HeroBackdropResolver.shared.resolveAssets(for: enriched.heroBackdropRequest())
                }
            }

            // Shows: warm the episode-thumbnail image cache.
            await withTaskGroup(of: Void.self) { group in
                for (_, ref, kind) in snapshotRefs where kind == .show {
                    group.addTask {
                        let provider = await MainActor.run {
                            MediaProviderRegistry.shared.provider(for: ref.providerID)
                        }
                        guard let provider,
                              let episodes = try? await provider.allEpisodes(of: ref) else { return }
                        let thumbURLs = episodes.prefix(8).compactMap { $0.artwork.thumbnail ?? $0.artwork.poster }
                        for url in thumbURLs {
                            _ = await ImageCacheManager.shared.image(for: url)
                        }
                    }
                }
            }
        }
    }

    /// Resolves the TMDB clear-logo URL for a ref, or nil for non-TMDB refs.
    /// Called from the prefetch group so logo resolution runs in parallel with
    /// the detail fetch instead of serializing behind it.
    private static func fetchTMDBLogo(ref: MediaItemRef) async -> URL? {
        guard ref.providerID == TMDBMediaMapper.providerID,
              let (tmdbId, type) = TMDBMediaMapper.decodeItemID(ref.itemID) else { return nil }
        return await TMDBLogoCache.shared.logoURL(tmdbId: tmdbId, type: type)
    }

    /// Fetches the TMDB logo for the currently selected card and splices it in
    /// as soon as it arrives, even if the full prefetch ring hasn't started
    /// yet. Lets us show the logo on the first render of the carousel without
    /// waiting for the entry animation to settle.
    private func prefetchLogoForSelectedItem() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        guard item.artwork.logo == nil else { return }
        let ref = item.ref
        let targetIndex = selectedIndex
        Task.detached(priority: .userInitiated) {
            guard let logoURL = await Self.fetchTMDBLogo(ref: ref) else { return }
            await MainActor.run {
                guard items.indices.contains(targetIndex),
                      items[targetIndex].ref == ref else { return }
                items[targetIndex] = items[targetIndex].withLogoIfMissing(logoURL)
            }
        }
    }

    private func frame(
        for index: Int,
        centeredFrame: CGRect,
        fullFrame: CGRect,
        entryFrame: CGRect
    ) -> CGRect {
        if index == selectedIndex {
            switch stateMachine.phase {
            case .entryMorph:
                return entryFrame
            case .carouselStable, .exiting:
                return carouselFrame(for: index, centeredFrame: centeredFrame)
            case .expandingHero, .expandedHero, .detailsStable:
                // Card expands to full screen — the mask reveals the backdrop
                return fullFrame
            }
        }

        if stateMachine.phase == .carouselStable {
            return carouselFrame(for: index, centeredFrame: centeredFrame)
        }

        let offset = CGFloat(index - selectedIndex)
        let x = centeredFrame.minX + offset * (centeredFrame.width + sideCardGap)

        return CGRect(
            x: x,
            y: centeredFrame.minY,
            width: centeredFrame.width,
            height: centeredFrame.height
        )
    }

    private func carouselFrame(for index: Int, centeredFrame: CGRect) -> CGRect {
        let slot = carouselSlotPosition(for: index)
        let x = centeredFrame.minX + slot * (centeredFrame.width + sideCardGap)

        return CGRect(
            x: x,
            y: centeredFrame.minY,
            width: centeredFrame.width,
            height: centeredFrame.height
        )
    }

    private func carouselSlotPosition(for index: Int) -> CGFloat {
        let fromIndex = pagingFromIndex ?? selectedIndex
        let toIndex = selectedIndex
        let startPos = CGFloat(index - fromIndex)
        let endPos = CGFloat(index - toIndex)
        if stateMachine.phase == .carouselStable, pagingMotionActive {
            return startPos + ((endPos - startPos) * pagingProgress)
        }
        return endPos
    }

    private func parallaxOffset(for index: Int, centeredFrame: CGRect) -> CGFloat {
        guard stateMachine.phase == .carouselStable else { return 0 }
        // Keep parallax tied to the same slot position as the card's x-translation.
        // Side cards are pre-offset while idle, so there is no jump on paging start.
        let slot = carouselSlotPosition(for: index)
        let deltaFromCenter = slot * (centeredFrame.width + sideCardGap)
        return -deltaFromCenter * carouselParallaxFactor
    }

    private func sanitizedSourceFrame(_ frame: CGRect?, fallback: CGRect, in containerSize: CGSize) -> CGRect {
        guard let frame, frame.width > 0, frame.height > 0 else {
            return fallback
        }

        let clippedX = min(max(frame.minX, 0), max(0, containerSize.width - frame.width))
        let clippedY = min(max(frame.minY, 0), max(0, containerSize.height - frame.height))
        return CGRect(x: clippedX, y: clippedY, width: frame.width, height: frame.height)
    }

    private func cardCornerRadius(for index: Int) -> CGFloat {
        if index == selectedIndex {
            switch stateMachine.phase {
            case .expandingHero, .expandedHero, .detailsStable:
                return 0
            default:
                break
            }
        }
        return cornerRadius
    }

    private func cardOpacity(for index: Int) -> Double {
        if index == selectedIndex {
            return 1  // Selected card always visible — mask reveals/hides
        }

        switch stateMachine.phase {
        case .carouselStable:
            return 1
        case .entryMorph, .expandingHero, .expandedHero, .detailsStable, .exiting:
            return 0
        }
    }

    private func cardZIndex(for index: Int) -> Double {
        switch stateMachine.phase {
        case .entryMorph:
            return 1
        case .carouselStable:
            // Keep the card nearest the visual center on top so side-card overscan
            // never draws above the center card in one paging direction.
            // This preserves a flat carousel plane while fixing directional asymmetry.
            let slotDistance = abs(carouselSlotPosition(for: index))
            return 100 - (slotDistance * 10)
        case .expandingHero, .expandedHero, .detailsStable, .exiting:
            return index == selectedIndex ? 2 : 1
        }
    }

}

private struct PreviewCarouselCard: View {
    let item: MediaItem
    let frame: CGRect
    let stageSize: CGSize
    let stageWindowFrame: CGRect
    let phase: PreviewPhase
    let isCurrent: Bool
    let vignetteVisible: Bool
    let metadataVisible: Bool
    let showExpandedChrome: Bool
    let allowVerticalScroll: Bool
    let allowActionRowInteraction: Bool
    let motionLocked: Bool
    let backgroundParallaxOffset: CGFloat
    let previewAnimationSettled: Bool
    let onPreviewExitRequested: () -> Void
    let onDetailsBecameVisible: () -> Void
    let onSubItemNavigation: ((MediaItem) -> Void)?
    let cornerRadius: CGFloat
    let opacity: Double

    private var showsCarouselOverlay: Bool {
        phase == .carouselStable && isCurrent
    }

    private var isCardExpanded: Bool {
        isCurrent && (phase == .expandedHero || phase == .detailsStable)
    }

    private var usesExpandedSurface: Bool {
        isCurrent && (phase == .expandingHero || phase == .expandedHero || phase == .detailsStable)
    }

    var body: some View {
        ZStack {
            // Current card uses a single persistent surface across carousel→expanded
            // so the backdrop and metadata keep their view identity (no redraw).
            // Non-current cards in carousel share the same rendering path so
            // incoming artwork slides in with the card during paging.
            if isCurrent || phase == .carouselStable {
                PreviewHeroSurface(
                    item: item,
                    isExpanded: isCurrent ? isCardExpanded : false,
                    vignetteVisible: isCurrent ? vignetteVisible : false,
                    metadataVisible: isCurrent ? metadataVisible : false,
                    showExpandedChrome: isCurrent ? showExpandedChrome : false,
                    showBackdropLayer: true,
                    allowVerticalScroll: isCurrent ? allowVerticalScroll : false,
                    allowActionRowInteraction: isCurrent ? allowActionRowInteraction : false,
                    heroBackdropMotionLocked: motionLocked,
                    backgroundParallaxOffset: backgroundParallaxOffset,
                    backdropStageSize: stageSize,
                    backdropWindowFrame: stageWindowFrame,
                    onPreviewExitRequested: onPreviewExitRequested,
                    onDetailsBecameVisible: onDetailsBecameVisible,
                    onSubItemNavigation: onSubItemNavigation,
                    enableDetailDataLoading: isCurrent,
                    previewAnimationSettled: previewAnimationSettled
                )
                .allowsHitTesting(usesExpandedSurface && isCardExpanded)

                if showsCarouselOverlay {
                    PreviewCarouselStageWindow(cornerRadius: cornerRadius)
                }
            } else {
                PreviewCarouselSideCard(
                    item: item,
                    motionLocked: motionLocked
                )
            }
        }
        .frame(width: frame.width, height: frame.height)
        .mask(
            UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: cornerRadius,
                style: .continuous
            )
        )
        .opacity(opacity)
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(usesExpandedSurface && isCardExpanded)
    }
}

private struct PreviewCarouselStageWindow: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            Color.clear
            UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: cornerRadius,
                style: .continuous
            )
            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct PreviewHeroSurface: View {
    let item: MediaItem
    let isExpanded: Bool
    let vignetteVisible: Bool
    let metadataVisible: Bool
    let showExpandedChrome: Bool
    let showBackdropLayer: Bool
    let allowVerticalScroll: Bool
    let allowActionRowInteraction: Bool
    let heroBackdropMotionLocked: Bool
    let backgroundParallaxOffset: CGFloat
    let backdropStageSize: CGSize
    let backdropWindowFrame: CGRect
    let onPreviewExitRequested: () -> Void
    let onDetailsBecameVisible: () -> Void
    let onSubItemNavigation: ((MediaItem) -> Void)?
    let enableDetailDataLoading: Bool
    let previewAnimationSettled: Bool

    var body: some View {
        MediaDetailView(
            item: item,
            presentationMode: isExpanded ? .expandedDetail : .previewCarousel,
            backgroundParallaxOffset: backgroundParallaxOffset,
            showVignette: vignetteVisible,
            showMetadata: metadataVisible,
            showExpandedChrome: showExpandedChrome,
            showsBackdropLayer: showBackdropLayer,
            allowVerticalScroll: allowVerticalScroll,
            allowActionRowInteraction: allowActionRowInteraction,
            heroBackdropMotionLocked: heroBackdropMotionLocked,
            backdropStageSize: backdropStageSize,
            backdropWindowFrame: backdropWindowFrame,
            onPreviewExitRequested: onPreviewExitRequested,
            onDetailsBecameVisible: onDetailsBecameVisible,
            onSubItemNavigation: onSubItemNavigation,
            enableDetailDataLoading: enableDetailDataLoading,
            previewAnimationSettled: previewAnimationSettled
        )
    }
}

/// Lightweight placeholder card shown only during `.entryMorph` phase (see
/// `PreviewCarouselCard.body`). Once `carouselStable` is reached, all three
/// visible cards route through `MediaDetailView`/`HeroBackdropCoordinator`.
///
/// This was previously backed by a per-card `HeroBackdropCoordinator`; the
/// coordinator adds nothing here because the only thing the side card shows
/// is the downsampled backdrop for ~600ms before the real hero surface takes
/// over. Binding `HeroBackdropImage` directly to the resolved URL removes a
/// `@Published` publisher and a `.task(id:)` from the entry window.
private struct PreviewCarouselSideCard: View {
    let item: MediaItem
    let motionLocked: Bool

    private var request: HeroBackdropRequest {
        item.heroBackdropRequest()
    }

    var body: some View {
        HeroBackdropImage(url: request.backdropURL ?? request.thumbnailURL) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        // Scale so image is already ~full-screen sized even inside the narrower card.
        // When the card expands during hero transition, the image doesn't resize —
        // the mask just reveals more of the already-positioned image.
        .scaleEffect(1.14)
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 28,
                style: .continuous
            )
            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }
}
