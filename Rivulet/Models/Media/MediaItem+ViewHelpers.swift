//
//  MediaItem+ViewHelpers.swift
//  Rivulet
//
//  Convenience computed properties used by views that display episode/season
//  cards. These are pure derivations from the fields already on MediaItem;
//  no network calls, no backend knowledge.
//

import Foundation

extension MediaItem {
    // MARK: - Watch State Helpers

    /// True when the item has been started but not finished.
    var isInProgress: Bool {
        guard let runtime, runtime > 0 else { return false }
        let offset = userState.viewOffset
        guard offset > 0 else { return false }
        let progress = offset / runtime
        return progress < 0.98
    }

    /// True when the item has been fully watched (isPlayed flag from provider).
    var isWatched: Bool { userState.isPlayed }

    /// Fractional watch progress [0, 1], or nil if not started.
    var watchProgress: Double? {
        guard let runtime, runtime > 0 else { return nil }
        let offset = userState.viewOffset
        guard offset > 0 else { return nil }
        return min(1.0, offset / runtime)
    }

    // MARK: - Formatting

    /// Human-readable duration derived from `runtime` (seconds).
    var durationFormatted: String? {
        guard let runtime else { return nil }
        let totalMinutes = Int(runtime / 60)
        guard totalMinutes > 0 else { return nil }
        if totalMinutes >= 60 {
            let h = totalMinutes / 60
            let m = totalMinutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(totalMinutes)m"
    }

    /// "S01E03"-style label for episodes; nil for non-episodes.
    var episodeString: String? {
        guard kind == .episode,
              let s = seasonNumber,
              let e = episodeNumber else { return nil }
        return "S\(String(format: "%02d", s))E\(String(format: "%02d", e))"
    }
}
