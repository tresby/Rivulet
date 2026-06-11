//
//  PlexHomeUIKitBridge.swift
//  Rivulet
//
//  SwiftUI bridge to host `PlexHomeViewController` (UIKit/TVUIKit home).
//  Forwards tile selections back to SwiftUI bindings so the surrounding
//  NavigationStack pushes `MediaDetailView` / music routers like the
//  SwiftUI home does.
//

import SwiftUI
import UIKit

struct PlexHomeUIKitBridge: UIViewControllerRepresentable {
    /// Surface to render: .home (default) or .library(key:title:). Fixed for
    /// the lifetime of the hosted controller — library call sites must `.id`
    /// the container by library key so a key change rebuilds the VC.
    var mode: HomeMode = .home
    @Binding var selectedItem: MediaItem?
    @Binding var selectedMusicItem: PlexMetadata?
    /// Search mode only: the live `.searchable` query text, pushed into the
    /// controller on every SwiftUI update; and a monotonically-increasing
    /// submit counter (keyboard Search key) that triggers an immediate search.
    var searchQuery: String = ""
    var searchSubmitCount: Int = 0
    /// Search mode only: mirror controller-driven query changes (recents
    /// pills) back into the `.searchable` field.
    var searchQueryBinding: Binding<String>? = nil

    final class Coordinator {
        var selectedItem: Binding<MediaItem?>
        var selectedMusicItem: Binding<PlexMetadata?>
        var lastSearchSubmitCount = 0
        init(selectedItem: Binding<MediaItem?>, selectedMusicItem: Binding<PlexMetadata?>) {
            self.selectedItem = selectedItem
            self.selectedMusicItem = selectedMusicItem
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedItem: $selectedItem, selectedMusicItem: $selectedMusicItem)
    }

    /// The single shared HOME controller. SwiftUI identity churn during
    /// launch (state flips re-evaluating the tab tree) was discarding the
    /// representable and calling make again ~1s in — TWO full home VCs each
    /// fetching, observing, and applying 5s snapshots through the whole
    /// launch window. The home is a singleton surface for the app's
    /// lifetime, so the bridge hands every make the SAME instance (UIKit
    /// reparents the view to the newest host automatically). Library mode is
    /// NOT cached: each library gets a fresh controller via .id(key).
    @MainActor private static var sharedHomeVC: PlexHomeViewController?

    func makeUIViewController(context: Context) -> PlexHomeViewController {
        if case .library = mode { StartupTimer.mark("bridge.makeUIViewController (library)") }
        else { StartupTimer.mark("bridge.makeUIViewController (home)") }
        Task { @MainActor in PerfLog.activeImpl = .uikit }

        let vc: PlexHomeViewController
        if case .home = mode {
            if let shared = Self.sharedHomeVC {
                StartupTimer.mark("bridge reusing shared home VC")
                vc = shared
            } else {
                vc = PlexHomeViewController(mode: mode)
                Self.sharedHomeVC = vc
            }
        } else {
            vc = PlexHomeViewController(mode: mode)
        }

        vc.onSelectItem = { item in
            context.coordinator.selectedItem.wrappedValue = item
        }
        vc.onSelectMusic = { meta in
            context.coordinator.selectedMusicItem.wrappedValue = meta
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: PlexHomeViewController, context: Context) {
        // Refresh the callbacks to capture the latest bindings.
        uiViewController.onSelectItem = { item in
            context.coordinator.selectedItem.wrappedValue = item
        }
        uiViewController.onSelectMusic = { meta in
            context.coordinator.selectedMusicItem.wrappedValue = meta
        }
        if case .search = mode {
            if let binding = searchQueryBinding {
                uiViewController.onSearchQueryChangedByController = { query in
                    binding.wrappedValue = query
                }
            }
            uiViewController.updateSearchQuery(searchQuery)
            if searchSubmitCount != context.coordinator.lastSearchSubmitCount {
                context.coordinator.lastSearchSubmitCount = searchSubmitCount
                uiViewController.submitSearch()
            }
        }
    }
}
