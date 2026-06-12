//
//  PlayerPreference.swift
//  Rivulet
//
//  User-selectable video player engine for VOD. Two engines:
//  AetherEngine (default) and Apple's AVPlayer. Surfaced as a 2-way
//  picker in Settings.
//
//  - .aether (default): AetherEngine via AVPlayerViewController. Native
//    HDR10+, HLG, EAC3+JOC Atmos, DV P5/P8.1, lossless TrueHD/DTS.
//    Sources Aether can't reach natively (DV P7, AV1) route through
//    AVPlayer's local-remux / server-HLS paths automatically.
//  - .apple: AVPlayer paths (avPlayerDirect / localRemux / HLS).
//
//  RivuletPlayer (the former custom FFmpeg engine) is no longer a VOD
//  option; it is retained only for the Live TV path.
//

import Foundation

enum PlayerPreference: String, CaseIterable, Sendable, CustomStringConvertible {
    case aether
    case apple

    /// Used by SettingsPickerRow to display the current selection.
    var description: String { displayName }

    /// UserDefaults key for the preference.
    static let userDefaultsKey = "playerPreference"

    /// One-time forced-migration flag. On the first launch of an
    /// Aether-default build we move every existing user to `.aether`,
    /// overriding any prior `.rivulet` / `.apple` choice. After that the
    /// stored preference is respected, so the user can switch back.
    private static let forcedAetherKey = "playerPreference.forcedAether.v1"

    /// Apply the one-time forced migration to `.aether`. Idempotent and
    /// cheap; safe to call at launch and on every `current` read.
    static func applyForcedAetherMigrationIfNeeded() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: forcedAetherKey) else { return }
        ud.set(true, forKey: forcedAetherKey)
        ud.set(PlayerPreference.aether.rawValue, forKey: userDefaultsKey)
    }

    /// The current preference. Runs the forced migration first so a
    /// returning user lands on `.aether` exactly once.
    static var current: PlayerPreference {
        applyForcedAetherMigrationIfNeeded()
        if let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
           let pref = PlayerPreference(rawValue: raw) {
            return pref
        }
        return .aether
    }

    static func set(_ pref: PlayerPreference) {
        UserDefaults.standard.set(pref.rawValue, forKey: userDefaultsKey)
    }

    /// Display label for the Settings picker.
    var displayName: String {
        switch self {
        case .aether: return "Aether"
        case .apple:  return "Apple AVPlayer"
        }
    }
}
