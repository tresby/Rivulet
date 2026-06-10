//
//  PlexHomeRoot.swift
//  Rivulet
//
//  Routing wrapper for the Plex Home screen. Switches between the SwiftUI
//  `PlexHomeView` and the UIKit `PlexHomeUIKitBridge` based on the
//  `homeImplementation` AppStorage toggle. The UIKit branch wraps its
//  controller in a NavigationStack so tile taps still navigate via
//  SwiftUI's stack to `MediaDetailView` / music routers.
//
//  Both renderers read the same `PlexDataStore`, observe the same hubs,
//  and emit perf signposts tagged with `impl=swiftui|uikit` so Instruments
//  traces can be compared apples-to-apples.
//

import SwiftUI

struct PlexHomeRoot: View {
    var body: some View {
        // Committed to the UIKit/TVUIKit home; the SwiftUI PlexHomeView is retired.
        UIKitHomeContainer()
            .onAppear { Task { @MainActor in PerfLog.activeImpl = .uikit } }
    }
}

/// SwiftUI shell that owns the NavigationStack + selection bindings for
/// the UIKit home. The UIKit controller forwards selections via callbacks
/// which flip the bindings here, and the stack pushes the matching
/// destination view exactly like the SwiftUI home does.
///
/// Also mirrors the SwiftUI home's `nestedNavigationState.isNested` plumb:
/// the sidebar reads this flag to hide its tab bar while a detail view is
/// on top, so the UIKit home must update it the same way the SwiftUI home
/// does (`onChange(of: selectedItem)` in `PlexHomeView`).
private struct UIKitHomeContainer: View {
    @State private var selectedItem: MediaItem?
    @State private var selectedMusicItem: PlexMetadata?
    @Environment(\.nestedNavigationState) private var nestedNavState

    var body: some View {
        NavigationStack {
            PlexHomeUIKitBridge(selectedItem: $selectedItem, selectedMusicItem: $selectedMusicItem)
                .ignoresSafeArea()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $selectedItem) { item in
                    MediaDetailView(item: item)
                }
                .navigationDestination(item: $selectedMusicItem) { meta in
                    switch meta.type {
                    case "artist": MusicSearchDetailRouter(plexMeta: meta, kind: .artist)
                    case "album": MusicSearchDetailRouter(plexMeta: meta, kind: .album)
                    default: EmptyView()
                    }
                }
        }
        .onChange(of: selectedItem) { _, newValue in
            nestedNavState.isNested = newValue != nil || selectedMusicItem != nil
        }
        .onChange(of: selectedMusicItem) { _, newValue in
            nestedNavState.isNested = newValue != nil || selectedItem != nil
        }
    }
}
