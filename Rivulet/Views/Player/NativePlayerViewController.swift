//
//  NativePlayerViewController.swift
//  Rivulet
//
//  Host for AVPlayer-direct / localRemux / HLS routes. Binds
//  `self.player` to `viewModel.$player` (single AVPlayer that the
//  view model constructs once for the session, no internal reloads).
//
//  Shares transport bar, skip-button, progress reporting, and
//  dismissal with AetherPlayerViewController via BaseAVPlayerViewController.
//

import AVKit
import Combine

class NativePlayerViewController: BaseAVPlayerViewController {

    override func bindPlayerSpecific() {
        viewModel.$player
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                self?.player = avPlayer
            }
            .store(in: &cancellables)
    }
}
