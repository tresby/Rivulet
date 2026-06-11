//
//  BaseAVPlayerViewController.swift
//  Rivulet
//
//  Shared AVPlayerViewController behavior for both NativePlayerViewController
//  (binds viewModel.$player for AVPlayer-direct / localRemux / HLS routes)
//  and AetherPlayerViewController (binds viewModel.aetherPlayer?.$currentAVPlayer
//  for the Aether route). The two subclasses differ only in which publisher
//  drives `self.player`; everything else (skip button, progress reporting,
//  dismissal, Now Playing) is identical.
//
//  Now Playing comes from AVPlayerViewController natively. Do NOT attach
//  NowPlayingService here.
//

import AVKit
import Combine

class BaseAVPlayerViewController: AVPlayerViewController {

    let viewModel: UniversalPlayerViewModel
    var cancellables = Set<AnyCancellable>()
    private var progressTimer: Timer?
    private var lastReportedTime: TimeInterval = -1
    var onDismiss: (() -> Void)?

    init(viewModel: UniversalPlayerViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindContextualActions()
        bindPlayerSpecific()
    }

    /// Override to bind `self.player` to the correct publisher for this
    /// route. Must call `.sink` (not `.first()`) for the Aether case, since
    /// AetherEngine swaps its underlying AVPlayer instance on every
    /// internal reload (audio-track switch, background reopen). The
    /// AVPlayer-direct case can use `.first()` because that path constructs
    /// a single AVPlayer and never re-emits.
    func bindPlayerSpecific() {
        fatalError("Subclasses must override bindPlayerSpecific()")
    }

    private func bindContextualActions() {
        viewModel.$activeMarker
            .receive(on: DispatchQueue.main)
            .sink { [weak self] marker in
                guard let self else { return }
                if marker != nil {
                    let label = self.viewModel.skipButtonLabel
                    self.contextualActions = [
                        UIAction(title: label, image: UIImage(systemName: "forward.fill")) { [weak self] _ in
                            guard let self else { return }
                            Task { await self.viewModel.skipActiveMarker() }
                        }
                    ]
                } else {
                    self.contextualActions = []
                }
            }
            .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        NotificationCenter.default.post(name: .plexPlaybackStarted, object: nil)

        Task { @MainActor in
            await viewModel.startPlayback()
        }

        startProgressReporting()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        if isBeingDismissed || isMovingFromParent {
            stopProgressReporting()
            reportFinalProgress()
            NotificationCenter.default.post(name: .plexPlaybackStopped, object: nil)
            viewModel.stopPlayback()
            onDismiss?()
        }
    }

    // MARK: - Plex Progress Reporting

    private func startProgressReporting() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.reportCurrentProgress()
        }
    }

    private func stopProgressReporting() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func reportCurrentProgress() {
        let time = viewModel.currentTime
        guard abs(time - lastReportedTime) >= 5 else { return }
        lastReportedTime = time

        let ratingKey = viewModel.metadata.ratingKey ?? ""
        let duration = viewModel.duration
        let state = viewModel.isPlaying ? "playing" : "paused"

        Task {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: ratingKey,
                time: time,
                duration: duration,
                state: state
            )
        }
    }

    private func reportFinalProgress() {
        let ratingKey = viewModel.metadata.ratingKey ?? ""
        let time = viewModel.currentTime
        let duration = viewModel.duration

        Task {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: ratingKey,
                time: time,
                duration: duration,
                state: "stopped",
                forceReport: true
            )

            if duration > 0 && time / duration > 0.9 {
                await PlexProgressReporter.shared.markAsWatched(ratingKey: ratingKey)
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)

            await MainActor.run {
                NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            }
        }
    }
}
