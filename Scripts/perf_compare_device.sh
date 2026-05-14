#!/usr/bin/env bash
#
# perf_compare_device.sh
#
# Cold-launch + RSS + hitch comparison on a physical Apple TV using
# devicectl. Mirrors Scripts/perf_compare.sh but pulls the per-trial
# perf.log from the app's Documents directory after each run.
#
# Pre-reqs:
#   - Physical Apple TV paired with this Mac, accessible via devicectl
#   - DEVICE_UDID env var or default below
#   - Release build of Rivulet.app installed (run xcodebuild + devicectl
#     install once before running this script)
#   - User signed in to Plex on the device
#
# Usage:
#   DEVICE_UDID=00008110-001618993E41401E bash Scripts/perf_compare_device.sh uikit 5
#

set -euo pipefail

DEVICE_UDID="${DEVICE_UDID:-00008110-001618993E41401E}"
BUNDLE_ID="com.gstudios.rivulet"

IMPL="${1:-}"
TRIALS="${2:-5}"

if [[ "$IMPL" != "swiftui" && "$IMPL" != "uikit" ]]; then
    echo "Usage: $0 {swiftui|uikit} [trials=5]"
    exit 1
fi

OUTPUT_CSV="$(pwd)/perf_results_device.csv"
if [[ ! -f "$OUTPUT_CSV" ]]; then
    echo "impl,trial,launch_to_first_frame_ms,rss_at_5s_mb,rss_at_30s_mb,first_5s_hitch_ms_total,first_5s_hitches" > "$OUTPUT_CSV"
fi

echo "[perf-device] impl=$IMPL trials=$TRIALS device=$DEVICE_UDID"

for trial in $(seq 1 "$TRIALS"); do
    echo "[perf-device] trial $trial/$TRIALS"

    # Force-quit any running instance. info processes is slow but
    # required so the next launch is genuinely cold (and the perf.log
    # gets reset).
    EXISTING_PID=$(xcrun devicectl device info processes --device "$DEVICE_UDID" 2>/dev/null | grep "/Rivulet.app/Rivulet" | grep -v TopShelf | awk '{print $1}' | head -1 || echo "")
    if [[ -n "$EXISTING_PID" ]]; then
        xcrun devicectl device process terminate --device "$DEVICE_UDID" --pid "$EXISTING_PID" 2>/dev/null | tail -1 || true
    fi
    sleep 2

    LAUNCH_START_MS=$(($(date +%s%N) / 1000000))

    # Launch with home-impl override
    LAUNCH_OUT=$(xcrun devicectl device process launch \
        --device "$DEVICE_UDID" \
        "$BUNDLE_ID" \
        -- "--home-impl=$IMPL" 2>&1 || true)
    PID=$(echo "$LAUNCH_OUT" | grep -oE 'process identifier of [0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")
    echo "[perf-device]   launched (pid not always reported by devicectl)"

    # Wait 35s so the RSS sampler captures both 5s and 30s checkpoints
    sleep 35

    # Pull perf.log from the app's Documents directory
    LOG_FILE="/tmp/rivulet_perf_device_${IMPL}_${trial}.log"
    rm -f "$LOG_FILE"
    xcrun devicectl device copy from \
        --device "$DEVICE_UDID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "Library/Caches/perf.log" \
        --destination "$LOG_FILE" \
        2>&1 | tail -3 || true

    if [[ ! -f "$LOG_FILE" ]]; then
        echo "[perf-device]   FAILED to pull perf.log; skipping trial"
        continue
    fi

    # Parse FIRST_FRAME_MS — file log uses CLOCK_MONOTONIC_RAW nanoseconds
    # as the timestamp. Compute delta in ms.
    APP_LAUNCH_NS=$(grep "EVENT AppLaunch" "$LOG_FILE" | head -1 | awk '{print $1}')
    FIRST_FRAME_NS=$(grep "EVENT HomeFirstFrameOnScreen" "$LOG_FILE" | head -1 | awk '{print $1}')
    if [[ -n "$APP_LAUNCH_NS" && -n "$FIRST_FRAME_NS" ]]; then
        FIRST_FRAME_MS=$(( (FIRST_FRAME_NS - APP_LAUNCH_NS) / 1000000 ))
    else
        FIRST_FRAME_MS="?"
    fi

    # RSS @ 5s and 30s — find the closest RSS line by timestamp
    RSS_5=$(grep "RSS impl=" "$LOG_FILE" | awk 'NR==5 {print $0}' | sed -n 's/.*mb=\([0-9.]*\).*/\1/p')
    RSS_30=$(grep "RSS impl=" "$LOG_FILE" | awk 'NR==30 {print $0}' | sed -n 's/.*mb=\([0-9.]*\).*/\1/p')
    [[ -z "$RSS_5" ]] && RSS_5="?"
    [[ -z "$RSS_30" ]] && RSS_30="?"

    # First 5 frame buckets
    HITCH_MS_TOTAL=$(grep "FRAMEBUCKET" "$LOG_FILE" | head -5 | sed -n 's/.*hitch_ms=\([0-9.]*\).*/\1/p' | awk '{s+=$1} END {printf "%.2f", s}')
    HITCH_COUNT=$(grep "FRAMEBUCKET" "$LOG_FILE" | head -5 | sed -n 's/.*hitches=\([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s}')
    [[ -z "$HITCH_MS_TOTAL" ]] && HITCH_MS_TOTAL="?"
    [[ -z "$HITCH_COUNT" ]] && HITCH_COUNT="?"

    echo "$IMPL,$trial,${FIRST_FRAME_MS:-?},$RSS_5,$RSS_30,$HITCH_MS_TOTAL,$HITCH_COUNT" >> "$OUTPUT_CSV"
    echo "[perf-device] trial $trial: first_frame_ms=${FIRST_FRAME_MS:-?} rss_5s=$RSS_5 rss_30s=$RSS_30 hitch_ms=$HITCH_MS_TOTAL hitches=$HITCH_COUNT"
done

echo "[perf-device] done. results in $OUTPUT_CSV"
