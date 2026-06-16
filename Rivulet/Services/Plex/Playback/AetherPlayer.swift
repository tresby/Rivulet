//
//  AetherPlayer.swift
//  Rivulet
//
//  PlayerProtocol-conforming adapter around AetherEngine.
//
//  Rivulet's third selectable video player, alongside RivuletPlayer
//  (custom FFmpeg+AVSampleBuffer) and AVPlayer (NativePlayerViewController
//  on .avPlayerDirect / .localRemux / .hls routes). Aether routes its
//  native path through AVPlayer too, so AetherPlayerViewController binds
//  this adapter's `currentAVPlayer` and gets the system transport bar /
//  Now Playing / AirPlay 2 picker for free.
//
//  Aether handles HDR10+ dynamic metadata preservation, HLG signaling,
//  EAC3+JOC Atmos stream-copy through MKV, and DV P5/P8.1 via dvh1+dvcC
//  in HLS-fMP4 sample entries. It does NOT handle DV P7 (drops to HDR10
//  base only) or Live TV (scaffold-level live path). Routing decisions
//  live in ContentRouter; this adapter just bridges the engine surface.
//

import AVFoundation
import Combine
import Foundation
import UIKit
import AetherEngine

@MainActor
final class AetherPlayer: PlayerProtocol {

    private let engine: AetherEngine

    private let stateSubject = CurrentValueSubject<UniversalPlaybackState, Never>(.idle)
    private let timeSubject = PassthroughSubject<TimeInterval, Never>()
    private let errorSubject = PassthroughSubject<PlayerError, Never>()
    private var cancellables = Set<AnyCancellable>()

    /// Re-publishes AetherEngine.currentAVPlayer so AetherPlayerViewController
    /// can rebind its .player on every internal Aether reload (audio-track
    /// switch / background reopen). Documented at AetherEngine.swift:1225.
    @Published private(set) var currentAVPlayer: AVPlayer?

    /// Subtitle cues bridged from AetherEngine.SubtitleCue into Rivulet's
    /// nameable AetherSubtitleCue (carries text AND bitmap bodies). Converted
    /// on the main queue in wireUpPublishers so the host overlay binds directly.
    @Published private(set) var subtitleCues: [AetherSubtitleCue] = []

    /// Subtitle renditions advertised in the generated HLS master playlist,
    /// bridged from AetherEngine.SubtitleRendition into Rivulet's nameable
    /// AetherSubtitleRenditionInfo. The host uses this to map a native-picker
    /// AVMediaSelectionOption back to the engine track index it represents.
    @Published private(set) var subtitleRenditions: [AetherSubtitleRenditionInfo] = []

    /// Mirrors engine.$isSubtitleActive. True when any subtitle track
    /// (embedded or sidecar) is selected and the engine has cue data.
    @Published private(set) var isSubtitleActive: Bool = false

    /// Source-timeline position in seconds, mirroring clock.$currentTime.
    /// Equal to currentTime on all current Aether paths (PlaybackClock
    /// unifies source-PTS and wall-clock onto a single value).
    @Published private(set) var sourceTime: Double = 0

    private var _audioTracks: [MediaTrack] = []
    private var _subtitleTracks: [MediaTrack] = []

    init() {
        do {
            self.engine = try AetherEngine()
        } catch {
            fatalError("AetherEngine init failed: \(error)")
        }
        wireUpPublishers()
    }

