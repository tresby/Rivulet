//
//  AppRestartCoordinator.swift
//  Rivulet
//
//  Drives an in-process "soft restart" of the sidebar shell. Bumping `token`
//  recreates `TVSidebarView` from scratch (via `.id(token)` in ContentView), so
//  the `.sidebarAdaptable` sidebar is rebuilt with the current library / Live-TV
//  set in a launch-like context.
//
//  This is how sidebar/library changes are applied without the tab-set-mutation
//  focus wedge: the sidebar is never mutated in place (that corrupts its focus
//  for the session) — it is rebuilt. App singletons (auth, data, caches) persist
//  across the swap, so the rebuild is near-instant with no re-login or re-fetch.
//

import SwiftUI
import Combine

@MainActor
final class AppRestartCoordinator: ObservableObject {
    static let shared = AppRestartCoordinator()
    private init() {}

    /// Identity for `TVSidebarView`. Each bump recreates the whole shell.
    @Published var token = 0
    /// Covers the brief rebuild so no press lands mid-swap and the flash is hidden.
    @Published var isRestarting = false

    func softRestart() {
        isRestarting = true
        // Build a fresh home on the rebuilt shell (the cached singleton renders
        // stale when reparented into the new tree).
        PlexHomeUIKitBridge.resetSharedHome()
        // Re-filter the home rows for the current library visibility. `homeItems`
        // is a cached projection that `loadHubsIfNeeded` won't rebuild once
        // populated, so the fresh home would otherwise show the old library set.
        PlexDataStore.shared.projectHomeItems()
        token &+= 1
        // Keep the cover up until the fresh home signals it has painted (and
        // self-landed focus), so the rebuild happens entirely behind the blip.
        // Fallback so the cover always lifts even if that signal never arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.finishRestart()
        }
    }

    /// Called by the freshly-rebuilt home once it has painted its first content,
    /// so the cover lifts exactly when the rebuild is visible-ready (no guess).
    /// A no-op outside a restart.
    func notifyHomePainted() {
        finishRestart()
    }

    private func finishRestart() {
        guard isRestarting else { return }
        isRestarting = false
    }
}
