//
//  MusicAudioProcessor.swift
//  Rivulet
//
//  Audio processing helpers: ReplayGain, crossfade settings, format detection.
//

import Foundation
import SwiftUI

// MARK: - Audio Quality Model

/// Describes the audio quality of a track
struct AudioQuality: Sendable {
    let codec: String
    let bitrate: Int?
    let sampleRate: Int?
    let isLossless: Bool
    let isHiRes: Bool

    /// Human-readable label for display in AudioQualityBadge
    var displayLabel: String {
        switch codec.lowercased() {
        case "flac":
            return isHiRes ? "Hi-Res FLAC" : "FLAC"
        case "alac":
            return isHiRes ? "Hi-Res ALAC" : "ALAC"
        case "aac":
            if let bitrate, bitrate >= 320 {
                return "AAC 320"
            } else if let bitrate, bitrate >= 256 {
                return "AAC \(bitrate)"
            }
            return "AAC"
        case "mp3":
            if let bitrate, bitrate >= 320 {
                return "MP3 320"
            }
            return "MP3"
        case "wav", "pcm":
            return isHiRes ? "Hi-Res WAV" : "WAV"
        case "aiff":
            return isHiRes ? "Hi-Res AIFF" : "AIFF"
        case "dsd", "dsd64", "dsd128", "dsd256":
            return "DSD"
        case "opus":
            return "Opus"
        case "vorbis", "ogg":
            return "Vorbis"
        default:
            return codec.uppercased()
        }
    }
}

// MARK: - Crossfade Duration Setting

/// User-configurable crossfade duration, persisted via AppStorage
enum CrossfadeDuration: Int, CaseIterable, CustomStringConvertible, Sendable {
    case off = 0
    case short = 2
    case medium = 5
    case long = 8
    case veryLong = 12

    var description: String {
        switch self {
        case .off: return "Off"
        case .short: return "2s"
        case .medium: return "5s"
        case .long: return "8s"
        case .veryLong: return "12s"
        }
    }

    var seconds: TimeInterval {
        TimeInterval(rawValue)
    }
}

// MARK: - Audio Processor

/// Static helpers for audio processing, format detection, and gain adjustment.
enum MusicAudioProcessor {

    /// AppStorage key for crossfade duration setting
    static let crossfadeKey = "music_crossfade_duration"

    /// Returns the current crossfade duration from UserDefaults
    static var crossfadeDuration: CrossfadeDuration {
        let rawValue = UserDefaults.standard.integer(forKey: crossfadeKey)
        return CrossfadeDuration(rawValue: rawValue) ?? .off
    }

    // MARK: - ReplayGain

    /// Adjusts volume based on codec characteristics embedded in the track.
    /// Returns a normalized volume value between 0.0 and 1.0.
    ///
    /// For now, uses a conservative loudness normalization based on codec
    /// characteristics — lossless content tends to have wider dynamic range
    /// and may need slight volume reduction. Returns 1.0 if no adjustment needed.
    static func adjustedVolume(for track: MusicTrack) -> Float {
        let codec = (track.audioCodec ?? "").lowercased()
        let isLossless = ["flac", "alac", "wav", "pcm", "aiff"].contains(codec)

        if isLossless {
            // Slight volume reduction for lossless to prevent clipping
            // when content has high dynamic range
            return 0.95
        }

        return 1.0
    }

    // MARK: - Format Detection

    /// Determines the audio quality of a track from its agnostic metadata.
    static func audioQuality(for track: MusicTrack) -> AudioQuality {
        return audioQuality(
            codec: track.audioCodec,
            bitrate: track.bitrate,
            sampleRate: track.sampleRate
        )
    }

    /// Determines audio quality from explicit codec, bitrate, and sample rate values.
    static func audioQuality(codec: String?, bitrate: Int? = nil, sampleRate: Int? = nil) -> AudioQuality {
        let codecLower = (codec ?? "unknown").lowercased()
        let losslessCodecs = ["flac", "alac", "wav", "pcm", "aiff", "dsd", "dsd64", "dsd128", "dsd256"]
        let isLossless = losslessCodecs.contains(codecLower)

        // Hi-res: lossless + sample rate above 44100Hz (CD quality)
        let isHiRes = isLossless && (sampleRate ?? 0) > 44100

        return AudioQuality(
            codec: codec ?? "unknown",
            bitrate: bitrate,
            sampleRate: sampleRate,
            isLossless: isLossless,
            isHiRes: isHiRes
        )
    }
}
