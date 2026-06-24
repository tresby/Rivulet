//
//  TVSidebarView.swift
//  Rivulet
//
//  Main tvOS navigation using system TabView with sidebarAdaptable style
//

import SwiftUI
import os.log

// Temporary diagnostic logger for intermittent sidebar focus loss.
private let libraryIndexLog = Logger(subsystem: "com.rivulet.app", category: "LibraryIndex")


// MARK: - TVSidebarView

struct TVSidebarView: View {
    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var dataStore = PlexDataStore.shared
    // Observed directly so the sidebar rebuilds when library visibility/order
    // changes in settings. `dataStore.visibleMediaLibraries` reads from this
    // manager but holds it as a plain `let`, so without an explicit
    // @StateObject here, SwiftUI doesn't see hiddenLibraryKeys updates.
    @StateObject private var librarySettings = LibrarySettingsManager.shared
    @StateObject private var liveTVDataStore = LiveTVDataStore.shared
    @StateObject private var profileManager = PlexUserProfileManager.shared
    @StateObject private var nestedNavState = NestedNavigationState()
    @StateObject private var deepLinkHandler = DeepLinkHandler.shared
    @StateObject private var musicQueue = MusicQueue.shared
    @AppStorage("combineLiveTVSources") private var combineLiveTVSources = true
    @AppStorage("liveTVAboveLibraries") private var liveTVAboveLibraries = false
    @AppStorage("showDiscoverTab") private var showDiscoverTab = true
    @AppStorage("discoverAboveLibraries") private var discoverAboveLibraries = true
    @AppStorage("displaySize") private var displaySizeRaw = DisplaySize.normal.rawValue
    @State private var selectedTab: SidebarTab = .home
    @State private var previousTab: SidebarTab = .home
    // The library set the SIDEBAR renders, decoupled from the live
    // `dataStore.visibleMediaLibraries`. Mutating the sidebar's tab set while
    // focus is in Settings corrupts the .sidebarAdaptable sidebar's focus
    // acceptance for the session (a known tvOS bug). So we only sync this
    // snapshot when the user is NOT in Settings (see `syncSidebarStructure`),
    // deferring fresh-sign-in library loads until they navigate to a safe tab.
    @State private var sidebarLibraries: [PlexLibrary] = []
    // The rest of the sidebar STRUCTURE, snapshotted for the same reason as
    // `sidebarLibraries`: the Live TV section appearing/disappearing (e.g. Plex
    // Live TV clearing on sign-out), the Discover tab, and the section ordering
    // all change the sidebar's tab set, which wedges focus if it happens while
    // in Settings. These mirror the live values but only sync when not in
    // Settings (see `syncSidebarStructure`). Defaults match the @AppStorage
    // defaults so the first render is correct before the initial sync.
    @State private var sidebarLiveTVSources: [LiveTVDataStore.LiveTVSourceInfo] = []
    @State private var sidebarCombineLiveTV = true
    @State private var sidebarShowDiscover = true
    @State private var sidebarDiscoverAbove = true
    @State private var sidebarLiveTVAbove = false
    @State private var showProfilePicker = false
    @State private var showProfileSwitcher = false
    @State private var hasCheckedProfilePicker = false
    @State private var isAwaitingProfileSelection = false
    @AppStorage("lastSeenBuild") private var lastSeenBuild = ""
    @State private var showWhatsNew = false
    @State private var whatsNewVersion = ""
    @State private var deepLinkDetailItem: MediaItem?
    @State private var didApplyDebugLaunch = false
    @State private var musicLibraryEntryToken = UUID()
    // Fresh sign-in: a returning user already has credentials at launch (the
    // sidebar populates via the normal Home sync), so we mark it handled in
    // onAppear and DON'T prompt. Only a genuine sign-in this session (libraries
    // 0→N while signed in) offers a quick reload to populate the sidebar.
    @State private var freshSignInHandled = false

    @Namespace private var contentNamespace
    @Environment(\.resetFocus) private var resetFocus

    private var uiScale: CGFloat {
        (DisplaySize(rawValue: displaySizeRaw) ?? .normal).scale
    }

    private var profileName: String {
        profileManager.selectedUser?.displayName ?? authManager.username ?? "Account"
    }

    private var isMusicLibrarySelected: Bool {
        guard case .library(let key) = selectedTab else { return false }
        return dataStore.libraries.first(where: { $0.key == key })?.isMusicLibrary ?? false
    }

    private var tabSelection: Binding<SidebarTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                // Block tab changes while in nested navigation (carousel,
                // detail view, or deep Settings sub-page).
                if nestedNavState.isNested || nestedNavState.isSettingsSubPage {
                    return
                }

