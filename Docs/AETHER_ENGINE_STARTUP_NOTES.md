# AetherEngine Startup Notes

Date: 2026-05-28

These notes summarize the local AetherEngine startup investigation against Rivulet's custom player on Apple TV 4K 3rd gen, using Plex over local network. The test case that exposed the largest gap was a large MKV with E-AC3 audio and many subtitle streams.

## Findings

- Full FFmpeg container open/probe is still the dominant startup cost for complex MKV files. In the worst case tested, the file exposed 47 streams and FFmpeg spent time probing subtitle streams before playback setup could continue.
- Increasing HTTP range size from 4 MB to 8 MB was worse. Fetch time scaled roughly with bytes, so this path was bandwidth-bound rather than round-trip-bound.
- Increasing URLSession connection count did not help while libavformat's demuxer reads were still serialized.
- Speculative parallel fetches can work architecturally, but on the tested WiFi path they competed for bandwidth and did not produce a reliable startup win.
- `networkServiceType = .avStreaming`, lower AVPlayer buffer duration, deferred init serving, and reduced FFmpeg probe budgets produced mixed or risky results. They should not be bundled with universal fixes.

## Safe AetherEngine Candidates

The candidates that look broadly safe enough to test upstream are:

1. AVIO range cache and duplicate in-flight range coalescing.
   - Avoids repeat HTTP requests when FFmpeg and the segment producer ask for the same 4 MB range.
   - Keeps behavior equivalent because it only returns bytes already fetched for the exact source URL/range.

2. Direct resume producer startup.
   - When starting at a non-zero position, initialize the HLS segment producer at the target segment instead of producing from segment 0 and then restarting.
   - This avoids wasted startup work and removes an out-of-range restart path.

3. SDR direct media playlist routing.
   - For non-HDR/non-DV output, serve the media playlist directly instead of forcing the master playlist path.
   - HDR/DV still uses the master playlist where variant signaling matters.

## Changes Not Included In The Safe Set

The following experiments were intentionally left out:

- Reduced startup `probesize` / `analyzeduration`.
- URLSession `.avStreaming` and connection-pool tuning.
- Lower `preferredForwardBufferDuration`.
- Starting AVPlayer before init segment readiness.
- App-side metadata deferral specific to this investigation.
- Startup timing instrumentation.

These may be worth revisiting as separate experiments, but they have higher compatibility risk than the safe candidates above.

## Current Conclusion

The safe candidates reduce wasted work and duplicate network reads, but they do not make Aether's startup equivalent to RivuletPlayer for complex MKVs. The remaining gap is mostly the full FFmpeg open/probe requirement and AVPlayer's HLS startup behavior. Larger startup wins likely require a deliberately staged/light probe design, which is a behavioral change and should be treated separately from universal correctness/performance fixes.
