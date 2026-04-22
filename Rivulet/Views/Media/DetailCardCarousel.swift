//
//  DetailCardCarousel.swift
//  Rivulet
//
//  Full-screen carousel of MediaDetailView cards (Apple TV+ style preview)
//

import SwiftUI
import os.log

private let carouselLog = Logger(subsystem: "com.rivulet.app", category: "DetailCardCarousel")

private let pageAnimation: Animation = .easeInOut(duration: 0.4)
private let expandAnimation: Animation = .easeInOut(duration: 0.35)

/// Only applies the rounded mask when active (carousel mode), removes it when expanded to avoid blocking focus
private struct TopRoundedMask: ViewModifier {
    let cornerRadius: CGFloat
    let height: CGFloat
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive && cornerRadius > 0 {
            content.mask(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .frame(height: height + cornerRadius)
                    .frame(height: height, alignment: .top)
            )
        } else {
            content
        }
    }
}

struct DetailCardCarousel: View {
    let items: [PlexMetadata]
    let initialIndex: Int
    let namespace: Namespace.ID
    let serverURL: String
    let authToken: String
    let onDismiss: () -> Void

    @State private var currentIndex: Int
    @State private var isExpanded: Bool = false
    @State private var metadataVisible: Bool = false
    @FocusState private var isCarouselFocused: Bool

    private let cardWidth: CGFloat = 1600
    private let cardSpacing: CGFloat = 20
    private let topInset: CGFloat = 50
    private let cornerRadius: CGFloat = 70

    /// Parallax: the backdrop image drifts at this fraction of the card travel speed.
    /// The image is scaled 15% wider inside MediaDetailView so it can shift without gaps.
    private let parallaxFactor: CGFloat = 0.04

    init(
        items: [PlexMetadata],
        initialIndex: Int,
        namespace: Namespace.ID,
        serverURL: String,
        authToken: String,
        onDismiss: @escaping () -> Void
    ) {
        self.items = items
        self.initialIndex = initialIndex
        self.namespace = namespace
        self.serverURL = serverURL
        self.authToken = authToken
        self.onDismiss = onDismiss
        self._currentIndex = State(initialValue: initialIndex)
        carouselLog.info("Init: \(items.count) items, initialIndex=\(initialIndex)")
    }

