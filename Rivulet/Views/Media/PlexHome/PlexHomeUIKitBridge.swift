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
    @Binding var selectedItem: MediaItem?
    @Binding var selectedMusicItem: PlexMetadata?

    final class Coordinator {
        var selectedItem: Binding<MediaItem?>
        var selectedMusicItem: Binding<PlexMetadata?>
        init(selectedItem: Binding<MediaItem?>, selectedMusicItem: Binding<PlexMetadata?>) {
            self.selectedItem = selectedItem
            self.selectedMusicItem = selectedMusicItem
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedItem: $selectedItem, selectedMusicItem: $selectedMusicItem)
    }

    func makeUIViewController(context: Context) -> PlexHomeViewController {
        Task { @MainActor in PerfLog.activeImpl = .uikit }
        let vc = PlexHomeViewController()
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
    }
}
