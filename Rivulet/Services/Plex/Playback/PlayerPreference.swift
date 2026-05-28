//
//  PlayerPreference.swift
//  Rivulet
//
//  User-selectable video player engine. Stored in UserDefaults with
//  a migration from the legacy `useApplePlayer` Bool. Surfaced as a
//  3-way picker in Settings.
//
//  - .rivulet (default): RivuletPlayer (custom FFmpeg + AVSampleBuffer).
//    Best for DV P7 sources and Live TV. The Rivulet baseline.
//  - .apple: AVPlayer paths (avPlayerDirect / localRemux / HLS). The
//    pre-existing "Use Apple's Player" mode.
//  - .aether: AetherEngine. Native HDR10+, HLG, EAC3+JOC Atmos via
//    AVPlayerViewController. Falls back to RPlayer for DV P7 / Live TV /
//    SW-path codecs (AV1 / VP9 / legacy).
//

import Foundation

enum PlayerPreference: String, CaseIterable, Sendable {
    case rivulet
    case apple
    case aether

    /// UserDefaults key for the new 3-way preference.
    static let userDefaultsKey = "playerPreference"

    /// Legacy UserDefaults key (Bool). Read once on migration, then
    /// the new key takes over. We do NOT delete the legacy key so a
    /// downgrade to a pre-Aether build still reads the user's choice.
    static let legacyKey = "useApplePlayer"

    /// Read the current preference, migrating from the legacy Bool key
    /// if needed. Writes the migrated value back to the new key so
    /// subsequent reads short-circuit.
    static var current: PlayerPreference {
        let ud = UserDefaults.standard

        // New key takes precedence if set.
        if let raw = ud.string(forKey: userDefaultsKey),
           let pref = PlayerPreference(rawValue: raw) {
            return pref
        }

        // Migrate from legacy Bool on first read.
        if ud.object(forKey: legacyKey) != nil {
            let useApple = ud.bool(forKey: legacyKey)
            let migrated: PlayerPreference = useApple ? .apple : .rivulet
            ud.set(migrated.rawValue, forKey: userDefaultsKey)
            return migrated
        }

        // Fresh install default.
        return .rivulet
    }

    static func set(_ pref: PlayerPreference) {
        UserDefaults.standard.set(pref.rawValue, forKey: userDefaultsKey)
    }

    /// Display label for the Settings picker.
    var displayName: String {
        switch self {
        case .rivulet: return "Rivulet Player"
        case .apple:   return "Apple AVPlayer"
        case .aether:  return "Aether (experimental)"
        }
    }
}