    /// Only render full detail for items near the current index
    private var renderRange: ClosedRange<Int> {
        max(0, currentIndex - 2)...min(items.count - 1, currentIndex + 2)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let screenWidth = geo.size.width
                let screenHeight = geo.size.height

                if screenWidth > 0 && screenHeight > 0 {
                    let cardHeight = isExpanded ? screenHeight : (screenHeight - topInset)
                    let currentCardWidth = isExpanded ? screenWidth : cardWidth
                    let currentCornerRadius = isExpanded ? CGFloat(0) : cornerRadius

                    // Card travel distance per page
                    let cardStep = cardWidth + cardSpacing
                    // The image offset that creates the "slower" drift.
                    // Each card's content shifts by (distance from center) * parallaxFactor * cardStep
                    // in the opposite direction of the carousel offset, making the image lag behind.

                    HStack(alignment: .top, spacing: cardSpacing) {
                        ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                            let isCurrent = index == currentIndex
                            let thisCardWidth = isCurrent ? currentCardWidth : cardWidth
                            let inRenderRange = renderRange.contains(index)
                            let thisCornerRadius = isCurrent ? currentCornerRadius : cornerRadius

                            // Parallax: shift content in the same direction the carousel moves,
                            // so the image appears to move slower than the card frame.
                            let distanceFromCenter = CGFloat(index - currentIndex)
                            let innerOffset = isExpanded ? 0 : distanceFromCenter * parallaxFactor * cardStep

                            Group {
                                if inRenderRange {
                                    let mediaItem = plexToMediaItem(item)
                                    MediaDetailView(
                                        item: mediaItem,
                                        presentationMode: isExpanded && isCurrent ? .expandedDetail : .previewCarousel,
                                        backgroundParallaxOffset: isExpanded ? 0 : innerOffset,
                                        showMetadata: isCurrent && metadataVisible,
                                        showExpandedChrome: isExpanded && isCurrent,
                                        allowVerticalScroll: isExpanded && isCurrent
                                    )
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: thisCardWidth, height: cardHeight)
                            .modifier(TopRoundedMask(cornerRadius: thisCornerRadius, height: cardHeight, isActive: !isExpanded))
                            .shadow(color: .black.opacity(isExpanded ? 0 : 0.4), radius: 20, y: 8)
                            .allowsHitTesting(isExpanded && isCurrent)
                            .zIndex(isCurrent ? 1 : 0)
                        }
                    }
                    .offset(
                        x: carouselOffset(screenWidth: screenWidth, currentCardWidth: currentCardWidth),
                        y: isExpanded ? 0 : topInset
                    )
                    .animation(pageAnimation, value: currentIndex)
                    .animation(expandAnimation, value: isExpanded)
                    .onAppear {
                        carouselLog.info("Appeared: \(screenWidth)x\(screenHeight) items=\(self.items.count) idx=\(self.currentIndex)")
                        isCarouselFocused = true
                        // Delay metadata fade-in so image settles first
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                metadataVisible = true
                            }
                        }
                    }
                }
            }
            .ignoresSafeArea()
        }
        .background(.regularMaterial)
        .overlay {
            // Carousel input layer: only active when NOT expanded
            // This prevents .onMoveCommand from eating MediaDetailView's focus events
            if !isExpanded {
                Color.clear
                    .focusable(true)
                    .focused($isCarouselFocused)
                    .focusSection()
                    .onMoveCommand { direction in
                        switch direction {
                        case .left:
                            if currentIndex > 0 {
                                metadataVisible = false
                                withAnimation(pageAnimation) {
                                    currentIndex -= 1
                                }
                                scheduleMetadataFadeIn()
                                carouselLog.info("← idx \(self.currentIndex)")
                            }
                        case .right:
                            if currentIndex < items.count - 1 {
                                metadataVisible = false
                                withAnimation(pageAnimation) {
                                    currentIndex += 1
                                }
                                scheduleMetadataFadeIn()
                                carouselLog.info("→ idx \(self.currentIndex)")
                            }
                        case .down:
                            carouselLog.info("↓ expand idx \(self.currentIndex)")
                            expandCurrentCard()
                        default:
                            break
                        }
                    }
                    .onTapGesture {
                        carouselLog.info("Select (tap) → expand idx \(self.currentIndex)")
                        expandCurrentCard()
                    }
                    .onKeyPress(.return) {
                        carouselLog.info("Select (key) → expand idx \(self.currentIndex)")
                        expandCurrentCard()
                        return .handled
                    }
                    .onPlayPauseCommand {
                        carouselLog.info("PlayPause → expand idx \(self.currentIndex)")
                        expandCurrentCard()
                    }
            }
        }
        .onExitCommand {
            if isExpanded {
                carouselLog.info("Exit → collapse")
                withAnimation(expandAnimation) {
                    isExpanded = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isCarouselFocused = true
                }
            } else {
                carouselLog.info("Exit → dismiss")
                onDismiss()
            }
        }
        .onChange(of: isCarouselFocused) { _, focused in
            carouselLog.info("focused=\(focused) expanded=\(self.isExpanded)")
        }
        .onChange(of: isExpanded) { _, expanded in
            carouselLog.info("expanded=\(expanded)")
        }
        .ignoresSafeArea()
    }

    /// Compute offset to center the current card.
    private func carouselOffset(screenWidth: CGFloat, currentCardWidth: CGFloat) -> CGFloat {
        let centerX = (screenWidth - currentCardWidth) / 2
        let itemsBeforeWidth = CGFloat(currentIndex) * (cardWidth + cardSpacing)
        return centerX - itemsBeforeWidth
    }

    private func expandCurrentCard() {
        withAnimation(expandAnimation) {
            isExpanded = true
        }
    }

    /// Convert a `PlexMetadata` item to the agnostic `MediaItem` required by
    /// `MediaDetailView`. Uses the primary registered provider for providerID.
    private func plexToMediaItem(_ meta: PlexMetadata) -> MediaItem {
        let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
        return PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: authToken)
    }

    /// Fade metadata back in slightly before paging animation finishes
    private func scheduleMetadataFadeIn() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeInOut(duration: 0.7)) {
                metadataVisible = true
            }
        }
    }
}
