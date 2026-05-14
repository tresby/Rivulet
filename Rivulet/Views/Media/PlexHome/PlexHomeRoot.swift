//
//  PlexHomeRoot.swift
//  Rivulet
//
//  Routing wrapper for the Plex Home screen. Switches between the SwiftUI
//  `PlexHomeView` and the UIKit `PlexHomeUIKitBridge` based on the
//  `homeImplementation` AppStorage toggle, set in Settings → Developer.
//
//  Both renderers read the same `PlexDataStore`, observe the same hubs,
//  and emit perf signposts tagged with `impl=swiftui|uikit` so Instruments
//  traces can be compared apples-to-apples.
//
//  Use `PlexHomeRoot()` everywhere a SwiftUI view used to render
//  `PlexHomeView()` directly.
//

import SwiftUI

struct PlexHomeRoot: View {
    @AppStorage(HomeImplPreference.storageKey) private var implRaw: String = HomeImpl.swiftui.rawValue

    var body: some View {
        let impl = HomeImpl(rawValue: implRaw) ?? .swiftui
        ZStack {
            switch impl {
            case .swiftui:
                PlexHomeView()
                    .onAppear { Task { @MainActor in PerfLog.activeImpl = .swiftui } }
            case .uikit:
                PlexHomeUIKitBridge()
                    .ignoresSafeArea()
            }
        }
    }
}
