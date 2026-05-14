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
