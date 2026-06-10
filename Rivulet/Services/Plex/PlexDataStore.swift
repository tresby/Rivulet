//
//  PlexDataStore.swift
//  Rivulet
//
//  Shared data store for Plex content that persists across view recreations
//

import Foundation
import Combine
import UIKit

@MainActor
class PlexDataStore: ObservableObject {
    static let shared = PlexDataStore()

    // MARK: - Published State

    @Published var hubs: [PlexHub] = []
    /// Continue Watching hub fetched from Plex's dedicated `/hubs/continueWatching`
    /// endpoint — matches what Plex's own apps display (respects user dismissals and
    /// library exclusion settings). Nil until first fetch completes.
    @Published var continueWatchingHub: PlexHub?
    @Published var libraries: [PlexLibrary] = []
    @Published var isLoadingHubs = false
    @Published var isLoadingLibraries = false
    @Published var hubsError: String?
    @Published var librariesError: String?
    @Published private(set) var hasLoadedLibraries = false

    /// Per-library hubs for Home screen (keyed by library key)
    @Published var libraryHubs: [String: [PlexHub]] = [:]
    @Published var isLoadingLibraryHubs = false

    /// Increments whenever hubs content changes (not just count)
    /// Views should watch this to trigger UI updates when items change
    @Published private(set) var hubsVersion: UUID = UUID()

    /// Increments when library hubs content changes
    @Published private(set) var libraryHubsVersion: UUID = UUID()

    /// Set by PlexHomeView when processed hubs are ready to display
    @Published var isHomeContentReady = false

    // MARK: - Freshness Tracking

    /// Timestamps of last successful network fetch, keyed by resource identifier
    /// e.g. "libraryItems:/library/sections/1", "libraryHubs:/library/sections/1"
    private var lastFetchTimestamps: [String: Date] = [:]

    /// Record that a resource was just fetched from the network
    func recordFetch(for key: String) {
        lastFetchTimestamps[key] = Date()
    }

    /// Check if a resource was fetched recently enough to skip a refresh
    func isFresh(_ key: String, within interval: TimeInterval) -> Bool {
        guard let timestamp = lastFetchTimestamps[key] else { return false }
        return Date().timeIntervalSince(timestamp) < interval
    }

    /// Clear all freshness timestamps (e.g. on sign out or profile switch)
    func clearFreshnessTimestamps() {
        lastFetchTimestamps.removeAll()
    }

    // MARK: - Full Metadata Cache (stale-while-revalidate)

    /// Cached full metadata responses keyed by ratingKey, with fetch timestamp
    private var fullMetadataCache: [String: (metadata: PlexMetadata, fetchedAt: Date)] = [:]
    private let fullMetadataCacheLimit = 50

    /// Get cached full metadata for a ratingKey (returns nil if not cached)
    func getCachedFullMetadata(for ratingKey: String) -> PlexMetadata? {
        return fullMetadataCache[ratingKey]?.metadata
    }

    /// Check if cached full metadata is fresh enough to skip a network request
    func isFullMetadataFresh(for ratingKey: String, within interval: TimeInterval = 120) -> Bool {
        guard let entry = fullMetadataCache[ratingKey] else { return false }
        return Date().timeIntervalSince(entry.fetchedAt) < interval
    }

