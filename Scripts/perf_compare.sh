#!/usr/bin/env bash
#
# perf_compare.sh
#
# Cold-launch + idle-memory comparison between the SwiftUI and UIKit
# implementations of PlexHomeView. Run from the repo root.
#
# Pre-reqs:
#   - Booted simulator with a known UDID (default: AppleTV4K3rdGenAt1080p
#     UDID below — override with $SIM_UDID).
#   - App already installed and signed in to Plex (since the perf-spike
#     toggle only swaps the Home view, the rest of the app must work).
#
# Output: appends rows to perf_results.csv:
#   impl,trial,launch_to_first_frame_ms,rss_at_5s_mb,rss_at_30s_mb
#
# Per the perf agent's guidance:
#   - Use Release build for representative numbers
#   - Force-quit between trials
#   - Disable network variance: pre-warm caches, then airplane mode
#   - 10 trials each, report median
#
# This script handles the install/launch/measure loop. It does NOT capture
# Animation Hitches (need Instruments for that — that's a separate run).
#
# Usage:
#   scripts/perf_compare.sh swiftui 10
#   scripts/perf_compare.sh uikit 10
#

set -euo pipefail

SIM_UDID="${SIM_UDID:-B7CDD74D-BA0C-4CDB-8038-8D6FCAB7764F}"
BUNDLE_ID="com.gstudios.rivulet"
DEFAULTS_KEY="homeImplementation"

IMPL="${1:-}"
TRIALS="${2:-10}"

if [[ "$IMPL" != "swiftui" && "$IMPL" != "uikit" ]]; then
    echo "Usage: $0 {swiftui|uikit} [trials=10]"
    exit 1
fi

OUTPUT_CSV="$(pwd)/perf_results.csv"
if [[ ! -f "$OUTPUT_CSV" ]]; then
    echo "impl,trial,launch_to_first_frame_ms,rss_at_5s_mb,rss_at_30s_mb" > "$OUTPUT_CSV"
fi

echo "[perf] impl=$IMPL trials=$TRIALS sim=$SIM_UDID"

# Ensure sim booted
xcrun simctl bootstatus "$SIM_UDID" 2>/dev/null || xcrun simctl boot "$SIM_UDID"

# Set the impl preference once for the entire run.
xcrun simctl spawn "$SIM_UDID" defaults write "$BUNDLE_ID" "$DEFAULTS_KEY" -string "$IMPL"

for trial in $(seq 1 "$TRIALS"); do
    echo "[perf] trial $trial/$TRIALS"

    # Force-quit between trials.
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    sleep 1

    # Stream logs to a per-trial file so we can extract the AppLaunch interval.
    LOG_FILE="/tmp/rivulet_perf_${IMPL}_${trial}.log"
    xcrun simctl spawn "$SIM_UDID" log stream --process Rivulet --level debug --style compact > "$LOG_FILE" 2>&1 &
    LOG_PID=$!

    sleep 0.5
    LAUNCH_START_MS=$(($(date +%s%N) / 1000000))

    PID=$(xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" | awk '{print $NF}')

    # Wait for first-frame signal: poll for the HomeFirstFrameOnScreen event
    # in the log. Cap at 30s.
    DEADLINE=$(($(date +%s) + 30))
    FIRST_FRAME_MS=""
    while [[ $(date +%s) -lt $DEADLINE ]]; do
        if grep -q "HomeFirstFrameOnScreen" "$LOG_FILE" 2>/dev/null; then
            FIRST_FRAME_MS=$(($(date +%s%N) / 1000000 - LAUNCH_START_MS))
            break
        fi
        sleep 0.1
    done

    # Capture RSS at +5s and +30s. App emits "[Perf:RSS] mb=N" lines via
    # PerfLog.startRSSSampler() once per second. Take the last line at
    # each checkpoint.
    sleep 5
    RSS_5=$(grep "Perf:RSS" "$LOG_FILE" 2>/dev/null | tail -1 | sed -n 's/.*mb=\([0-9.]*\).*/\1/p')
    [[ -z "$RSS_5" ]] && RSS_5="?"

    sleep 25
    RSS_30=$(grep "Perf:RSS" "$LOG_FILE" 2>/dev/null | tail -1 | sed -n 's/.*mb=\([0-9.]*\).*/\1/p')
    [[ -z "$RSS_30" ]] && RSS_30="?"

    kill "$LOG_PID" 2>/dev/null || true

    echo "$IMPL,$trial,${FIRST_FRAME_MS:-?},$RSS_5,$RSS_30" >> "$OUTPUT_CSV"
    echo "[perf] trial $trial: first_frame_ms=${FIRST_FRAME_MS:-?} rss_5s=$RSS_5 rss_30s=$RSS_30"
done

echo "[perf] done. results in $OUTPUT_CSV"
