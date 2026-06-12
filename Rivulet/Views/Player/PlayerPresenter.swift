//
//  PlayerPresenter.swift
//  Rivulet
//
//  Single source of truth for picking the right presentation host based
//  on the user's PlayerPreference. Replaces the 9 ad-hoc
//  `if useApplePlayer` forks scattered across ContentView, MediaDetailView,
//  PlexHomeViewController, PlexHomeView, PlexLibraryView, TVSidebarView,
//  and the playback test harness with a single place to choose between:
//
//    - .rivulet -> UniversalPlayerView (custom SwiftUI overlay) inside
//      PlayerContainerViewController.
//    - .apple   -> NativePlayerViewController (AVPlayerViewController
//      subclass binding viewModel.$player).
//    - .aether  -> AetherPlayerViewController (AVPlayerViewController
//      subclass binding viewModel.aetherPlayer?.$currentAVPlayer).
//

import SwiftUI
import UIKit

@MainActor
enum PlayerPresenter {

    /// Build the UIViewController to present for the given playback
    /// session, picking the host based on the current PlayerPreference.
    /// The view model is shared between hosts; only the presentation
    /// surface differs.
    static func makeViewController(
        viewModel: UniversalPlayerViewModel,
        onDismiss: (() -> Void)? = nil
    ) -> UIViewController {
        switch PlayerPreference.current {
        case .apple:
            let vc = NativePlayerViewController(viewModel: viewModel)
            vc.onDismiss = onDismiss
            return vc

        case .aether:
            let vc = AetherPlayerViewController(viewModel: viewModel)
            vc.onDismiss = onDismiss
            return vc
        }
    }
}
