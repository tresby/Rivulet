//
//  HeroOverlayView.swift
//  Rivulet
//
//  Native UIKit hero overlay. Replaces the previous SwiftUI-hosted
//  `HeroOverlayCell` so the entire UIKit Home is one focus model.
//
//  Composition (bottom-up):
//    - HeroSlideView   — logo / metadata / tagline for the current slide
//    - HeroButtonRowView — Play / Watchlist / Info / Next
//    - paging dots     — pinned to the bottom of the overlay
//
//  The slide content lags the backdrop's `currentIndex` by 100ms so the
//  Apple TV "metadata follows the art" beat is preserved (matches
//  `HeroOverlayContent.slideSwapDelay`).
//
//  The view does NOT manage the backdrop image. The collection-view
//  controller hosts `HeroBackdropView` as a sibling and updates it
//  whenever this view emits `onIndexChanged`.
//

import UIKit
import Combine
import os.log

private let heroLog = Logger(subsystem: "com.rivulet.app", category: "HeroOverlayUIKit")

@MainActor
final class HeroOverlayView: UIView {

    // MARK: - Inputs

    private(set) var items: [PlexMetadata] = []
    private var serverURL: String = ""
    private var authToken: String = ""

    /// Index of the slide whose backdrop is currently visible. Drives
    /// `onIndexChanged` (which the controller wires to the backdrop view).
    private(set) var currentIndex: Int = 0

    /// Lags `currentIndex` by 100ms so the metadata column doesn't pop in
    /// before the backdrop crossfade has started. Mirrors
    /// `HeroOverlayContent.displayedIndex`.
    private var displayedIndex: Int = 0
    private var displayedSwapWorkItem: DispatchWorkItem?

    var onIndexChanged: ((Int) -> Void)?
    var onInfo: ((PlexMetadata) -> Void)?
    var onPlay: ((PlexMetadata) -> Void)?
    var onFocusEntered: (() -> Void)?

    // MARK: - Subviews

    private let slideView = HeroSlideView()
    private let buttonRow = HeroButtonRowView()
    private let pagingDots = HeroPagingDotsView()
    private let pagingDotsBackground = UIView()

    // MARK: - State

    private var resolvedPlayTargets: [String: PlexMetadata] = [:]
    private var resolvedForWatchlistCache: [String: PlexMetadata] = [:]
    private var isResolvingPlay = false

