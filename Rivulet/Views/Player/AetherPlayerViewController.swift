//
//  AetherPlayerViewController.swift
//  Rivulet
//
//  AVPlayerViewController host for the Aether route. Binds
//  `self.player` to `viewModel.aetherPlayer?.$currentAVPlayer`. Uses
//  `.sink` (NOT `.first()`) because AetherEngine swaps its underlying
//  AVPlayer instance on every internal reload (audio-track switch,
//  background reopen). The publisher re-emits with the new AVPlayer
//  each time; the host must rebind on every emission.
//
//  Documented at AetherEngine.swift:1225 — the `currentAVPlayer`
//  publisher exists specifically so AVPlayerViewController hosts can
//  rebind their .player on every Aether reload.
//

import AVKit
import Combine

class AetherPlayerViewController: BaseAVPlayerViewController {

    override func bindPlayerSpecific() {
        viewModel.$aetherPlayer
            .compactMap { $0 }
            .flatMap { $0.$currentAVPlayer }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                self?.player = avPlayer
            }
            .store(in: &cancellables)
    }
}
