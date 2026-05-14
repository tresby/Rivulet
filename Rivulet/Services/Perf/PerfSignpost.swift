//
//  PerfSignpost.swift
//  Rivulet
//
//  Shared `os_signpost` plumbing for the SwiftUI-vs-UIKit home-screen
//  perf comparison. Both implementations call into the same surface so
//  Instruments traces line up.
//
//  Subsystem `com.rivulet.perf`, category `.pointsOfInterest`. Shows up
//  as the "Points of Interest" track in Time Profiler and Animation
//  Hitches recordings without extra config.
//
//  Names mirrored across implementations (see `Docs/PERF_COMPARISON.md`):
//    - AppLaunch          (interval) — main → first home cell visible
//    - HomeDataFetch      (interval) — refreshHubs called → models in memory
//    - HomeFirstRender    (interval) — data ready → first cell laid out
//    - HomeFirstFrameOnScreen (event) — earliest frame containing a cell
//    - HomeScroll         (interval) — wraps a scroll gesture
//    - CellPrepare        (interval) — per-cell: configure → ready
//    - ImageDecode        (interval) — per-image: cache miss → UIImage ready
//    - FocusUpdate        (interval) — focus engine: shouldUpdate → didUpdate
//
//  Implementation tag: every signpost is sent with metadata `impl=swiftui|uikit`
//  so Instruments traces can be filtered/compared per implementation.
//

import Foundation
import os.log
import os.signpost

/// Active home-screen implementation. Drives both runtime swap and signpost
/// tagging. `@AppStorage`-backed via `HomeImplPreference` (see view layer).
enum HomeImpl: String, Sendable {
    case swiftui
    case uikit
}

/// Subsystem-scoped logger for perf signposts. Custom subsystem keeps perf
/// events isolated from the app's normal logging firehose so Instruments
/// templates can subscribe to just `com.rivulet.perf`.
@MainActor
enum PerfLog {
    static let log = OSLog(subsystem: "com.rivulet.perf", category: .pointsOfInterest)

    /// Currently-active implementation. Set on home-view appear so per-cell
    /// signposts (which can't easily plumb the value down) tag correctly.
    static var activeImpl: HomeImpl = .swiftui
}

/// Type-safe signpost names. Matches the reference table above.
enum PerfSignpost: String {
    case appLaunch = "AppLaunch"
    case homeDataFetch = "HomeDataFetch"
    case homeFirstRender = "HomeFirstRender"
    case homeFirstFrameOnScreen = "HomeFirstFrameOnScreen"
    case homeScroll = "HomeScroll"
    case cellPrepare = "CellPrepare"
    case imageDecode = "ImageDecode"
    case focusUpdate = "FocusUpdate"
}

/// Lightweight wrapper around `os_signpost` so callers don't have to deal
/// with `OSSignpostID` plumbing. For per-instance intervals (e.g. per-cell),
/// pass a stable `key` (the cell's reuse identity is fine) so the begin/end
/// pair can be matched in Instruments.
@MainActor
enum Perf {
    /// Mark a one-shot event.
    static func event(_ signpost: PerfSignpost, message: String = "") {
        os_signpost(
            .event,
            log: PerfLog.log,
            name: signpost.rawValue.staticString,
            "impl=%{public}s msg=%{public}s",
            PerfLog.activeImpl.rawValue,
            message
        )
    }

    /// Begin an interval keyed by `key` (defaults to the signpost name itself
    /// for singleton intervals like AppLaunch). Returns the `OSSignpostID` so
    /// the caller can hand it to `end(...)`.
    @discardableResult
    static func begin(_ signpost: PerfSignpost, key: AnyHashable? = nil, message: String = "") -> OSSignpostID {
        let id = signpostID(for: signpost, key: key)
        os_signpost(
            .begin,
            log: PerfLog.log,
            name: signpost.rawValue.staticString,
            signpostID: id,
            "impl=%{public}s msg=%{public}s",
            PerfLog.activeImpl.rawValue,
            message
        )
        return id
    }

    /// End an interval started with `begin(_:key:)`. Same `key` must be passed.
    static func end(_ signpost: PerfSignpost, key: AnyHashable? = nil, id: OSSignpostID? = nil, message: String = "") {
        let id = id ?? signpostID(for: signpost, key: key)
        os_signpost(
            .end,
            log: PerfLog.log,
            name: signpost.rawValue.staticString,
            signpostID: id,
            "impl=%{public}s msg=%{public}s",
            PerfLog.activeImpl.rawValue,
            message
        )
    }

    /// Convenience: time the closure and emit a begin/end pair.
    static func interval<T>(_ signpost: PerfSignpost, key: AnyHashable? = nil, _ work: () throws -> T) rethrows -> T {
        let id = begin(signpost, key: key)
        defer { end(signpost, key: key, id: id) }
        return try work()
    }

    /// Async variant.
    static func interval<T>(_ signpost: PerfSignpost, key: AnyHashable? = nil, _ work: () async throws -> T) async rethrows -> T {
        let id = begin(signpost, key: key)
        defer { end(signpost, key: key, id: id) }
        return try await work()
    }

    private static func signpostID(for signpost: PerfSignpost, key: AnyHashable?) -> OSSignpostID {
        // Stable hashing across call sites so begin/end with the same key
        // produce the same OSSignpostID. AnyHashable's hashValue is stable
        // within a process run.
        let hashSeed = (key?.hashValue ?? 0) ^ signpost.rawValue.hashValue
        return OSSignpostID(UInt64(bitPattern: Int64(hashSeed)))
    }
}

// MARK: - StaticString bridging

private extension String {
    /// `os_signpost` requires `StaticString`. We can't synthesize one from
    /// arbitrary input at runtime, so this helper hand-maps known PerfSignpost
    /// names. Keeps the rest of the API ergonomic (callers pass the enum).
    var staticString: StaticString {
        switch self {
        case "AppLaunch": return "AppLaunch"
        case "HomeDataFetch": return "HomeDataFetch"
        case "HomeFirstRender": return "HomeFirstRender"
        case "HomeFirstFrameOnScreen": return "HomeFirstFrameOnScreen"
        case "HomeScroll": return "HomeScroll"
        case "CellPrepare": return "CellPrepare"
        case "ImageDecode": return "ImageDecode"
        case "FocusUpdate": return "FocusUpdate"
        default: return "Unknown"
        }
    }
}
