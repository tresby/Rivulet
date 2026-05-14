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
import Darwin.Mach
import QuartzCore
import UIKit

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

    /// Parallel logger used to emit human-readable signpost events to
    /// `log stream` (which doesn't pick up signposts by default). Used by
    /// the `scripts/perf_compare.sh` driver to detect first-frame events.
    static let textLog = Logger(subsystem: "com.rivulet.perf", category: "events")

    /// Currently-active implementation. Set on home-view appear so per-cell
    /// signposts (which can't easily plumb the value down) tag correctly.
    static var activeImpl: HomeImpl = .swiftui

    /// Resident set size in bytes. Reads via `task_vm_info` — the same
    /// metric Xcode's memory gauge shows.
    static func currentRSSBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    /// Log RSS in MB to the text log. Called by the perf script on a timer
    /// (the script greps for these lines).
    static func logRSS(tag: String) {
        let bytes = currentRSSBytes()
        let mb = Double(bytes) / 1_048_576.0
        textLog.info("[Perf:RSS] impl=\(activeImpl.rawValue, privacy: .public) tag=\(tag, privacy: .public) mb=\(String(format: "%.2f", mb), privacy: .public)")
        appendToFileLog("RSS impl=\(activeImpl.rawValue) tag=\(tag) mb=\(String(format: "%.2f", mb))")
    }

    /// Persistent file log. Timestamp is mach absolute time in
    /// nanoseconds since boot — gives sub-millisecond resolution that
    /// the ISO8601 string format can't represent. Driver script does
    /// math on these values directly.
    static func appendToFileLog(_ line: String) {
        let ns = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let entry = "\(ns) \(line)\n"
        guard let url = perfLogURL else { return }
        if let data = entry.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Reset the file log (start of trial). Called from RivuletApp init.
    static func resetFileLog() {
        guard let url = perfLogURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static var perfLogURL: URL? {
        // tvOS doesn't expose a Documents directory; use Caches which IS
        // writable and survives across app runs (until the OS evicts).
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent("perf.log")
    }

    /// Periodic RSS sampler. Call once on app launch; runs forever.
    static func startRSSSampler(interval: TimeInterval = 1.0) {
        if rssSampler != nil { return }
        rssSampler = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                logRSS(tag: "tick")
            }
        }
    }
    private static var rssSampler: Timer?
}

// MARK: - Frame hitch sampler

/// Per-frame `CADisplayLink` callback that tracks frame durations and
/// counts "hitches" (frames > 1.5x the target frame interval). Aggregates
/// totals into 1-second buckets and logs them. Used by the perf script to
/// quantify scroll smoothness without needing Instruments.
@MainActor
final class FrameHitchSampler {
    static let shared = FrameHitchSampler()

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var bucketStart: CFTimeInterval = 0
    private var bucketFrameCount: Int = 0
    private var bucketHitchCount: Int = 0
    private var bucketHitchMs: Double = 0

    /// Target frame interval. Apple TV is 60Hz default, can be 24/30/60.
    /// Use `targetTimestamp - timestamp` from the display link for the
    /// real expected interval.
    private var targetInterval: CFTimeInterval = 1.0 / 60.0

    /// Hitch threshold: a frame longer than this is considered a hitch.
    /// 1.5x target interval per Apple's WWDC guidance.
    private var hitchThreshold: CFTimeInterval { targetInterval * 1.5 }

    private init() {}

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        bucketStart = CACurrentMediaTime()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let target = link.targetTimestamp
        targetInterval = target - now

        if lastTimestamp != 0 {
            let actualInterval = now - lastTimestamp
            bucketFrameCount += 1
            if actualInterval > hitchThreshold {
                bucketHitchCount += 1
                bucketHitchMs += (actualInterval - targetInterval) * 1000
            }
        }
        lastTimestamp = now

        // Flush bucket every 1 second.
        if now - bucketStart >= 1.0 {
            let hitchRatio = bucketHitchMs  // ms hitched per second
            PerfLog.textLog.info("[Perf:FrameBucket] impl=\(PerfLog.activeImpl.rawValue, privacy: .public) frames=\(self.bucketFrameCount) hitches=\(self.bucketHitchCount) hitch_ms=\(String(format: "%.2f", hitchRatio), privacy: .public)")
            PerfLog.appendToFileLog("FRAMEBUCKET impl=\(PerfLog.activeImpl.rawValue) frames=\(bucketFrameCount) hitches=\(bucketHitchCount) hitch_ms=\(String(format: "%.2f", hitchRatio))")
            bucketStart = now
            bucketFrameCount = 0
            bucketHitchCount = 0
            bucketHitchMs = 0
        }
    }
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
        PerfLog.textLog.info("[Perf:\(signpost.rawValue, privacy: .public)] impl=\(PerfLog.activeImpl.rawValue, privacy: .public) \(message, privacy: .public)")
        PerfLog.appendToFileLog("EVENT \(signpost.rawValue) impl=\(PerfLog.activeImpl.rawValue) msg=\(message)")
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
