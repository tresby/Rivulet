import Foundation
import Combine

// MARK: - AetherSubtitleModel

/// Manages the active-cue set for an Aether-driven subtitle overlay.
///
/// Callers feed this model the current source time and the full cue list
/// from AetherPlayer; the model handles binary-search lookup plus the
/// optional display delay that lets users nudge subtitle timing.
///
/// Operates on `AetherSubtitleCue` (Rivulet's bridge type, carrying text AND
/// bitmap bodies), not Rivulet's text-only RPlayer `SubtitleCue`, so the
/// overlay can render PGS/DVB bitmap subtitles too.
@MainActor
final class AetherSubtitleModel: ObservableObject {

    // MARK: - Published state

    /// Full sorted cue list. Set via update(cues:).
    @Published var cues: [AetherSubtitleCue] = []

    /// Current source-timeline position in seconds, mirroring AetherPlayer.sourceTime.
    @Published var sourceTime: Double = 0

    /// Subtitle display delay in seconds. Positive values shift subtitles earlier
    /// (reduce effective time), negative values shift later.
    @Published var delaySeconds: Double = 0

    // MARK: - Derived

    /// Maximum cue duration observed in the current cue list, rounded up to
    /// the next whole second, with a minimum of 6 seconds.
    ///
    /// Used by activeCues as the backward-walk window: a binary search lands
    /// on the last cue whose startTime <= t, then the walk goes back until
    /// startTime < t - maxCueDuration. This bounds the scan to a constant
    /// number of cues regardless of list length.
    private(set) var maxCueDuration: Double = 6

    // MARK: - Mutation

    /// Replace the cue list and recompute maxCueDuration.
    ///
    /// Cues must arrive sorted by startTime ascending (AetherEngine guarantees this).
    /// If they aren't, the binary search in activeCues will produce wrong results.
    func update(cues: [AetherSubtitleCue]) {
        self.cues = cues
        recomputeMaxDuration()
    }

    private func recomputeMaxDuration() {
        guard !cues.isEmpty else {
            maxCueDuration = 6
            return
        }
        let maxRaw = cues.reduce(0.0) { acc, cue in
            max(acc, cue.endTime - cue.startTime)
        }
        maxCueDuration = max(maxRaw.rounded(.up), 6)
    }

    // MARK: - Active cue lookup

    /// Cues active at the current effective playback time.
    ///
    /// Effective time = sourceTime - delaySeconds.
    ///
    /// A cue is active when startTime <= t AND endTime >= t (both ends inclusive).
    ///
    /// Algorithm:
    /// 1. Binary search for the rightmost cue with startTime <= t.
    /// 2. Walk leftward as long as startTime > t - maxCueDuration.
    /// 3. Include cues whose endTime >= t.
    ///
    /// This is O(log n + k) where k is the number of active cues (typically 1-3).
    var activeCues: [AetherSubtitleCue] {
        let t = sourceTime - delaySeconds
        guard !cues.isEmpty else { return [] }

        // Binary search: find rightmost index where startTime <= t.
        var lo = 0
        var hi = cues.count - 1
        var pivot = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].startTime <= t {
                pivot = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        guard pivot >= 0 else { return [] }

        // Walk left within the maxCueDuration window.
        let windowStart = t - maxCueDuration
        var result: [AetherSubtitleCue] = []
        var i = pivot
        while i >= 0 && cues[i].startTime > windowStart {
            let cue = cues[i]
            if cue.startTime <= t && cue.endTime >= t {
                result.append(cue)
            }
            i -= 1
        }

        // Result was collected right-to-left; reverse to restore startTime order.
        return result.reversed()
    }
}