    private var watchlistObserver: AnyCancellable?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setUpSubviews()
        wireButtonHandlers()
        observeWatchlist()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func setUpSubviews() {
        slideView.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        pagingDotsBackground.translatesAutoresizingMaskIntoConstraints = false
        pagingDots.translatesAutoresizingMaskIntoConstraints = false

        addSubview(slideView)
        addSubview(buttonRow)
        addSubview(pagingDotsBackground)
        pagingDotsBackground.addSubview(pagingDots)

        pagingDotsBackground.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        pagingDotsBackground.layer.cornerRadius = 12
        pagingDotsBackground.layer.cornerCurve = .continuous
        pagingDotsBackground.isHidden = true

        NSLayoutConstraint.activate([
            // Slide + buttons pinned bottom-left, 120pt from leading edge,
            // matching SwiftUI's `.padding(.leading, 120)`. We hold them off
            // the very bottom by 144pt (24 for the dots + 120pt slack) so
            // the dots can sit centered below without overlapping.
            slideView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 120),
            slideView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -120),

            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 120),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -144),
            buttonRow.topAnchor.constraint(equalTo: slideView.bottomAnchor, constant: 28),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -120),

            pagingDotsBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
            pagingDotsBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),

            pagingDots.topAnchor.constraint(equalTo: pagingDotsBackground.topAnchor, constant: 8),
            pagingDots.bottomAnchor.constraint(equalTo: pagingDotsBackground.bottomAnchor, constant: -8),
            pagingDots.leadingAnchor.constraint(equalTo: pagingDotsBackground.leadingAnchor, constant: 14),
            pagingDots.trailingAnchor.constraint(equalTo: pagingDotsBackground.trailingAnchor, constant: -14)
        ])
    }

    // MARK: - Configure

    func configure(items: [PlexMetadata],
                   serverURL: String,
                   authToken: String,
                   initialIndex: Int) {
        self.items = items
        self.serverURL = serverURL
        self.authToken = authToken
        // Clamp index against new items.
        self.currentIndex = max(0, min(initialIndex, max(0, items.count - 1)))
        self.displayedIndex = currentIndex
        renderSlide(animated: false)
        updateButtonStateForCurrentItem()
        renderPagingDots()
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    /// Forward focus into the button row so the focus engine can find
    /// `play` as the default landing target.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [buttonRow]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.isDescendant(of: self),
           context.previouslyFocusedView?.isDescendant(of: self) != true {
            onFocusEntered?()
        }
    }

    // MARK: - Slide rendering

    private var currentItem: PlexMetadata? {
        guard !items.isEmpty else { return nil }
        let clamped = max(0, min(currentIndex, items.count - 1))
        return items[clamped]
    }

    private var displayedItem: PlexMetadata? {
        guard !items.isEmpty else { return nil }
        let clamped = max(0, min(displayedIndex, items.count - 1))
        return items[clamped]
    }

    private func renderSlide(animated: Bool) {
        guard let item = displayedItem else {
            slideView.configure(item: nil, serverURL: serverURL, authToken: authToken, animated: false)
            return
        }
        slideView.configure(item: item, serverURL: serverURL, authToken: authToken, animated: animated)
    }

    private func renderPagingDots() {
        pagingDotsBackground.isHidden = items.count <= 1
        pagingDots.update(count: items.count, activeIndex: displayedIndex)
    }

    // MARK: - Paging (button -> currentIndex -> backdrop -> delayed slide swap)

    private func advance() {
        guard items.count > 1 else { return }
        let next = (currentIndex + 1) % items.count
        setCurrentIndex(next)
    }

    private func setCurrentIndex(_ newIndex: Int) {
        guard newIndex != currentIndex else { return }
        currentIndex = newIndex
        onIndexChanged?(newIndex)
        updateButtonStateForCurrentItem()

        // Lag the visible slide content by 100ms so the backdrop has time
        // to begin its crossfade before the metadata changes.
        displayedSwapWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.displayedIndex = newIndex
            self.renderSlide(animated: true)
            self.renderPagingDots()
        }
        displayedSwapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: - Buttons + handlers

    private func wireButtonHandlers() {
        buttonRow.onPlay = { [weak self] in self?.handlePlay() }
        buttonRow.onWatchlist = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            Task { @MainActor in await self.toggleWatchlist(for: item) }
        }
        buttonRow.onInfo = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.onInfo?(item)
        }
        buttonRow.onNext = { [weak self] in self?.advance() }
    }

    private func updateButtonStateForCurrentItem() {
        buttonRow.canAdvance = items.count > 1
        if let item = currentItem {
            let tmdb = resolvedTmdbId(for: item)
            let onList = tmdb.map { PlexWatchlistService.shared.contains(tmdbId: $0) } ?? false
            buttonRow.isOnWatchlist = onList
        } else {
            buttonRow.isOnWatchlist = false
        }
        buttonRow.isResolvingPlay = isResolvingPlay
    }

    private func handlePlay() {
        guard !isResolvingPlay, let item = currentItem else { return }
        if let key = item.ratingKey, let cached = resolvedPlayTargets[key] {
            onPlay?(cached)
            return
        }
        if let type = item.type, type == "movie" || type == "episode" {
            onPlay?(item)
            return
        }
        isResolvingPlay = true
        buttonRow.isResolvingPlay = true
        Task { @MainActor in
            let resolved = await HeroPlaySession.resolvePlaybackTarget(
                for: item,
                serverURL: serverURL,
                authToken: authToken
            )
            if let key = item.ratingKey {
                resolvedPlayTargets[key] = resolved
            }
            isResolvingPlay = false
            buttonRow.isResolvingPlay = false
            onPlay?(resolved)
        }
    }

    // MARK: - Watchlist

    private func observeWatchlist() {
        // When the watchlist changes (toggle from anywhere else in the
        // app), refresh our bookmark icon.
        watchlistObserver = PlexWatchlistService.shared.$watchlistGUIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateButtonStateForCurrentItem()
            }
    }

    private func toggleWatchlist(for item: PlexMetadata) async {
        let resolved = await resolvedForWatchlist(item)
        guard let tmdbId = resolved.tmdbId else {
            heroLog.warning("Watchlist toggle aborted: no tmdbId on \(resolved.ratingKey ?? "?", privacy: .public)")
            return
        }
        let guid = "tmdb://\(tmdbId)"
        let service = PlexWatchlistService.shared
        if service.contains(guid: guid) {
            await service.remove(guid: guid)
        } else {
            let watchType: PlexWatchlistItem.WatchlistType = (resolved.type == "show") ? .show : .movie
            let posterURL: URL? = {
                guard let thumbPath = resolved.thumb, !thumbPath.isEmpty else { return nil }
                return URL(string: "\(serverURL)\(thumbPath)?X-Plex-Token=\(authToken)")
            }()
            let watchlistItem = PlexWatchlistItem(
                id: guid,
                title: resolved.title ?? "",
                year: resolved.year,
                type: watchType,
                posterURL: posterURL,
                guids: [guid]
            )
            await service.add(guid: guid, item: watchlistItem)
        }
    }

    private func resolvedForWatchlist(_ item: PlexMetadata) async -> PlexMetadata {
        if item.tmdbId != nil { return item }
        if let ratingKey = item.ratingKey, let cached = resolvedForWatchlistCache[ratingKey] {
            return cached
        }
        guard let ratingKey = item.ratingKey else { return item }
        do {
            let full = try await PlexNetworkManager.shared.getMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )
            resolvedForWatchlistCache[ratingKey] = full
            return full
        } catch {
            return item
        }
    }

    private func resolvedTmdbId(for item: PlexMetadata) -> Int? {
        if let id = item.tmdbId { return id }
        if let key = item.ratingKey, let cached = resolvedForWatchlistCache[key] {
            return cached.tmdbId
        }
        return nil
    }
}