                if newTab == .account {
                    if profileManager.hasMultipleProfiles {
                        showProfileSwitcher = true
                    }
                    return  // Never store .account — selectedTab stays unchanged
                }
                selectedTab = newTab
            }
        )
    }

    var body: some View {
        sidebarTabView
        .onExitCommand { }
        .task { await Self.installSidebarFocusGuard() }
        .task { await focusRecoveryWatchdog() }
        .onAppear { syncSidebarStructure() }
        // Handle tab selection
        .onChange(of: selectedTab) { _, newTab in
            nestedNavState.isNested = false
            previousTab = newTab
            if isMusicLibraryTab(newTab) {
                musicLibraryEntryToken = UUID()
            }
            // Apply any structure changes deferred while in Settings, now that
            // we are on a safe tab (the sidebar can mutate without wedging).
            syncSidebarStructure()
        }
        .onChange(of: liveSidebarStructureSignature) { _, _ in
            // Sync the sidebar's structure to live data — but only when NOT in
            // Settings (syncSidebarStructure guards this). Sign-in/out and other
            // structure changes that happen in Settings are deferred until the
            // user leaves (or a rebuild on leaving the sub-page).
            syncSidebarStructure()
        }
        .onChange(of: authManager.hasCredentials) { old, new in
            // We intentionally do NOT auto-jump to Home on fresh sign-in (adding
            // a server happens in Settings; the user stays there). The sidebar
            // focus wedge that used to require the auto-jump is now handled
            // directly via `sidebarLibraries` (the sidebar tab set is not mutated
            // while in Settings — see `syncSidebarStructure`).
            if old && !new {
                // Clear watchlist state on logout. We do NOT clear
                // `sidebarLibraries` here — that would mutate the sidebar while
                // the user is still in Settings (sign-out happens there). It is
                // synced (to empty) when they next leave Settings.
                PlexWatchlistService.shared.reset()
            }
        }
        // Reset tab selection when live TV source mode changes
        .onChange(of: combineLiveTVSources) { _, combined in
            if case .liveTV = selectedTab {
                selectedTab = .liveTV(sourceId: combined ? nil : liveTVDataStore.sources.first?.id)
            }
        }
        // If the user disables the Discover tab while it's selected, bounce
        // back to Home so they're not stuck on a hidden tab.
        .onChange(of: showDiscoverTab) { _, shown in
            if !shown && selectedTab == .discover {
                selectedTab = .home
            }
        }
        .task(id: authManager.hasCredentials) {
            StartupTimer.mark("TVSidebar .task entry")
            guard authManager.selectedServerToken != nil else { return }

            // If profile picker on launch is enabled, block content immediately
            if profileManager.showProfilePickerOnLaunch && !hasCheckedProfilePicker {
                isAwaitingProfileSelection = true
            }

            if profileManager.showProfilePickerOnLaunch && !hasCheckedProfilePicker {
                // Must await profile data before showing picker
                await profileManager.fetchHomeUsers()
                hasCheckedProfilePicker = true

                if profileManager.hasMultipleProfiles {
                    showProfilePicker = true
                    // Content will load after profile is selected
                    return
                } else {
                    isAwaitingProfileSelection = false
                }
            } else {
                // Home users are NOT needed to render the home screen (single-user
                // content uses the main auth token); they only feed the profile
                // switcher / settings. The plex.tv /api/v2/home/users call can be
                // slow (18s on device) and was contending with the critical hub
                // fetch for the network + cooperative thread pool at launch — so
                // defer it until after the home content path has had its window.
                hasCheckedProfilePicker = true
                Task {
                    // 10s: the 3s defer landed this slow plex.tv call back
                    // inside the busy launch window. Nothing reads home users
                    // until the profile switcher/settings are opened.
                    try? await Task.sleep(for: .seconds(10))
                    await profileManager.fetchHomeUsers()
                }
            }

            // CRITICAL PATH: Only hubs needed for home screen to render
            StartupTimer.mark("TVSidebar → loadHubsIfNeeded")
            await dataStore.loadHubsIfNeeded()
            StartupTimer.mark("TVSidebar loadHubsIfNeeded returned")

            // Kick off watchlist fetch — DEFERRED so it doesn't contend with
            // the home's cache decode + first paint at launch (the watchlist
            // row fills in a couple seconds later).
            Task {
                try? await Task.sleep(for: .seconds(2))
                await PlexWatchlistService.shared.fetchWatchlist()
            }

            // BACKGROUND: Libraries -> library hubs -> prefetch (chained, not blocking home).
            // Delayed so the big per-library hub decodes (316KB/550KB payloads)
            // don't saturate the cores during the home's first paint.
            Task {
                try? await Task.sleep(for: .seconds(2))
                await dataStore.loadLibrariesIfNeeded()
                await dataStore.loadLibraryHubsIfNeeded()
                dataStore.startBackgroundPrefetch(libraries: dataStore.visibleVideoLibraries)

                // Rebuild the library GUID index in the background. Used by Discover and
                // Watchlist surfaces to answer "do I own this?" in O(1). The index
                // matches by external GUID, so the fetch must include them
                // (Plex omits them from the default summary response).
                //
                // DEFERRED 20s past launch: this fetches ~5MB per library
                // (size: 5000 + includeGuids) — ~20MB total — and was running
                // inside the launch window, contending with the home's
                // critical path for network + decode. The only cost of the
                // delay is "in your library" badges on Discover/Watchlist
                // resolving late. Follow-up: persist the index to disk with a
                // TTL so cold launches don't refetch 20MB at all.
                Task.detached(priority: .background) {
                    try? await Task.sleep(for: .seconds(20))
                    let (serverURL, token) = await MainActor.run {
                        (PlexAuthManager.shared.selectedServerURL, PlexAuthManager.shared.selectedServerToken)
                    }
                    guard let serverURL, let token else { return }

                    let visible = await MainActor.run { PlexDataStore.shared.visibleVideoLibraries }

                    var allItems: [PlexMetadata] = []
                    for library in visible {
                        if let result = try? await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                            serverURL: serverURL,
                            authToken: token,
                            sectionId: library.key,
                            start: 0,
                            size: 5000,
                            includeGuids: true
                        ) {
                            allItems.append(contentsOf: result.items)
                        }
                    }
                    let withGuids = allItems.filter { ($0.Guid ?? []).isEmpty == false }
                    let sample = withGuids.first.flatMap { $0.Guid?.first?.id } ?? "(none)"
                    libraryIndexLog.info("[GUIDIndex] populated: \(allItems.count) items total, \(withGuids.count) with external GUIDs, sample=\(sample, privacy: .public)")
                    await LibraryGUIDIndex.shared.replace(with: allItems)
                }
            }
        }
        .task {
            // Start background preloading of Live TV data (low priority)
            liveTVDataStore.startBackgroundPreload()
        }
        .onChange(of: deepLinkHandler.pendingPlayback) { _, metadata in
            guard let metadata else { return }
            presentPlayerForDeepLink(metadata)
            deepLinkHandler.pendingPlayback = nil
        }
        // Handle detail deep links from Siri search results
        .onChange(of: deepLinkHandler.pendingDetail) { _, metadata in
            guard let metadata,
                  let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }
            let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
            deepLinkDetailItem = PlexMediaMapper.item(metadata, providerID: providerID, serverURL: serverURL, authToken: token)
            deepLinkHandler.pendingDetail = nil
        }
        .fullScreenCover(item: $deepLinkDetailItem) { metadata in
            MediaDetailView(item: metadata)
                .presentationBackground(.black)
        }
        // What's New: present the SAME UIKit glass changelog popup as
        // Settings → Changelog (not a separate SwiftUI dialog) for consistency.
        .onChange(of: showWhatsNew) { _, show in
            if show { presentWhatsNewPopup() }
        }
        .onAppear {
            // Returning user already authed at launch → sidebar populates via the
            // normal Home sync; don't offer the fresh-sign-in reload.
            if authManager.selectedServerToken != nil { freshSignInHandled = true }
            applyDebugLaunchTab()
            // Defer What's New check if profile picker needs to be shown first
            if profileManager.showProfilePickerOnLaunch && authManager.selectedServerToken != nil {
                return
            }
            checkAndShowWhatsNew()
        }
        // DEBUG: launch straight into a named library, e.g.
        // `xcrun simctl launch --setenv RIVULET_OPEN_LIBRARY="TV Shows" ...`
        .onChange(of: dataStore.libraries.count) { _, _ in applyDebugLaunchTab() }
        // Fresh sign-in: libraries just arrived this session → offer a quick
        // reload to populate the sidebar now (instead of only on reaching Home).
        .onChange(of: visibleLibraryCount) { _, count in
            handleVisibleLibraryCountChange(count)
        }
        // Profile picker overlay (launch-time "Who's Watching")
        .fullScreenCover(isPresented: $showProfilePicker) {
            ProfilePickerOverlay(isPresented: $showProfilePicker)
        }
        .onChange(of: showProfilePicker) { _, isShowing in
            if !isShowing {
                // Profile selected, unblock content
                isAwaitingProfileSelection = false

                // Load content if not already loaded (profile switch handles its own reload)
                Task {
                    if dataStore.hubs.isEmpty {
                        // CRITICAL PATH: Only hubs needed for home screen to render
                        await dataStore.loadHubsIfNeeded()

                        // BACKGROUND: Libraries -> library hubs -> prefetch
                        Task {
                            await dataStore.loadLibrariesIfNeeded()
                            await dataStore.loadLibraryHubsIfNeeded()
                            dataStore.startBackgroundPrefetch(libraries: dataStore.visibleVideoLibraries)
                        }
                    }
                }

                // Now show What's New if applicable (was deferred for profile picker)
                checkAndShowWhatsNew()
            }
        }
        // Compact profile switcher popup (from sidebar account tab)
        .fullScreenCover(isPresented: $showProfileSwitcher) {
            ProfileSwitcherPopup(
                isPresented: $showProfileSwitcher,
                profileManager: profileManager
            )
            .presentationBackground(.clear)
        }
        // Music Now Playing overlay
        .fullScreenCover(isPresented: $musicQueue.showNowPlaying) {
            MusicNowPlayingView(isPresented: $musicQueue.showNowPlaying)
                .presentationBackground(.black)
        }
    }

    // MARK: - Tab Definitions

    private var sidebarTabView: some View {
        TabView(selection: tabSelection) {
            Tab(value: SidebarTab.account) {
                Color.clear.ignoresSafeArea()
            } label: {
                Label {
                    Text(selectedTab == .account ? "Switch Profile" : profileName)
                } icon: {
                    SidebarProfileAvatar(user: profileManager.selectedUser, size: 20, trailingPad: 10)
                        .frame(width: 28, height: 28)
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: SidebarTab.search) {
                tabContent(for: .search)
            }

            Tab("Home", systemImage: "house.fill", value: SidebarTab.home) {
                tabContent(for: .home)
            }

            // Discover above libraries — bare Tab, flush under Home.
            // All gating reads the `sidebar*` snapshot (NOT live values) so the
            // sidebar's tab set never changes while the user is in Settings.
            if sidebarShowDiscover && sidebarDiscoverAbove {
                Tab("Discover", systemImage: "sparkles", value: SidebarTab.discover) {
                    tabContent(for: .discover)
                }
            }

            if sidebarLiveTVAbove {
                if !sidebarLiveTVSources.isEmpty {
                    liveTVTabSection
                }
                if !sidebarLibraries.isEmpty {
                    libraryTabSection
                }
            } else {
                if !sidebarLibraries.isEmpty {
                    libraryTabSection
                }
                if !sidebarLiveTVSources.isEmpty {
                    liveTVTabSection
                }
            }

            // Discover below libraries — TabSection so it separates from the
            // library/liveTV group above it.
            if sidebarShowDiscover && !sidebarDiscoverAbove {
                discoverTabSection
            }

            TabSection("") {
                Tab("Settings", systemImage: "gearshape.fill", value: SidebarTab.settings) {
                    tabContent(for: .settings)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .toolbarVisibility((nestedNavState.isNested || isMusicLibrarySelected || nestedNavState.isSettingsSubPage) ? .hidden : .automatic, for: .tabBar)
        .animation(.easeInOut(duration: 0.18), value: nestedNavState.isNested)
        .onChange(of: nestedNavState.isNested) { _, isNested in
            guard isNested else { return }
            resetFocus(in: contentNamespace)
        }
    }

    private var libraryTabSection: some TabContent<SidebarTab> {
        // Renders the decoupled `sidebarLibraries` snapshot (NOT the live
        // `dataStore.visibleMediaLibraries`) so the sidebar tab set only changes
        // at safe times — see `syncSidebarStructure`.
        TabSection(authManager.savedServerName ?? "Library") {
            ForEach(sidebarLibraries, id: \.key) { library in
                Tab(library.title, systemImage: iconForLibrary(library),
                    value: SidebarTab.library(key: library.key)) {
                    tabContent(for: .library(key: library.key))
                }
            }
        }
    }

    private var discoverTabSection: some TabContent<SidebarTab> {
        TabSection("") {
            Tab("Discover", systemImage: "sparkles", value: SidebarTab.discover) {
                tabContent(for: .discover)
            }
        }
    }

    @TabContentBuilder<SidebarTab>
    private var liveTVTabSection: some TabContent<SidebarTab> {
        TabSection("Live TV") {
            // Snapshot-driven (NOT live `liveTVDataStore.sources` / the
            // combine setting) so the section's tabs never change while in
            // Settings — see `syncSidebarStructure`.
            if sidebarCombineLiveTV {
                Tab("Channels", systemImage: "tv.and.mediabox",
                    value: SidebarTab.liveTV(sourceId: nil)) {
                    tabContent(for: .liveTV(sourceId: nil))
                }
            } else {
                ForEach(sidebarLiveTVSources) { source in
                    Tab(source.displayName.replacingOccurrences(of: " Live TV", with: ""),
                        systemImage: iconForSourceType(source.sourceType),
                        value: SidebarTab.liveTV(sourceId: source.id)) {
                        tabContent(for: .liveTV(sourceId: source.id))
                    }
                }
            }
        }
    }

    // MARK: - Tab Content

    /// Settings tab content. The Settings surface is pure UIKit
    /// (`UIKitSettingsContainer` → `SettingsContainerViewController`); the old
    /// SwiftUI `SettingsView` has been retired.
    @ViewBuilder
    private var settingsTabContent: some View {
        UIKitSettingsContainer()
    }

    @ViewBuilder
    private func tabContent(for tab: SidebarTab) -> some View {
        // The profile gate is an OVERLAY, not a structural branch. The old
        // `if isAwaitingProfileSelection { Color.clear } else { content }`
        // swapped the whole tree when the flag flipped, changing the
        // content's SwiftUI identity — which discarded and REBUILT the UIKit
        // home (two live home VCs through the entire launch window). An
        // overlay conceals without touching identity. (Focus isolation while
        // the gate is up comes from the profile picker's own presentation.)
        Group {
            switch tab {
            case .account:
                Color.clear
            case .search:
                // UIKit Search: the home VC in .search mode under the system
                // `.searchable` keyboard. The SwiftUI PlexSearchView is the
                // retired implementation, kept in-tree like PlexHomeView.
                UIKitSearchContainer()
            case .home:
                // PlexHomeRoot is ALWAYS rendered (never an if/else branch) so
                // its SwiftUI identity — and the singleton UIKit home VC it
                // hosts — stays stable across the `hasCredentials` false→true
                // flip on sign-in. The old `if hasCredentials { PlexHomeRoot }
                // else { welcomeView }` swapped the tree on sign-in, which made
                // SwiftUI tear the home VC out of the hierarchy (willMove(to:
                // nil) → window=nil, orphaned) and never re-host it: blank,
                // unfocusable Home + watchdog loop. This is the SAME structural-
                // branch anti-pattern the profile gate (below) already fixed by
                // becoming an overlay. The welcome screen is now an opaque
                // overlay; the home behind is `.disabled` so focus lands on the
                // welcome button, not a hidden home element.
                PlexHomeRoot()
                    .disabled(!authManager.hasCredentials)
                    .overlay {
                        if !authManager.hasCredentials {
                            welcomeView
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.black)
                        }
                    }
            case .discover:
                // UIKit Discover: same hero + shelf surface as the home,
                // TMDB-fed (HomeMode.discover). The SwiftUI DiscoverView is
                // the retired implementation, kept in-tree like PlexHomeView.
                UIKitHomeContainer(mode: .discover)
            case .library(let key):
                if let lib = dataStore.libraries.first(where: { $0.key == key }) {
                    if lib.isMusicLibrary {
                            MusicHomeView(libraryKey: lib.key, libraryTitle: lib.title)
                                .id("\(lib.key)-\(musicLibraryEntryToken.uuidString)")
                    } else {
                        // Library page = the home VC in .library mode (one
                        // implementation, two surfaces). `.id` rebuilds the
                        // controller when switching libraries.
                        UIKitHomeContainer(mode: .library(key: lib.key, title: lib.title))
                            .id(lib.key)
                    }
                }
            case .liveTV(let sourceId):
                LiveTVContainerView(sourceIdFilter: sourceId)
            case .settings:
                settingsTabContent
            }
        }
        .overlay {
            if isAwaitingProfileSelection {
                Color.black.ignoresSafeArea()
            }
        }
        .focusScope(contentNamespace)
        .environment(\.nestedNavigationState, nestedNavState)
        .environment(\.uiScale, uiScale)
    }

    // MARK: - Welcome View

    private var welcomeView: some View {
        VStack(spacing: 28) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.3))

            VStack(spacing: 12) {
                Text("Welcome to Rivulet")
                    .font(.system(size: 46, weight: .semibold))

                Text("Connect your Plex server in Settings to get started.")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            Button {
                selectedTab = .settings
            } label: {
                Text("Open Settings")
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.card)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Icon Helpers

    private func iconForLibrary(_ library: PlexLibrary) -> String {
        switch library.type {
        case "movie": return "film.fill"
        case "show": return "tv.fill"
        case "artist": return "music.note"
        case "photo": return "photo.fill"
        default: return "folder.fill"
        }
    }

    private func iconForSourceType(_ sourceType: LiveTVSourceType) -> String {
        switch sourceType {
        case .plex: return "play.rectangle.fill"
        case .dispatcharr: return "antenna.radiowaves.left.and.right"
        case .genericM3U: return "list.bullet.rectangle"
        }
    }

    /// DEBUG: jump straight to a library named by the RIVULET_OPEN_LIBRARY env
    /// var once libraries have loaded, so sim iteration skips the sidebar nav.
    private func applyDebugLaunchTab() {
        guard !didApplyDebugLaunch,
              let name = ProcessInfo.processInfo.environment["RIVULET_OPEN_LIBRARY"],
              let lib = dataStore.visibleMediaLibraries.first(where: { $0.title == name }) else { return }
        didApplyDebugLaunch = true
        selectedTab = .library(key: lib.key)
    }

    private func isMusicLibraryTab(_ tab: SidebarTab) -> Bool {
        guard case .library(let key) = tab else { return false }
        return dataStore.libraries.first(where: { $0.key == key })?.isMusicLibrary ?? false
    }

    /// Sync the sidebar's library tab set (`sidebarLibraries`) to the live
    /// `dataStore.visibleMediaLibraries` — but ONLY while the user is not in
    /// Settings. Mutating the `.sidebarAdaptable` sidebar's tab set while focus
    /// is in Settings content corrupts the sidebar's focus acceptance for the
    /// session (the sidebar then refuses focus — "opens then closes"). Deferring
    /// the sync until the user is on a safe tab means a fresh sign-in (which
    /// happens in Settings) never mutates the sidebar while it's vulnerable; the
    /// library tabs appear the moment they navigate away, like the clean launch
    /// path.
    /// Snapshot the live sidebar structure (libraries + Live TV / Discover /
    /// ordering) into the `sidebar*` @State — but ONLY when not in Settings.
    /// Mutating the sidebar's tab set while focused in Settings corrupts its
    /// focus for the session, so structure changes (fresh sign-in library load,
    /// Plex Live TV clearing on sign-out, etc.) are deferred until a safe tab.
    /// Present the canonical UIKit changelog popup (same one Settings uses) for
    /// the fresh-launch "What's New", instead of a bespoke SwiftUI dialog.
    private func presentWhatsNewPopup() {
        guard let top = Self.topPresentedViewController() else { showWhatsNew = false; return }
        let popup = SettingsContent.makeChangelogPopup()
        popup.onDismiss = { showWhatsNew = false }
        top.present(popup, animated: true)
    }

    /// Sidebar-relevant library count (kept out of `body` to ease type-checking).
    private var visibleLibraryCount: Int { dataStore.visibleMediaLibraries.count }

    private func handleVisibleLibraryCountChange(_ count: Int) {
        guard !freshSignInHandled, count > 0,
              authManager.selectedServerToken != nil else { return }
        freshSignInHandled = true
        presentFreshSignInReloadPopup()
    }

    /// First sign-in: offer a quick soft-restart so the freshly-loaded libraries
    /// populate the sidebar immediately (the same glass confirm as the toggle
    /// flow). "Later" leaves it — the sidebar still fills in when you reach Home.
    private func presentFreshSignInReloadPopup(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let top = Self.topPresentedViewController()
            let name = top.map { String(describing: type(of: $0)) } ?? "nil"
            // Right after sign-in the Plex auth screen is still the top VC and is
            // about to dismiss; presenting on a transitioning VC is swallowed.
            // Wait until the main UI is on top.
            let transient = top == nil
                || top!.isBeingDismissed
                || top!.isBeingPresented
                || name.contains("Auth")
            if transient {
                if attempt < 12 { self.presentFreshSignInReloadPopup(attempt: attempt + 1) }
                return
            }
            let popup = ConfirmationPopupViewController(
                title: "Load Your Libraries?",
                message: "Rivulet will quickly reload to add your libraries to the sidebar and return you to the Home screen.",
                confirmTitle: "Reload",
                cancelTitle: "Later",
                onConfirm: { AppRestartCoordinator.shared.softRestart() })
            top!.present(popup, animated: true)
        }
    }

    private static func topPresentedViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    private func syncSidebarStructure() {
        // Never mutate the sidebar's tab set while focused in Settings (it
        // corrupts .sidebarAdaptable focus for the session). On a safe tab the
        // in-place sync is fine; Settings changes apply via a soft restart.
        guard selectedTab != .settings else { return }
        applySidebarSnapshotFromLive()
    }

    /// Copy the live sidebar structure into the `sidebar*` snapshot. Guarded by
    /// `syncSidebarStructure` so it only runs on a safe (non-Settings) tab.
    private func applySidebarSnapshotFromLive() {
        let live = dataStore.visibleMediaLibraries
        if sidebarLibraries.map(\.key) != live.map(\.key) { sidebarLibraries = live }
        let sources = liveTVDataStore.sources
        if sidebarLiveTVSources.map(\.id) != sources.map(\.id) { sidebarLiveTVSources = sources }
        if sidebarCombineLiveTV != combineLiveTVSources { sidebarCombineLiveTV = combineLiveTVSources }
        if sidebarShowDiscover != showDiscoverTab { sidebarShowDiscover = showDiscoverTab }
        if sidebarDiscoverAbove != discoverAboveLibraries { sidebarDiscoverAbove = discoverAboveLibraries }
        if sidebarLiveTVAbove != liveTVAboveLibraries { sidebarLiveTVAbove = liveTVAboveLibraries }
    }

    /// Equatable signature of all sidebar-structure inputs, used as a single
    /// `onChange` trigger (kept out of `body`).
    private struct SidebarStructureSignature: Equatable {
        var libraryKeys: [String]
        var liveTVSourceIDs: [String]
        var combineLiveTV: Bool
        var showDiscover: Bool
        var discoverAbove: Bool
        var liveTVAbove: Bool
    }
    private var liveSidebarStructureSignature: SidebarStructureSignature {
        SidebarStructureSignature(
            libraryKeys: dataStore.visibleMediaLibraries.map(\.key),
            liveTVSourceIDs: liveTVDataStore.sources.map(\.id),
            combineLiveTV: combineLiveTVSources,
            showDiscover: showDiscoverTab,
            discoverAbove: discoverAboveLibraries,
            liveTVAbove: liveTVAboveLibraries
        )
    }


    // MARK: - Deep Link Player

    /// Present player for a deep link from Top Shelf
    private func presentPlayerForDeepLink(_ metadata: PlexMetadata) {
        Task {
            let (artImage, thumbImage) = await getPlayerImages(for: metadata)

            await MainActor.run {
                let viewModel = UniversalPlayerViewModel(
                    metadata: metadata,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? "",
                    startOffset: metadata.viewOffset.map { Double($0) / 1000.0 },
                    loadingArtImage: artImage,
                    loadingThumbImage: thumbImage
                )
                let playerVC = PlayerPresenter.makeViewController(viewModel: viewModel)

                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = scene.windows.first?.rootViewController {
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
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return (nil, nil) }

        let request = metadata.heroBackdropRequest(
            serverURL: serverURL,
            authToken: token
        )
        return await HeroBackdropResolver.shared.playerLoadingImages(for: request)
    }

    // MARK: - What's New

    // MARK: - Focus Recovery

    /// Monitors for lost focus and restores it to the content area.
    /// Catches cases where focus ends up in limbo after overlays, popups, etc.
    @MainActor
    private func focusRecoveryWatchdog() async {
        // Wait for initial layout
        try? await Task.sleep(for: .seconds(2))

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))

            // Skip recovery while overlays are active
            guard !showProfileSwitcher, !showProfilePicker, !showWhatsNew else { continue }

            // Check if any view in the window has focus
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first,
                  let focusSystem = window.rootViewController?.view.window?.windowScene?.focusSystem
            else { continue }

            // Safety net: if the whole window has lost focus, force it back
            // into the current tab's content so the user is never stranded.
            if focusSystem.focusedItem == nil {
                resetFocus(in: contentNamespace)
            }
        }
    }

    // MARK: - Sidebar Focus Containment

    /// Overrides shouldUpdateFocus on the sidebar's collection view class
    /// to prevent focus from escaping downward (like the Apple TV app).
    @MainActor
    private static func installSidebarFocusGuard() async {
        try? await Task.sleep(for: .seconds(1))

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return }

        var hasSwizzled = false

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))

            if let cv = findSidebarCollectionView(in: window) {
                // Disable scroll bounce
                cv.bounces = false
                cv.alwaysBounceVertical = false

                // Swizzle shouldUpdateFocus once on the collection view's class
                if !hasSwizzled {
                    Self.overrideSidebarFocusBehavior(on: type(of: cv))
                    hasSwizzled = true
                }
            }
        }
    }

    /// Replaces shouldUpdateFocus(in:) on the sidebar collection view class
    /// to block downward focus escape while allowing all other focus movement.
    private static func overrideSidebarFocusBehavior(on cvClass: AnyClass) {
        let selector = #selector(UIView.shouldUpdateFocus(in:))

        // Save the original implementation (if any) so we can call it for non-blocked cases
        let originalIMP = class_getMethodImplementation(cvClass, selector)

        typealias OriginalFunc = @convention(c) (AnyObject, Selector, UIFocusUpdateContext) -> Bool
        let originalFunc = unsafeBitCast(originalIMP, to: OriginalFunc.self)

        let block: @convention(block) (AnyObject, UIFocusUpdateContext) -> Bool = { obj, context in
            guard let selfView = obj as? UICollectionView else { return true }

            let width = selfView.frame.width

            // Only apply to sidebar-width collection views (not content area lists)
            guard width > 0 && width < 500 else {
                return originalFunc(obj, selector, context)
            }

            // Block focus from leaving the sidebar downward (like the Apple TV app)
            if context.focusHeading == .down {
                if let nextView = context.nextFocusedView,
                   !nextView.isDescendant(of: selfView) {
                    return false
                }
            }

            return originalFunc(obj, selector, context)
        }

        let imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        let method = class_getInstanceMethod(UIView.self, selector)!
        let types = method_getTypeEncoding(method)!
        class_replaceMethod(cvClass, selector, imp, types)
    }

    /// Finds the sidebar's UICollectionView by looking for a narrow, left-aligned collection view
    private static func findSidebarCollectionView(in view: UIView) -> UICollectionView? {
        if let cv = view as? UICollectionView {
            let frame = cv.frame
            // Sidebar is narrow (< 500pt) and left-aligned
            if frame.origin.x == 0 && frame.width > 0 && frame.width < 500 {
                return cv
            }
        }
        for subview in view.subviews {
            if let found = findSidebarCollectionView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func checkAndShowWhatsNew() {
        guard !isAwaitingProfileSelection else { return }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let current = "\(version) (\(build))"

        if current != lastSeenBuild {
            if WhatsNewView.features(for: current) != nil {
                whatsNewVersion = current
                showWhatsNew = true
            }
            lastSeenBuild = current
        }
    }
}

// MARK: - Sidebar Profile Avatar

struct SidebarProfileAvatar: View {
    let user: PlexHomeUser?
    let size: CGFloat
    var trailingPad: CGFloat = 0

    @State private var circularImage: UIImage?

    private var totalWidth: CGFloat { size + trailingPad }

    var body: some View {
        Group {
            if let circularImage {
                Image(uiImage: circularImage)
                    .renderingMode(.original)
            } else {
                HStack(spacing: 0) {
                    placeholder
                        .frame(width: size, height: size)
                    if trailingPad > 0 {
                        Color.clear.frame(width: trailingPad)
                    }
                }
            }
        }
        .frame(width: totalWidth, height: size)
        .task(id: user?.thumb) {
            await loadCircularAvatar()
        }
    }

    private func loadCircularAvatar() async {
        guard let thumbURL = user?.thumb, let url = URL(string: thumbURL) else {
            circularImage = nil
            return
        }

        // Try loading from ImageCacheManager first, then network
        let image: UIImage?
        if let cached = await ImageCacheManager.shared.image(for: url) {
            image = cached
        } else {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let downloaded = UIImage(data: data) else {
                return
            }
            image = downloaded
        }

        guard let source = image else { return }

        // Render circular image with border (wider canvas for trailing pad)
        let canvasWidth = size + trailingPad
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasWidth, height: size))
        let circular = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let circlePath = UIBezierPath(ovalIn: rect)
            circlePath.addClip()

            // Draw image scaled to fill
            let imageSize = source.size
            let scale = max(size / imageSize.width, size / imageSize.height)
            let drawWidth = imageSize.width * scale
            let drawHeight = imageSize.height * scale
            let drawRect = CGRect(
                x: (size - drawWidth) / 2,
                y: (size - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            )
            source.draw(in: drawRect)

            // Draw subtle border
            ctx.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.15).cgColor)
            ctx.cgContext.setLineWidth(1)
            ctx.cgContext.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }

        circularImage = circular
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(profileColor.gradient)
            Text(initial)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var initial: String {
        (user?.displayName ?? "?").prefix(1).uppercased()
    }

    private var profileColor: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        guard let id = user?.id else { return .gray }
        return colors[abs(id) % colors.count]
    }
}
