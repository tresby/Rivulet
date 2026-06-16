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
//  Documented at AetherEngine.swift:1225 -- the `currentAVPlayer`
//  publisher exists specifically so AVPlayerViewController hosts can
//  rebind their .player on every Aether reload.
//
//  Subtitle overlay
//  ----------------
//  AetherSubtitleOverlayView is hosted via a retained UIHostingController
//  child VC whose view is added to `contentOverlayView` (above video,
//  below AVKit's transport bar). This is the correct mount point for
//  overlays that must coexist with AVKit's native controls; Sodalite mounts
//  in self.view because it suppresses AVKit chrome -- we do not.
//
//  Live restyle: CaptionAppearance.changedNotification triggers a rootView
//  rebuild with a fresh CaptionAppearance.current() style. rootView is
//  replaced wholesale (all three params at once) so SwiftUI diffing sees a
//  clean value update.
//

import AVKit
import Combine
import SwiftUI

class AetherPlayerViewController: BaseAVPlayerViewController {

    // MARK: - Subtitle state

    /// Drives the subtitle overlay. Fed from AetherPlayer publishers.
    private let subtitleModel = AetherSubtitleModel()

    /// Retained hosting controller. Must be retained as a child VC;
    /// releasing it while its view is attached causes layout to die.
    private var subtitleHostingController: UIHostingController<AetherSubtitleOverlayView>?

    /// Current caption style. Replaced on CaptionAppearance.changedNotification.
    private var captionStyle: CaptionStyle = CaptionAppearance.current()

    /// Whether AVKit's transport bar is currently visible.
    /// AVPlayerViewController does not expose a public publisher for this,
    /// so we track it via the `showsPlaybackControls` observed property and
    /// assume visible initially (conservative: more bottom padding at start).
    private var controlsVisible: Bool = true

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        mountSubtitleOverlay()
        observeControlsVisibility()
        observeCaptionAppearance()
    }

    // MARK: - Overlay mounting

    /// Adds AetherSubtitleOverlayView as a child VC in contentOverlayView.
    ///
    /// Per the tvOS UIKit rules (research/viewcontrollers-presentation.md):
    ///   addChild -> addSubview + constraints/autoresizingMask -> didMove(toParent:)
    ///
    /// contentOverlayView is always non-nil after viewDidLoad has run on
    /// AVPlayerViewController (it is created as part of the player view hierarchy).
    /// We fall back to view if it were somehow nil, but that should never occur.
    private func mountSubtitleOverlay() {
        let overlayView = AetherSubtitleOverlayView(
            model: subtitleModel,
            style: captionStyle,
            controlsVisible: controlsVisible
        )
        let hosting = UIHostingController(rootView: overlayView)
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false

        // Proper containment order per UIKit containment contract.
        addChild(hosting)
        let container = contentOverlayView ?? view!
        container.addSubview(hosting.view)
        hosting.view.frame = container.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.didMove(toParent: self)

        subtitleHostingController = hosting
    }

    // MARK: - Caption appearance

    private func observeCaptionAppearance() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captionAppearanceDidChange),
            name: CaptionAppearance.changedNotification,
            object: nil
        )
    }

    @objc private func captionAppearanceDidChange() {
        captionStyle = CaptionAppearance.current()
        rebuildOverlayRootView()
    }

    // MARK: - Controls visibility

    /// AVPlayerViewController exposes no delegate or publisher for transport bar
    /// visibility. We observe `showsPlaybackControls` via KVO so we can lift the
    /// subtitle text above the bar when it appears.
    private var controlsObservation: NSKeyValueObservation?

    private func observeControlsVisibility() {
        controlsObservation = observe(\.showsPlaybackControls, options: [.initial, .new]) { [weak self] _, change in
            guard let self else { return }
            let visible = change.newValue ?? self.showsPlaybackControls
            // Dispatch to main in case KVO fires on a non-main queue (rare but possible).
            DispatchQueue.main.async {
                self.controlsVisible = visible
                self.rebuildOverlayRootView()
            }
        }
    }

    // MARK: - rootView rebuild

    private func rebuildOverlayRootView() {
        subtitleHostingController?.rootView = AetherSubtitleOverlayView(
            model: subtitleModel,
            style: captionStyle,
            controlsVisible: controlsVisible
        )
    }

    // MARK: - Player binding

    override func bindPlayerSpecific() {
        // Bind AVPlayer instance (existing behavior).
        viewModel.$aetherPlayer
            .compactMap { $0 }
            .flatMap { $0.$currentAVPlayer }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                self?.player = avPlayer
            }
            .store(in: &cancellables)

        // Feed cue list into the subtitle model.
        viewModel.$aetherPlayer
            .compactMap { $0 }
            .flatMap { $0.$subtitleCues }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                self?.subtitleModel.update(cues: cues)
            }
            .store(in: &cancellables)

        // Feed source time into the subtitle model (drives activeCues lookup).
        viewModel.$aetherPlayer
            .compactMap { $0 }
            .flatMap { $0.$sourceTime }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.subtitleModel.sourceTime = time
            }
            .store(in: &cancellables)
    }
}
