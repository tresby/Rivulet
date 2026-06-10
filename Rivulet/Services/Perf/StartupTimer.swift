//
//  StartupTimer.swift
//  Rivulet
//
//  Dead-simple wall-clock startup tracing. Unlike the os_signpost-based Perf
//  helper (Instruments-oriented, hardcoded signpost names), this prints plain
//  "[Startup +1234ms] <event>" lines to the console so a launch timeline can
//  be read straight out of a device-console paste — exactly what's needed to
//  pinpoint where cold-launch time goes (2026-06-10: ~30s to first content on
//  device, suspected dead cached-URL hitting the 30s request timeout).
//
//  Thread-safe (monotonic clock + plain print); callable from any actor.
//

import Foundation
import os

enum StartupTimer {
    /// Monotonic launch reference, captured the first time this type is touched
    /// (app init). systemUptime is unaffected by wall-clock changes.
    nonisolated(unsafe) private static let launchUptime = ProcessInfo.processInfo.systemUptime

    private static let log = Logger(subsystem: "com.bain.Rivulet", category: "Startup")

    /// Force the launch reference to be captured now (call as early as possible).
    static func arm() { _ = launchUptime }

    /// Log a milestone with elapsed-since-launch.
    static func mark(_ event: String) {
        let ms = (ProcessInfo.processInfo.systemUptime - launchUptime) * 1000
        log.info("[Startup +\(Int(ms), privacy: .public)ms] \(event, privacy: .public)")
    }

    /// Time an async block, logging start + duration with the elapsed prefix.
    @discardableResult
    static func measure<T>(_ event: String, _ work: () async throws -> T) async rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        mark("▶︎ \(event)")
        defer {
            let dur = (ProcessInfo.processInfo.systemUptime - start) * 1000
            mark("✓ \(event) — took \(Int(dur))ms")
        }
        return try await work()
    }
}
