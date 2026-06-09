//
//  MediaLibraryView.swift
//  Rivulet
//
//  SwiftUI host for MediaLibraryViewController.
//  Mirrors PlexHomeUIKitBridge but simpler: no navigation bindings.
//  onSelectItem wiring is deferred — a later task handles it.
//

import SwiftUI
import UIKit

struct MediaLibraryView: UIViewControllerRepresentable {
    let libraryKey: String
    let libraryTitle: String

    func makeUIViewController(context: Context) -> MediaLibraryViewController {
        // primaryProvider is guaranteed non-nil by the call-site gate.
        let provider = MediaProviderRegistry.shared.primaryProvider!
        let library = MediaLibrary(
            id: libraryKey,
            providerID: provider.id,
            title: libraryTitle,
            kind: .mixed
        )
        return MediaLibraryViewController(provider: provider, library: library, config: .init())
    }

    func updateUIViewController(_ vc: MediaLibraryViewController, context: Context) { }
}