    private func wireUpPublishers() {
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] aetherState in
                self?.stateSubject.send(Self.translate(aetherState))
            }
            .store(in: &cancellables)

        // AetherEngine 3.x moved the high-frequency clock off the engine's
        // own objectWillChange into a separate PlaybackClock (the engine
        // does NOT fire on clock ticks). Observe clock.$currentTime.
        // Also drive sourceTime here so subtitle lookups share the same tick.
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                self?.timeSubject.send(t)
                self?.sourceTime = t
            }
            .store(in: &cancellables)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                // Convert here: each cue's type is inferred as
                // AetherEngine.SubtitleCue (it cannot be named explicitly),
                // and the body cases are pattern-matched without naming them.
                self?.subtitleCues = cues.map { cue in
                    let body: AetherSubtitleCue.Body
                    switch cue.body {
                    case .text(let string):
                        body = .text(string)
                    case .image(let image):
                        body = .image(cgImage: image.cgImage, position: image.position)
                    }
                    return AetherSubtitleCue(
                        id: cue.id,
                        startTime: cue.startTime,
                        endTime: cue.endTime,
                        body: body
                    )
                }
            }
            .store(in: &cancellables)

        // Bridge subtitle renditions: each element's type is inferred as
        // AetherEngine.SubtitleRendition (cannot be named explicitly in
        // Rivulet -- same module/class name collision as SubtitleCue).
        // Member access works on the inferred type; only the destination
        // struct name (AetherSubtitleRenditionInfo) needs to be nameable.
        engine.$subtitleRenditions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] renditions in
                self?.subtitleRenditions = renditions.map { r in
                    AetherSubtitleRenditionInfo(
                        renditionID: r.renditionID,
                        name: r.name,
                        language: r.language,
                        trackIndex: r.trackIndex
                    )
                }
            }
            .store(in: &cancellables)

        engine.$isSubtitleActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isSubtitleActive = active
            }
            .store(in: &cancellables)

        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avp in
                self?.currentAVPlayer = avp
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?._audioTracks = tracks.map(Self.translateTrack)
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?._subtitleTracks = tracks.map(Self.translateTrack)
            }
            .store(in: &cancellables)
    }

    private static func translate(_ s: PlaybackState) -> UniversalPlaybackState {
        switch s {
        case .idle: return .idle
        case .loading: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .seeking: return .buffering
        case .error(let message): return .failed(.unknown(message))
        }
    }

    private static func translateTrack(_ t: TrackInfo) -> MediaTrack {
        MediaTrack(
            id: t.id,
            name: t.name,
            language: t.language,
            languageCode: t.language,
            codec: t.codec,
            isDefault: t.isDefault,
            channels: t.channels > 0 ? t.channels : nil
        )
    }

    /// Read panel HDR state for LoadOptions.panelIsInHDRMode. Matches
    /// the post-handshake EDR detection pattern Aether 2.0 documents:
    /// `> 1.001` means the panel accepted HDR signaling.
    private static func panelIsInHDRMode() -> Bool {
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.screen })
            .first
        else { return false }
        return screen.currentEDRHeadroom > 1.001
    }

    // MARK: - PlayerProtocol state

    var isPlaying: Bool { engine.state == .playing }
    var currentTime: TimeInterval { engine.currentTime }
    var duration: TimeInterval { engine.duration }

    /// Duration updates. The engine publishes `duration` once the source is
    /// probed; the VM needs this (not just `timePublisher`) so Plex progress
    /// reports carry a real duration (viewOffset + watched threshold).
    var durationPublisher: AnyPublisher<TimeInterval, Never> {
        engine.$duration.eraseToAnyPublisher()
    }
    var bufferedTime: TimeInterval { 0 }
    var playbackRate: Float {
        get { _playbackRate }
        set {
            _playbackRate = newValue
            engine.setRate(newValue)
        }
    }
    private var _playbackRate: Float = 1.0

    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    var timePublisher: AnyPublisher<TimeInterval, Never> {
        timeSubject.eraseToAnyPublisher()
    }
    var errorPublisher: AnyPublisher<PlayerError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - Controls

    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?) async throws {
        // .lossless: FLAC encode for non-stream-copy audio (TrueHD, DTS,
        // DTS-HD MA, MP3, Opus). FLAC encode is ~3x realtime on A15 vs
        // EAC3's ~0.5x realtime, so segment production keeps up with
        // AVPlayer's HLS pipeline on high-bitrate 4K content.
        //
        // Tradeoff: needs a sink that accepts multichannel LPCM over
        // HDMI (Denon / Marantz / NAD AVRs). On AirPlay-to-HomePod or
        // stereo-LPCM-only routes the multichannel LPCM downmixes to
        // stereo, but the encode-throughput win is still worth it.
        let options = LoadOptions(
            suppressDisplayCriteria: false,
            httpHeaders: headers ?? [:],
            matchContentEnabled: true,
            panelIsInHDRMode: Self.panelIsInHDRMode(),
            audioBridgeMode: .lossless,
            advertiseSubtitleRenditions: true
        )
        do {
            try await engine.load(url: url, startPosition: startTime, options: options)
        } catch {
            let pe = PlayerError.loadFailed(String(describing: error))
            errorSubject.send(pe)
            throw pe
        }
    }

    /// Hand external metadata (title, artwork, description, genre) to the
    /// engine so AVPlayerViewController's info panel and the system Now
    /// Playing surface populate. Aether stashes these and applies them onto
    /// its internally created AVPlayerItem, replaying across internal reloads
    /// (audio-track switch, background reopen). Call BEFORE load(url:).
    ///
    /// Chapters are NOT covered: AetherEngine 3.3.0 has no navigation-marker
    /// API, so `navigationMarkerGroups` can't be injected here.
    func setExternalMetadata(_ items: [AVMetadataItem]) {
        engine.setExternalMetadata(items)
    }

    func play() { engine.play() }
    func pause() { engine.pause() }
    func stop() { engine.stop() }
    func seek(to time: TimeInterval) async { await engine.seek(to: time) }

    // MARK: - Tracks

    var audioTracks: [MediaTrack] { _audioTracks }
    var subtitleTracks: [MediaTrack] { _subtitleTracks }
    var currentAudioTrackId: Int? { engine.activeAudioTrackIndex }
    var currentSubtitleTrackId: Int? { nil }  // Aether exposes activeAudioTrackIndex but not a parallel subtitle index publisher in 2.0.0

    func selectAudioTrack(id: Int) {
        // TODO: id is currently a Plex stream ID (e.g. 753882) when called
        // from UniversalPlayerViewModel's selectAudioTrackWithoutSaving,
        // because the VM's audioTracks publishes Plex-source tracks not
        // Aether-source ones. Aether expects an AVStream index (e.g. 1).
        // Mapping requires either routing the picker through Aether's
        // own track list, or translating Plex stream order -> Aether
        // index by codec/language match. For now, no-op gracefully.
        engine.selectAudioTrack(index: id)
    }

    func selectSubtitleTrack(id: Int?) {
        if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
        }
    }

    /// Load a sidecar subtitle file (SRT, ASS, VTT, PGS) by URL.
    /// `headers` is forwarded as `httpHeaders` to AetherEngine for
    /// authenticated subtitle URLs (Plex token, CDN auth, etc.).
    func selectSidecarSubtitle(url: URL, headers: [String: String]?) {
        engine.selectSidecarSubtitle(url: url, httpHeaders: headers)
    }

    func prepareForReuse() {
        // No-op: AetherEngine doesn't have a reset-without-stop primitive.
        // stop() is called when the view model swaps players, and a fresh
        // AetherPlayer() instance is created for the next session.
    }
}
