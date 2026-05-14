//
//  PlexHomeUIKitBridge.swift
//  Rivulet
//
//  SwiftUI bridge to host `PlexHomeViewController` (UIKit/TVUIKit home)
//  inside the existing SwiftUI navigation shell. Only used when the
//  user has flipped the perf-spike toggle (see HomeImplPreference).
//
//  Wraps the entire UIKit home in a single representable; the surrounding
//  SwiftUI navigation, sidebar, etc. continue to work normally.
//

import SwiftUI
import UIKit

struct PlexHomeUIKitBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PlexHomeViewController {
        // Tag perf signposts so traces filter correctly when this bridge
        // is on screen.
        Task { @MainActor in PerfLog.activeImpl = .uikit }
        return PlexHomeViewController()
    }

    func updateUIViewController(_ uiViewController: PlexHomeViewController, context: Context) {
        // No SwiftUI state flows in; the controller observes PlexDataStore
        // directly via Combine.
    }
}
