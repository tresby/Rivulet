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
//  Native picker observation
//  -------------------------
//  When advertiseSubtitleRenditions is on, each subtitle track appears as a
//  decoy WebVTT rendition in AVKit's Subtitles menu. A 0.3 s periodic timer
//  polls currentMediaSelection on the current AVPlayerItem; on change it maps
//  the selected AVMediaSelectionOption to an AetherEngine track index (via
//  aetherPlayer.subtitleRenditions) and calls aetherPlayer.selectSubtitleTrack.
//  The timer is invalidated and re-armed whenever the bound AVPlayer changes
//  (Aether reloads the item on audio-track switch / background reopen).
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

    // MARK: - Native picker observation

    /// The legible AVMediaSelectionGroup for the current item.
    /// Loaded once per AVPlayer binding and reset on teardown.
    private var legibleGroup: AVMediaSelectionGroup?

    /// Last AVMediaSelectionOption seen from the picker poll. Identity
    /// comparison (===) detects changes without a slow isEqual.
    private var lastSeenOption: AVMediaSelectionOption?

    /// Timer that polls currentMediaSelection at 0.3 s intervals.
    private var pickerPollTimer: Timer?

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
        // Bind AVPlayer instance (existing behavior). Re-arm the picker
        // poll timer on every AVPlayer swap so we track the fresh item.
        viewModel.$aetherPlayer
            .compactMap { $0 }
            .flatMap { $0.$currentAVPlayer }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                self?.player = avPlayer
                self?.rebindPickerObservation(for: avPlayer)
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

    // MARK: - Native picker observation (subtitle track routing)

    /// Called whenever the bound AVPlayer changes. Tears down the previous
    /// poll timer, loads the legible group for the new item, and arms a
    /// fresh timer.
    private func rebindPickerObservation(for avPlayer: AVPlayer?) {
        stopPickerPollTimer()
        legibleGroup = nil
        lastSeenOption = nil

        guard let avPlayer else { return }

        // Load the legible group asynchronously. AVPlayerItem.asset is
        // already probed by Aether before currentAVPlayer is published, so
        // the load typically resolves immediately. The timer is armed inside
        // the continuation so it only polls once the group is ready.
        Task { [weak self, weak avPlayer] in
            guard let item = avPlayer?.currentItem else { return }

            let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.legibleGroup = group
                if group != nil {
                    self.startPickerPollTimer()
                }
            }
        }
    }

    private func startPickerPollTimer() {
        pickerPollTimer?.invalidate()
        pickerPollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollPickerSelection()
        }
    }

    private func stopPickerPollTimer() {
        pickerPollTimer?.invalidate()
        pickerPollTimer = nil
    }

    /// Reads the current legible selection and, if it changed since last poll,
    /// routes the new selection to the Aether engine.
    private func pollPickerSelection() {
        guard
            let group = legibleGroup,
            let item = player?.currentItem
        else { return }

        let selected = item.currentMediaSelection.selectedMediaOption(in: group)

        // Identity comparison: AVKit vends the same option object for the same
        // selection; a pointer change reliably signals a user action.
        guard selected !== lastSeenOption else { return }
        lastSeenOption = selected

        if let option = selected {
            if let idx = aetherTrackIndex(for: option, in: group) {
                viewModel.aetherPlayer?.selectSubtitleTrack(id: idx)
            }
            // If no mapping found, leave the engine selection unchanged.
        } else {
            // User chose "Off".
            viewModel.aetherPlayer?.selectSubtitleTrack(id: nil)
        }
    }

    /// Maps an AVMediaSelectionOption from the native picker to the
    /// AetherEngine track index it represents.
    ///
    /// Match priority:
    ///   1. language + display name (most precise)
    ///   2. language only (handles renamed renditions)
    ///   3. ordinal position within legibleGroup.options (last resort)
    ///
    /// Returns the `trackIndex` field from the matched rendition.
    private func aetherTrackIndex(for option: AVMediaSelectionOption, in group: AVMediaSelectionGroup) -> Int? {
        let renditions = viewModel.aetherPlayer?.subtitleRenditions ?? []
        guard !renditions.isEmpty else { return nil }

        let optLang = option.extendedLanguageTag ?? ""
        let optName = option.displayName

        // 1. Language + name match.
        if let r = renditions.first(where: { $0.language == optLang && $0.name == optName }) {
            return r.trackIndex
        }

        // 2. Language-only match.
        if let r = renditions.first(where: { $0.language == optLang }) {
            return r.trackIndex
        }

        // 3. Ordinal: the index of this option within the legible group maps
        //    to the same index in renditions (Aether inserts renditions in
        //    track order, and AVKit lists them in playlist order).
        if let ordinal = group.options.firstIndex(of: option),
           ordinal < renditions.count {
            return renditions[ordinal].trackIndex
        }

        return nil
    }

    // No deinit needed: pickerPollTimer uses [weak self] so it won't
    // retain this VC. stopPickerPollTimer() is called by rebindPickerObservation
    // on every AVPlayer swap, and on VC teardown AVKit's own cleanup nilifies
    // self.player which stops the item -- the timer fires and returns early.
    // If explicit pre-teardown cleanup is ever needed, call stopPickerPollTimer()
    // from viewDidDisappear before calling super.
}