    /// Cache full metadata with LRU eviction at 50 entries
    func cacheFullMetadata(_ metadata: PlexMetadata, for ratingKey: String) {
        // LRU eviction: remove oldest entry if at capacity and this is a new key
        if fullMetadataCache[ratingKey] == nil && fullMetadataCache.count >= fullMetadataCacheLimit {
            if let oldestKey = fullMetadataCache.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
                fullMetadataCache.removeValue(forKey: oldestKey)
            }
        }
        fullMetadataCache[ratingKey] = (metadata: metadata, fetchedAt: Date())
    }

    // MARK: - Hero Cache (per library)

    /// Cached hero items per library key - persists across navigation.
    /// Keys: "home" for the home screen, each library key for library-scoped carousels.
    private var heroItemsCache: [String: [PlexMetadata]] = [:]

    /// Get cached hero items for a library (returns nil if not cached)
    func getCachedHeroItems(forLibrary libraryKey: String) -> [PlexMetadata]? {
        return heroItemsCache[libraryKey]
    }

    /// Cache hero items for a library
    func cacheHeroItems(_ items: [PlexMetadata], forLibrary libraryKey: String) {
        heroItemsCache[libraryKey] = items
    }

    /// Clear hero cache (e.g., on sign out)
    func clearHeroCache() {
        heroItemsCache.removeAll()
    }

    // MARK: - Dependencies

    private let networkManager = PlexNetworkManager.shared
    private let cacheManager = CacheManager.shared
    private let authManager = PlexAuthManager.shared
    private let profileManager = PlexUserProfileManager.shared
    let librarySettings = LibrarySettingsManager.shared

    // MARK: - Computed Properties

    /// Libraries filtered by visibility settings and sorted by user preference
    /// Use this for displaying in the sidebar
    var visibleLibraries: [PlexLibrary] {
        librarySettings.filterAndSortLibraries(libraries)
    }

    /// Video libraries only (movies, shows), filtered and sorted
    var visibleVideoLibraries: [PlexLibrary] {
        visibleLibraries.filter { $0.isVideoLibrary }
    }

    /// Music libraries only (artist), filtered and sorted
    var visibleMusicLibraries: [PlexLibrary] {
        visibleLibraries.filter { $0.isMusicLibrary }
    }

    /// Video and music libraries combined (for sidebar display)
    var visibleMediaLibraries: [PlexLibrary] {
        visibleLibraries.filter { $0.isVideoLibrary || $0.isMusicLibrary }
    }

    /// Check if any music library is visible in the sidebar
    var hasMusicLibraryVisible: Bool {
        !visibleMusicLibraries.isEmpty
    }

    /// Video and music libraries that should appear on the Home screen
    var librariesForHomeScreen: [PlexLibrary] {
        visibleMediaLibraries.filter { librarySettings.isLibraryShownOnHome($0.key) }
    }

    // Track if initial load has been attempted
    private var hubsLoadTask: Task<Void, Never>?
    private var librariesLoadTask: Task<Void, Never>?
    private var libraryHubsLoadTask: Task<Void, Never>?

    /// Track whether we've already attempted connection recovery this session
    /// Reset on successful fetch
    private var hasAttemptedConnectionRecovery = false

    // MARK: - Background Polling

    /// Timer for periodic hub refresh (3 minutes)
    private var pollingTimer: Timer?
    private let pollingInterval: TimeInterval = 180 // 3 minutes

    /// Track if playback is active (pause polling during playback)
    private var isPlaybackActive = false

    /// Track if app is in foreground
    private var isInForeground = true

    private init() {
        setupPollingObservers()
    }

    private func setupPollingObservers() {
        // Observe app lifecycle
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isInForeground = true
                self?.startPollingIfNeeded()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isInForeground = false
                self?.stopPolling()
            }
        }

        // Observe playback state
        NotificationCenter.default.addObserver(
            forName: .plexPlaybackStarted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaybackActive = true
                self?.stopPolling()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .plexPlaybackStopped,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaybackActive = false
                self?.startPollingIfNeeded()
            }
        }
    }

    /// Start polling if conditions are met (foreground, not playing, authenticated)
    func startPollingIfNeeded() {
        guard isInForeground,
              !isPlaybackActive,
              authManager.selectedServerURL != nil,
              pollingTimer == nil else { return }

        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollHubs()
            }
        }
    }

    /// Stop polling
    private func stopPolling() {
        guard pollingTimer != nil else { return }
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    /// Poll hubs silently (no loading indicator)
    private func pollHubs() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        await fetchHubsFromServer(serverURL: serverURL, token: token, updateLoading: false)
    }

    // MARK: - Connection Recovery

    /// Check if an error indicates a connection problem that might be fixable
    private func isConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError

        // Network-level connection errors
        let connectionErrorCodes = [
            NSURLErrorCannotConnectToHost,      // -1004
            NSURLErrorTimedOut,                  // -1001
            NSURLErrorNotConnectedToInternet,   // -1009
            NSURLErrorNetworkConnectionLost,    // -1005
            NSURLErrorCannotFindHost,           // -1003
            NSURLErrorDNSLookupFailed,          // -1006
            NSURLErrorSecureConnectionFailed    // -1200
        ]

        if connectionErrorCodes.contains(nsError.code) {
            return true
        }

        // HTTP errors that suggest the server URL is wrong/stale
        if case PlexAPIError.httpError(let statusCode, _) = error {
            // 5xx errors often mean the URL is wrong (server not at that address)
            return (500...599).contains(statusCode)
        }

        return false
    }

    /// Attempt to recover from a connection error by verifying/fixing the connection
    /// Returns true if recovery was attempted and connection is now working
    private func attemptConnectionRecovery() async -> Bool {
        guard !hasAttemptedConnectionRecovery else {
            return false
        }

        hasAttemptedConnectionRecovery = true

        await authManager.verifyAndFixConnection()

        if authManager.isConnected {
            return true
        } else {
            print("📦 PlexDataStore: ❌ Connection recovery failed")
            return false
        }
    }

    // MARK: - Profile Switching

    /// Called when the user switches Plex Home profiles
    /// Clears all user-specific cached data and reloads content
    func onProfileSwitched() async {
        // Cancel any in-flight library hub loading
        libraryHubsLoadTask?.cancel()
        libraryHubsLoadTask = nil

        // Switch library settings to the new user's preferences
        LibrarySettingsManager.shared.onProfileSwitched()

        // Clear user-specific caches
        clearHeroCache()
        clearNextEpisodeCache()
        clearFreshnessTimestamps()
        fullMetadataCache.removeAll()

        // Clear in-memory data (libraries may differ per user)
        hubs = []
        libraries = []
        hasLoadedLibraries = false
        libraryHubs.removeAll()
        hubsVersion = UUID()
        libraryHubsVersion = UUID()
        isHomeContentReady = false

        // Clear on-deck/continue watching cache
        await cacheManager.clearOnDeckCache()

        // Clear library caches (different users may have different library access)
        await cacheManager.clearLibraryCache()

        // Reset connection recovery flag (new profile may have different access)
        hasAttemptedConnectionRecovery = false

        // Reload content for new profile (libraries + hubs in parallel, then library hubs)
        async let libs: () = refreshLibraries()
        async let hubsRefresh: () = refreshHubs()
        _ = await (libs, hubsRefresh)
        await refreshLibraryHubs()

    }

    // MARK: - Hubs (Home View)

    func loadHubsIfNeeded() async {
        // If we already have data, skip
        if !hubs.isEmpty {
            return
        }

        // If already loading, wait for that task
        if let existingTask = hubsLoadTask {
            await existingTask.value
            return
        }

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            hubsError = "Not authenticated"
            return
        }

        isLoadingHubs = true
        hubsError = nil

        // Create a non-cancellable task for the network request
        hubsLoadTask = Task {
            // Try cache first
            if let cached = await cacheManager.getCachedHubs(), !cached.isEmpty {
                await MainActor.run {
                    self.hubs = cached
                    self.hubsVersion = UUID()
                    self.isLoadingHubs = false
                }
                // Background refresh
                await fetchHubsFromServer(serverURL: serverURL, token: token, updateLoading: false)
            } else {
                await fetchHubsFromServer(serverURL: serverURL, token: token, updateLoading: true)
            }
        }

        await hubsLoadTask?.value
        hubsLoadTask = nil
    }

    private func fetchHubsFromServer(serverURL: String, token: String, updateLoading: Bool) async {
        let userId = profileManager.selectedUserId

        do {
            async let hubsTask = fetchHubsOffMain(serverURL: serverURL, token: token, userId: userId)
            async let continueWatchingTask = fetchContinueWatchingOffMain(serverURL: serverURL, token: token, userId: userId)
            let fetchedHubs = try await hubsTask
            let fetchedContinueWatching = try? await continueWatchingTask

            // Reset recovery flag on success
            hasAttemptedConnectionRecovery = false

            // Only update if hubs actually changed (prevents unnecessary re-renders)
            if !hubsAreEqual(self.hubs, fetchedHubs) {
                self.hubs = fetchedHubs
                self.hubsVersion = UUID()  // Signal that content changed
            } else {
            }

            if !continueWatchingHubsAreEqual(self.continueWatchingHub, fetchedContinueWatching) {
                self.continueWatchingHub = fetchedContinueWatching
                self.hubsVersion = UUID()
            }

            // Always update Top Shelf cache after fetching (lightweight, idempotent)
            updateTopShelfCache()
            self.hubsError = nil
            if updateLoading {
                self.isLoadingHubs = false
            }
            await cacheManager.cacheHubs(fetchedHubs)
        } catch {
            let nsError = error as NSError
            print("📦 PlexDataStore: ❌ Hubs fetch error: \(error)")
            print("📦 PlexDataStore: Error domain: \(nsError.domain), code: \(nsError.code)")

            // Ignore cancellation errors
            if nsError.code == NSURLErrorCancelled {
                return
            }

            // Attempt connection recovery for connection-related errors
            if isConnectionError(error) {
                if await attemptConnectionRecovery(),
                   let newServerURL = authManager.selectedServerURL,
                   let newToken = authManager.selectedServerToken {
                    // Retry with new connection
                    print("📦 PlexDataStore: Retrying hubs fetch after connection recovery...")
                    await fetchHubsFromServer(serverURL: newServerURL, token: newToken, updateLoading: updateLoading)
                    return
                }
            }

            if self.hubs.isEmpty {
                self.hubsError = error.localizedDescription
            }
            if updateLoading {
                self.isLoadingHubs = false
            }
        }
    }

    func refreshHubs() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        StartupTimer.mark("refreshHubs start (url=\(URL(string: serverURL)?.host ?? serverURL))")
        isLoadingHubs = true
        await cacheManager.clearOnDeckCache()
        await cacheManager.clearHubsCache()
        clearNextEpisodeCache()
        await StartupTimer.measure("fetchHubsFromServer") {
            await fetchHubsFromServer(serverURL: serverURL, token: token, updateLoading: true)
        }
    }

    // MARK: - Library-Specific Hubs (for separated Home screen)

    /// Load hubs for each library that should appear on the Home screen
    func loadLibraryHubsIfNeeded() async {
        // If already loading, wait for that task (deduplication)
        if let existingTask = libraryHubsLoadTask {
            await existingTask.value
            return
        }

        let librariesToLoad = librariesForHomeScreen

        // Skip if no libraries configured for Home
        guard !librariesToLoad.isEmpty else {
            return
        }

        // Skip if we already have hubs for all libraries
        let missingLibraries = librariesToLoad.filter { libraryHubs[$0.key] == nil }
        guard !missingLibraries.isEmpty else {
            return
        }

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            return
        }

        let userId = profileManager.selectedUserId
        print("📦 PlexDataStore: Loading hubs for \(missingLibraries.count) libraries... (userId: \(userId.map(String.init) ?? "none"))")
        isLoadingLibraryHubs = true

        libraryHubsLoadTask = Task {
            // Try cache first for each missing library
            var librariesNeedingFetch: [PlexLibrary] = []
            for library in missingLibraries {
                if let cached = await cacheManager.getCachedLibraryHubs(forLibrary: library.key), !cached.isEmpty {
                    libraryHubs[library.key] = cached
                } else {
                    librariesNeedingFetch.append(library)
                }
            }

            // If cache provided some data, update UI immediately
            if librariesNeedingFetch.count < missingLibraries.count {
                libraryHubsVersion = UUID()
                isLoadingLibraryHubs = false
            }

            // Fetch remaining libraries from network in parallel
            if !librariesNeedingFetch.isEmpty {
                await withTaskGroup(of: (String, String, [PlexHub]?).self) { group in
                    for library in librariesNeedingFetch {
                        let sectionId = library.key.replacingOccurrences(of: "/library/sections/", with: "")
                        group.addTask {
                            do {
                                let hubs = try await self.networkManager.getLibraryHubs(
                                    serverURL: serverURL,
                                    authToken: token,
                                    sectionId: sectionId,
                                    userId: userId,
                                    count: 24
                                )
                                return (library.key, library.title, hubs)
                            } catch {
                                print("📦 PlexDataStore: ❌ Failed to load hubs for \(library.title): \(error)")
                                return (library.key, library.title, nil)
                            }
                        }
                    }

                    for await (key, title, hubs) in group {
                        if let hubs {
                            libraryHubs[key] = hubs
                            recordFetch(for: "libraryHubs:\(key)")
                        }
                    }
                }
            }

            // Also background-refresh libraries that were served from cache
            let fetchKeys = Set(librariesNeedingFetch.map { $0.key })
            let cachedLibraries = missingLibraries.filter { !fetchKeys.contains($0.key) }
            if !cachedLibraries.isEmpty {
                await withTaskGroup(of: (String, String, [PlexHub]?).self) { group in
                    for library in cachedLibraries {
                        let sectionId = library.key.replacingOccurrences(of: "/library/sections/", with: "")
                        group.addTask {
                            do {
                                let hubs = try await self.networkManager.getLibraryHubs(
                                    serverURL: serverURL,
                                    authToken: token,
                                    sectionId: sectionId,
                                    userId: userId,
                                    count: 24
                                )
                                return (library.key, library.title, hubs)
                            } catch {
                                return (library.key, library.title, nil)
                            }
                        }
                    }

                    for await (key, title, hubs) in group {
                        if let hubs {
                            libraryHubs[key] = hubs
                            recordFetch(for: "libraryHubs:\(key)")
                        }
                    }
                }
            }

            libraryHubsVersion = UUID()
            isLoadingLibraryHubs = false
        }

        await libraryHubsLoadTask?.value
        libraryHubsLoadTask = nil
    }

    /// Refresh hubs for all libraries on Home screen
    func refreshLibraryHubs() async {
        libraryHubs.removeAll()
        await cacheManager.clearLibraryHubsCache()
        await loadLibraryHubsIfNeeded()
    }

    // MARK: - Libraries

    func loadLibrariesIfNeeded() async {
        // If we already have data, skip
        if !libraries.isEmpty {
            hasLoadedLibraries = true
            return
        }

        // If already loading, wait for that task
        if let existingTask = librariesLoadTask {
            await existingTask.value
            return
        }

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            librariesError = "Not authenticated"
            return
        }

        isLoadingLibraries = true
        librariesError = nil

        // Create a non-cancellable task for the network request
        librariesLoadTask = Task {
            // Try cache first
            if let cached = await cacheManager.getCachedLibraries(), !cached.isEmpty {
                await MainActor.run {
                    self.libraries = cached
                    self.isLoadingLibraries = false
                }
                // Background refresh
                await fetchLibrariesFromServer(serverURL: serverURL, token: token, updateLoading: false)
            } else {
                await fetchLibrariesFromServer(serverURL: serverURL, token: token, updateLoading: true)
            }
        }

        await librariesLoadTask?.value
        librariesLoadTask = nil
        hasLoadedLibraries = true
    }

    private func fetchLibrariesFromServer(serverURL: String, token: String, updateLoading: Bool) async {
        let userId = profileManager.selectedUserId

        do {
            let fetched = try await fetchLibrariesOffMain(serverURL: serverURL, token: token, userId: userId)

            // Reset recovery flag on success
            hasAttemptedConnectionRecovery = false

            // Only update if libraries actually changed (prevents unnecessary re-renders)
            if !librariesAreEqual(self.libraries, fetched) {
                self.libraries = fetched
            } else {
            }
            self.librariesError = nil
            if updateLoading {
                self.isLoadingLibraries = false
            }
            // Sync library order settings with current libraries
            self.librarySettings.syncOrderWithLibraries(fetched)
            await cacheManager.cacheLibraries(fetched)
        } catch {
            let nsError = error as NSError
            print("📦 PlexDataStore: ❌ Libraries fetch error: \(error)")
            print("📦 PlexDataStore: Error domain: \(nsError.domain), code: \(nsError.code)")

            // Ignore cancellation errors
            if nsError.code == NSURLErrorCancelled {
                return
            }

            // Attempt connection recovery for connection-related errors
            if isConnectionError(error) {
                if await attemptConnectionRecovery(),
                   let newServerURL = authManager.selectedServerURL,
                   let newToken = authManager.selectedServerToken {
                    // Retry with new connection
                    print("📦 PlexDataStore: Retrying libraries fetch after connection recovery...")
                    await fetchLibrariesFromServer(serverURL: newServerURL, token: newToken, updateLoading: updateLoading)
                    return
                }
            }

            if self.libraries.isEmpty {
                self.librariesError = error.localizedDescription
            }
            if updateLoading {
                self.isLoadingLibraries = false
            }
        }
    }

    // MARK: - Off-main fetch helpers

    private func fetchHubsOffMain(serverURL: String, token: String, userId: Int?) async throws -> [PlexHub] {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await PlexNetworkManager.shared.getHubs(serverURL: serverURL, authToken: token, userId: userId)
        }.value
    }

    private func fetchContinueWatchingOffMain(serverURL: String, token: String, userId: Int?) async throws -> PlexHub? {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await PlexNetworkManager.shared.getContinueWatching(serverURL: serverURL, authToken: token, userId: userId)
        }.value
    }

    private func continueWatchingHubsAreEqual(_ lhs: PlexHub?, _ rhs: PlexHub?) -> Bool {
        let lhsKeys = lhs?.Metadata?.compactMap { $0.ratingKey } ?? []
        let rhsKeys = rhs?.Metadata?.compactMap { $0.ratingKey } ?? []
        return lhsKeys == rhsKeys
    }

    private func fetchLibrariesOffMain(serverURL: String, token: String, userId: Int?) async throws -> [PlexLibrary] {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await PlexNetworkManager.shared.getLibraries(serverURL: serverURL, authToken: token, userId: userId)
        }.value
    }

    func refreshLibraries() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // Dedup concurrent calls. scenePhase->.active + LibrarySettingsView.onAppear
        // can fire back-to-back; the second would just overwrite the first's result.
        guard !isLoadingLibraries else { return }

        isLoadingLibraries = true
        await fetchLibrariesFromServer(serverURL: serverURL, token: token, updateLoading: true)
    }

    // MARK: - Optimistic Updates

    /// Update an item's watch status locally (optimistic update)
    /// This immediately reflects the change in UI before the server refresh completes.
    ///
    /// The same `ratingKey` can appear in multiple hub collections at once:
    /// - `hubs` — the global `/hubs` response, home of Continue Watching.
    /// - `libraryHubs[libraryKey]` — per-library hubs, home of "Recently Added <Library>".
    ///
    /// Both must be walked so a Mark as Watched from Continue Watching also
    /// flips the checkmark on the same title in a Recently Added row below.
    func updateItemWatchStatus(ratingKey: String, watched: Bool) {
        func applyWatchState(to item: inout PlexMetadata) {
            if watched {
                item.viewCount = (item.viewCount ?? 0) + 1
                item.viewOffset = nil
            } else {
                item.viewCount = 0
                item.viewOffset = nil
            }
        }

        var didUpdateHubs = false
        // Update in global hubs (Continue Watching lives here)
        for hubIndex in hubs.indices {
            guard var metadata = hubs[hubIndex].Metadata else { continue }
            var hubChanged = false
            for itemIndex in metadata.indices where metadata[itemIndex].ratingKey == ratingKey {
                applyWatchState(to: &metadata[itemIndex])
                hubChanged = true
            }
            if hubChanged {
                hubs[hubIndex].Metadata = metadata
                didUpdateHubs = true
            }
        }

        var didUpdateLibraryHubs = false
        // Update in per-library hubs (Recently Added <Library> rows live here)
        for (libraryKey, hubList) in libraryHubs {
            var updatedHubList = hubList
            var libraryChanged = false
            for hubIndex in updatedHubList.indices {
                guard var metadata = updatedHubList[hubIndex].Metadata else { continue }
                var hubChanged = false
                for itemIndex in metadata.indices where metadata[itemIndex].ratingKey == ratingKey {
                    applyWatchState(to: &metadata[itemIndex])
                    hubChanged = true
                }
                if hubChanged {
                    updatedHubList[hubIndex].Metadata = metadata
                    libraryChanged = true
                }
            }
            if libraryChanged {
                libraryHubs[libraryKey] = updatedHubList
                didUpdateLibraryHubs = true
            }
        }

        // Bump versions so views recompute their derived state
        if didUpdateHubs {
            hubsVersion = UUID()
        }
        if didUpdateLibraryHubs {
            libraryHubsVersion = UUID()
        }
    }

    // MARK: - Background Prefetch

    private var prefetchTask: Task<Void, Never>?

    /// Prefetch library content in the background for faster navigation
    /// Call this on app start after authentication is verified
    /// Pass libraries directly to avoid polling loops
    func startBackgroundPrefetch(libraries: [PlexLibrary]) {
        // Cancel any existing prefetch
        prefetchTask?.cancel()

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            print("📦 PlexDataStore: Cannot prefetch - not authenticated")
            return
        }

        let videoLibraries = libraries

        // Run heavy prefetch work off the main actor; only hop back when touching UI state.
        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // Prefetch content for each visible/pinned video library only
            for library in videoLibraries {
                guard !Task.isCancelled else { break }

                let libraryKey = library.key

                // Check if already cached
                let hasMoviesCache = await self.cacheManager.getCachedMovies(forLibrary: libraryKey) != nil
                let hasShowsCache = await self.cacheManager.getCachedShows(forLibrary: libraryKey) != nil
                let hasHubsCache = await self.cacheManager.getCachedLibraryHubs(forLibrary: libraryKey) != nil

                if hasMoviesCache || hasShowsCache {
                } else {
                    // Fetch and cache library items
                    do {
                        let result = try await self.networkManager.getLibraryItemsWithTotal(
                            serverURL: serverURL,
                            authToken: token,
                            sectionId: libraryKey,
                            start: 0,
                            size: 30
                        )

                        // Cache based on type
                        if let firstItem = result.items.first {
                            if firstItem.type == "movie" {
                                await self.cacheManager.cacheMovies(result.items, forLibrary: libraryKey)
                            } else if firstItem.type == "show" {
                                await self.cacheManager.cacheShows(result.items, forLibrary: libraryKey)
                            }
                        }
                        await MainActor.run {
                            self.recordFetch(for: "libraryItems:\(libraryKey)")
                        }

                        // Prefetch poster images for first 30 items
                        self.prefetchImages(for: result.items, serverURL: serverURL, token: token)
                    } catch {
                        print("📦 PlexDataStore: ⚠️ Failed to prefetch items for \(library.title): \(error.localizedDescription)")
                    }
                }

                // Prefetch library hubs
                if hasHubsCache {
                } else {
                    do {
                        let hubs = try await self.networkManager.getLibraryHubs(
                            serverURL: serverURL,
                            authToken: token,
                            sectionId: libraryKey
                        )
                        await self.cacheManager.cacheLibraryHubs(hubs, forLibrary: libraryKey)
                        await MainActor.run {
                            self.recordFetch(for: "libraryHubs:\(libraryKey)")
                        }
                    } catch {
                        print("📦 PlexDataStore: ⚠️ Failed to prefetch hubs for \(library.title): \(error.localizedDescription)")
                    }
                }

                // No delay needed — Plex server handles concurrent requests fine on local network
            }

            guard !Task.isCancelled else { return }

            // Prefetch home hub images and next episodes for Continue Watching
            await self.prefetchHubContent(serverURL: serverURL, token: token)

        }
    }

    // MARK: - Image Prefetching

    /// Build image URL for a metadata item
    nonisolated private func buildImageURL(for item: PlexMetadata, serverURL: String, token: String) -> URL? {
        // For episodes, prefer the series poster
        let thumb: String?
        if item.type == "episode" {
            thumb = item.grandparentThumb ?? item.parentThumb ?? item.thumb
        } else {
            thumb = item.thumb
        }

        guard let thumbPath = thumb else { return nil }
        var urlString = "\(serverURL)\(thumbPath)"
        if !urlString.contains("X-Plex-Token") {
            urlString += urlString.contains("?") ? "&" : "?"
            urlString += "X-Plex-Token=\(token)"
        }
        return URL(string: urlString)
    }

    /// Prefetch poster images for a list of items
    nonisolated private func prefetchImages(for items: [PlexMetadata], serverURL: String, token: String) {
        let imageURLs = items.compactMap { buildImageURL(for: $0, serverURL: serverURL, token: token) }
        guard !imageURLs.isEmpty else { return }

        Task.detached(priority: .utility) {
            await ImageCacheManager.shared.prefetch(urls: imageURLs)
        }
    }

    /// Prefetch hub content including images and next episodes for Continue Watching
    private func prefetchHubContent(serverURL: String, token: String) async {
        guard !hubs.isEmpty else { return }

        // Collect all hub items for image prefetching
        var allHubItems: [PlexMetadata] = []
        var continueWatchingEpisodes: [PlexMetadata] = []

        for hub in hubs {
            guard let items = hub.Metadata else { continue }
            allHubItems.append(contentsOf: items)

            // Identify Continue Watching / On Deck hubs
            let identifier = hub.hubIdentifier?.lowercased() ?? ""
            let isContinueWatching = identifier.contains("continuewatching") ||
                                     identifier.contains("ondeck") ||
                                     identifier.contains("inprogress")

            if isContinueWatching {
                // Collect TV episodes for next episode prefetching
                let episodes = items.filter { $0.type == "episode" }
                continueWatchingEpisodes.append(contentsOf: episodes)
            }
        }

        // Prefetch poster images for all hub items
        prefetchImages(for: allHubItems, serverURL: serverURL, token: token)

        // Prefetch next episodes for Continue Watching TV episodes
        if !continueWatchingEpisodes.isEmpty {
            await prefetchNextEpisodes(for: continueWatchingEpisodes, serverURL: serverURL, token: token)
        }
    }

    // MARK: - Next Episode Prefetching

    /// Cache for prefetched next episodes (keyed by current episode ratingKey)
    private(set) var nextEpisodeCache: [String: PlexMetadata] = [:]

    /// Prefetch next episodes for Continue Watching items
    private func prefetchNextEpisodes(for episodes: [PlexMetadata], serverURL: String, token: String) async {
        // Limit to first 5 episodes to avoid too many requests
        let episodesToProcess = Array(episodes.prefix(5))

        for episode in episodesToProcess {
            guard !Task.isCancelled else { break }

            guard let ratingKey = episode.ratingKey else { continue }

            // Skip if already cached
            if nextEpisodeCache[ratingKey] != nil { continue }

            do {
                // Fetch full metadata if parent keys are missing
                var workingEpisode = episode
                if workingEpisode.parentRatingKey == nil || workingEpisode.index == nil {
                    let fullMetadata = try await networkManager.getMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                    workingEpisode.parentRatingKey = fullMetadata.parentRatingKey
                    workingEpisode.grandparentRatingKey = fullMetadata.grandparentRatingKey
                    workingEpisode.parentIndex = fullMetadata.parentIndex
                    workingEpisode.index = fullMetadata.index
                }

                guard let seasonKey = workingEpisode.parentRatingKey,
                      let currentIndex = workingEpisode.index else { continue }

                // Get episodes in current season
                let seasonEpisodes = try await networkManager.getChildren(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: seasonKey
                )

                // Find next episode
                if let nextEp = seasonEpisodes.first(where: { $0.index == currentIndex + 1 }) {
                    nextEpisodeCache[ratingKey] = nextEp

                    // Prefetch the next episode's thumbnail
                    if let imageURL = buildImageURL(for: nextEp, serverURL: serverURL, token: token) {
                        Task.detached(priority: .utility) {
                            _ = await ImageCacheManager.shared.image(for: imageURL)
                        }
                    }
                }
                // Note: We don't try next season here to keep prefetch fast
            } catch {
                print("📦 PlexDataStore: ⚠️ Failed to prefetch next episode for \(episode.title ?? "?"): \(error.localizedDescription)")
            }

            // Small delay between requests
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    /// Get cached next episode for a given episode ratingKey
    func getCachedNextEpisode(for ratingKey: String) -> PlexMetadata? {
        return nextEpisodeCache[ratingKey]
    }

    /// Clear next episode cache
    func clearNextEpisodeCache() {
        nextEpisodeCache.removeAll()
    }

    // MARK: - Top Shelf Cache

    /// Update the Top Shelf cache with Continue Watching items
    /// Called after hubs are fetched to keep Top Shelf in sync
    private func updateTopShelfCache() {

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            print("TopShelf: No server URL or token available")
            return
        }

        // Use server URL as identifier (unique per server)
        let serverIdentifier = serverURL

        // Collect Continue Watching items from hubs
        var continueWatchingItems: [PlexMetadata] = []

        for hub in hubs {
            let identifier = hub.hubIdentifier?.lowercased() ?? ""
            let isContinueWatching = identifier.contains("continuewatching") ||
                                     identifier.contains("ondeck") ||
                                     identifier.contains("inprogress")

            if isContinueWatching, let items = hub.Metadata {
                continueWatchingItems.append(contentsOf: items)
            }
        }

        // Deduplicate by ratingKey and sort by lastViewedAt (Unix timestamp)
        var seen = Set<String>()
        var deduplicatedItems: [PlexMetadata] = []
        for item in continueWatchingItems {
            guard let key = item.ratingKey, !seen.contains(key) else { continue }
            seen.insert(key)
            deduplicatedItems.append(item)
        }
        // Sort by lastViewedAt descending (most recent first)
        deduplicatedItems.sort { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }
        let uniqueItems = deduplicatedItems

        // Convert to TopShelfItem and take top 10
        let topShelfItems = uniqueItems.prefix(10).compactMap { metadata -> TopShelfItem? in
            guard let ratingKey = metadata.ratingKey else { return nil }

            // Build title
            let title: String
            if metadata.type == "episode" {
                title = metadata.fullEpisodeTitle ?? metadata.title ?? "Unknown"
            } else {
                title = metadata.title ?? "Unknown"
            }

            // Build image URL with token
            // For episodes, prefer show poster (grandparentThumb) for Top Shelf display
            let thumbPath: String
            if metadata.type == "episode" {
                thumbPath = metadata.grandparentThumb ?? metadata.parentThumb ?? metadata.thumb ?? ""
            } else {
                thumbPath = metadata.thumb ?? ""
            }
            var imageURL = thumbPath
            if !thumbPath.isEmpty && !thumbPath.hasPrefix("http") {
                imageURL = "\(serverURL)\(thumbPath)"
            }
            if !imageURL.contains("X-Plex-Token") && !imageURL.isEmpty {
                imageURL += imageURL.contains("?") ? "&" : "?"
                imageURL += "X-Plex-Token=\(token)"
            }

            // Convert Unix timestamp to Date
            let lastWatchedDate: Date
            if let timestamp = metadata.lastViewedAt {
                lastWatchedDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
            } else {
                lastWatchedDate = Date()
            }

            return TopShelfItem(
                ratingKey: ratingKey,
                title: title,
                subtitle: metadata.grandparentTitle,
                imageURL: imageURL,
                progress: metadata.watchProgress ?? 0,
                type: metadata.type ?? "movie",
                lastWatched: lastWatchedDate,
                serverIdentifier: serverIdentifier
            )
        }

        TopShelfCache.shared.writeItems(Array(topShelfItems))
    }

    // MARK: - Reset (on sign out)

    func reset() {
        stopPolling()
        hubsLoadTask?.cancel()
        librariesLoadTask?.cancel()
        libraryHubsLoadTask?.cancel()
        prefetchTask?.cancel()
        hubsLoadTask = nil
        librariesLoadTask = nil
        libraryHubsLoadTask = nil
        prefetchTask = nil
        hubs = []
        libraries = []
        isHomeContentReady = false
        hubsError = nil
        librariesError = nil
        isLoadingHubs = false
        isLoadingLibraries = false
        nextEpisodeCache.removeAll()
        heroItemsCache.removeAll()
        clearFreshnessTimestamps()
        fullMetadataCache.removeAll()
        TopShelfCache.shared.clear()
    }

    // MARK: - Diffing Helpers

    /// Compare two hub arrays to avoid unnecessary state updates
    private func hubsAreEqual(_ lhs: [PlexHub], _ rhs: [PlexHub]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (l, r) in zip(lhs, rhs) {
            if l.hubIdentifier != r.hubIdentifier { return false }
            if l.Metadata?.count != r.Metadata?.count { return false }
            // Also compare item watch status to detect changes
            if let lItems = l.Metadata, let rItems = r.Metadata {
                for (lItem, rItem) in zip(lItems, rItems) {
                    if lItem.ratingKey != rItem.ratingKey { return false }
                    if lItem.viewCount != rItem.viewCount { return false }
                    if lItem.viewOffset != rItem.viewOffset { return false }
                }
            }
        }
        return true
    }

    /// Compare two library arrays to avoid unnecessary state updates.
    /// Includes `title` so a server-side rename (same key, new title)
    /// surfaces on the next refresh — keys alone would treat the
    /// renamed list as equal and the UI would stay stale until an
    /// app restart. `type` is included too because a library
    /// retype (movie ⇄ show, rare) also has to invalidate.
    private func librariesAreEqual(_ lhs: [PlexLibrary], _ rhs: [PlexLibrary]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (l, r) in zip(lhs, rhs) {
            if l.key != r.key || l.title != r.title || l.type != r.type {
                return false
            }
        }
        return true
    }
}
