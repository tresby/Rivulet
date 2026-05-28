//
//  HomeImplPreference.swift
//  Rivulet
//
//  AppStorage-backed toggle for selecting which Plex Home implementation
//  renders. Used by the perf comparison spike on the
//  `perf-tvuikit-spike` branch. Settings UI exposes this as "Home page
//  implementation" in Developer Tools (or whatever debug surface it ends
//  up plumbed into).
//
//  The two values map to:
//    - .swiftui → existing SwiftUI `PlexHomeView`
//    - .uikit   → `PlexHomeUIKitBridge` wrapping `PlexHomeViewController`
//
//  Both versions read the same `PlexDataStore`, render the same hubs,
//  and emit the same `os_signpost` events tagged with `impl=...`. Switch
//  via the debug toggle and Settings → restart-not-required: the SwiftUI
//  shell observes the AppStorage and rebuilds its body.
//

import Foundation
import SwiftUI

enum HomeImplPreference {
    static let storageKey = "homeImplementation"

    static var current: HomeImpl {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? HomeImpl.swiftui.rawValue
        return HomeImpl(rawValue: raw) ?? .swiftui
    }

    static func set(_ impl: HomeImpl) {
        UserDefaults.standard.set(impl.rawValue, forKey: storageKey)
    }
}

/// AppStorage-backed toggle for the UIKit preview-carousel rewrite.
/// Independent of `HomeImplPreference` — you can run the UIKit Home
/// with the SwiftUI carousel, or the SwiftUI Home with the UIKit
/// carousel, in any combination. Used for the perf comparison spike.
enum PreviewImplPreference {
    static let storageKey = "previewImplementation"

    enum Impl: String, Sendable {
        case swiftui
        case uikit
    }

    static var current: Impl {
        // Default flipped to .uikit for perf-spike active iteration.
        // Flip back to .swiftui before any PR ships.
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? Impl.uikit.rawValue
        return Impl(rawValue: raw) ?? .uikit
    }

    static func set(_ impl: Impl) {
        UserDefaults.standard.set(impl.rawValue, forKey: storageKey)
    }
}

/// Perf-spike auto-scroll mode. When on, the home view (whichever impl)
/// runs a deterministic scroll sequence on first appear: vertical scroll
/// from top to bottom over ~5 seconds, then horizontal scroll within the
/// first hub. Used by `Scripts/perf_compare.sh` to capture scroll FPS
/// without manual remote input.
enum PerfAutoScroll {
    static let storageKey = "perfAutoScrollEnabled"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }
}

