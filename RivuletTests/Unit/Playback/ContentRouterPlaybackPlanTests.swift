//
//  ContentRouterPlaybackPlanTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class ContentRouterPlaybackPlanTests: XCTestCase {

    // MARK: - MKV + DTS → Plex HLS (server transcodes audio)

    func testMKVWithDTSRoutesToHLS() {
        let metadata = makeMetadata(audioCodec: "dts", container: "mkv", includePart: true)
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)

        // Both branches route to HLS; the reasoning string differs:
        //  - FFmpeg available   → Path 3 "plex_server_remux"
        //  - FFmpeg unavailable → Path 5 "ffmpeg_unavailable"
        // The Sim target builds against the FFmpeg stub
        // (`isAvailable=false`); the device target builds against
        // the real lib (`isAvailable=true`). Both should still
        // produce a `.hls` primary with no fallbacks.
        if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty, "HLS server remux should have no fallbacks")
            if FFmpegDemuxer.isAvailable {
                XCTAssertTrue(plan.reasoning.contains("plex_server_remux"))
            } else {
                XCTAssertTrue(plan.reasoning.contains("ffmpeg_unavailable"))
            }
        } else {
            XCTFail("Expected HLS primary route for MKV + DTS, got \(plan.primary)")
        }
    }

    // MARK: - MKV + native audio → Plex HLS (server remuxes container)

    func testMKVWithEAC3RoutesToHLS() {
        let metadata = makeMetadata(audioCodec: "eac3", container: "mkv", includePart: true)
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)

        if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
            if FFmpegDemuxer.isAvailable {
                XCTAssertTrue(plan.reasoning.contains("plex_server_remux"))
            } else {
                XCTAssertTrue(plan.reasoning.contains("ffmpeg_unavailable"))
            }
        } else {
            XCTFail("Expected HLS primary route for MKV + EAC3, got \(plan.primary)")
        }
    }

    // MARK: - MP4 + native audio → AVPlayer Direct

    func testMP4WithAACRoutesToAVPlayerDirect() {
        let metadata = makeMetadata(audioCodec: "aac", container: "mp4", includePart: true)
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)

        if FFmpegDemuxer.isAvailable {
            if case .avPlayerDirect = plan.primary {
                XCTAssertEqual(plan.fallbacks.count, 1)
                if case .hls = plan.fallbacks[0] {
                    // expected
                } else {
                    XCTFail("Expected HLS fallback")
                }
            } else {
                XCTFail("Expected AVPlayerDirect for MP4 + AAC, got \(plan.primary)")
            }
        } else if case .hls = plan.primary {
            // FFmpeg unavailable but native container — still routes to direct with HLS fallback
            // or HLS if no FFmpeg at all
        } else if case .avPlayerDirect = plan.primary {
            // Also acceptable without FFmpeg for native container
        } else {
            XCTFail("Unexpected route for MP4 + AAC without FFmpeg: \(plan.primary)")
        }
    }

    // MARK: - User-enabled local remux

    func testMKVWithNativeAudioRoutesToLocalRemuxWhenEnabled() {
        let metadata = makeMetadata(audioCodec: "eac3", container: "mkv", includePart: true)
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            playbackPolicy: .directPlayFirst,
            useLocalRemux: true
        )

        let plan = ContentRouter.plan(for: context)

        if FFmpegDemuxer.isAvailable {
            if case .localRemux = plan.primary {
                XCTAssertEqual(plan.fallbacks.count, 1)
                if case .hls = plan.fallbacks[0] {
                    // expected
                } else {
                    XCTFail("Expected HLS fallback for local remux")
                }
                XCTAssertTrue(plan.reasoning.contains("local_remux_user_enabled"))
            } else {
                XCTFail("Expected LocalRemux primary for MKV when local remux is enabled, got \(plan.primary)")
            }
        } else if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
        } else {
            XCTFail("Expected HLS primary when FFmpeg is unavailable, got \(plan.primary)")
        }
    }

    func testMP4DirectPlayNotForcedToLocalRemuxWhenEnabled() {
        let metadata = makeMetadata(audioCodec: "aac", container: "mp4", includePart: true)
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            playbackPolicy: .directPlayFirst,
            useLocalRemux: true
        )

        let plan = ContentRouter.plan(for: context)

        if FFmpegDemuxer.isAvailable {
            if case .avPlayerDirect = plan.primary {
                XCTAssertEqual(plan.fallbacks.count, 1)
            } else {
                XCTFail("Expected AVPlayerDirect primary for MP4 direct-play content, got \(plan.primary)")
            }
        } else if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
        } else if case .avPlayerDirect = plan.primary {
            // acceptable when native direct path is still available without FFmpeg
        } else {
            XCTFail("Unexpected route for MP4 direct-play content: \(plan.primary)")
        }
    }

    // MARK: - No part key → HLS fallback

    func testPlanUsesHLSWhenNoDirectPlaySourceExists() {
        let metadata = makeMetadata(audioCodec: "aac", container: "mkv", includePart: false)
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)
        if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
        } else {
            XCTFail("Expected HLS primary when no direct-play part key is available")
        }
    }

    // MARK: - Live TV → HLS

    func testPlanUsesHLSForLiveTV() {
        let metadata = makeMetadata(audioCodec: "aac", container: "mkv", includePart: true)
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            isLiveTV: true,
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)
        if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
        } else {
            XCTFail("Expected HLS primary for live TV")
        }
    }

    // MARK: - DV P7 → Local Remux (unchanged)

    func testDVP7RoutesToLocalRemux() {
        let metadata = makeMetadata(
            audioCodec: "eac3",
            container: "mkv",
            includePart: true,
            streams: [makeAudioStream(id: 10, codec: "eac3", channels: 6)]
        )
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            requiresProfileConversion: true,
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)

        if FFmpegDemuxer.isAvailable {
            if case .localRemux = plan.primary {
                XCTAssertEqual(plan.fallbacks.count, 1)
                if case .hls = plan.fallbacks[0] {
                    // expected
                } else {
                    XCTFail("Expected HLS fallback for local remux")
                }
            } else {
                XCTFail("Expected LocalRemux for DV P7 content, got \(plan.primary)")
            }
        } else if case .hls = plan.primary {
            // Without FFmpeg, can't do local remux
        } else {
            XCTFail("Expected HLS when FFmpeg unavailable, got \(plan.primary)")
        }
    }

    // MARK: - DV conversion + TrueHD only → HLS (can't local remux without native audio)

    func testPlanUsesHLSForDVConversionWhenOnlyClientDecodeAudioExists() {
        let metadata = makeMetadata(
            audioCodec: "truehd",
            container: "mkv",
            includePart: true,
            streams: [makeAudioStream(id: 10, codec: "truehd", channels: 8)]
        )
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            requiresProfileConversion: true,
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)

        if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
        } else {
            XCTFail("Expected HLS primary for DV conversion with only client-decoded audio")
        }
    }

    // MARK: - DV conversion + native audio fallback → Local Remux

    func testPlanKeepsLocalRemuxForDVConversionWhenNativeAudioFallbackExists() {
        let metadata = makeMetadata(
            audioCodec: "truehd",
            container: "mkv",
            includePart: true,
            streams: [
                makeAudioStream(id: 10, codec: "truehd", channels: 8),
                makeAudioStream(id: 11, codec: "ac3", channels: 6)
            ]
        )
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            requiresProfileConversion: true,
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)

        if FFmpegDemuxer.isAvailable {
            if case .localRemux = plan.primary {
                XCTAssertEqual(plan.fallbacks.count, 1)
            } else {
                XCTFail("Expected LocalRemux primary when DV conversion has native audio fallback, got \(plan.primary)")
            }
        } else if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
        } else {
            XCTFail("Expected HLS primary when FFmpeg is unavailable")
        }
    }

    // MARK: - Helpers

    private func makeMetadata(
        audioCodec: String,
        container: String = "mkv",
        includePart: Bool,
        streams: [PlexStream]? = nil
    ) -> PlexMetadata {
        let part: [PlexPart]? = includePart
            ? [PlexPart(
                id: 1,
                key: "/library/parts/100/file.\(container)",
                duration: nil,
                file: nil,
                size: nil,
                container: container,
                Stream: streams
            )]
            : nil

        let media = PlexMedia(
            id: 1,
            duration: nil,
            bitrate: nil,
            width: nil,
            height: nil,
            aspectRatio: nil,
            audioChannels: nil,
            audioCodec: audioCodec,
            videoCodec: "hevc",
            videoResolution: "4k",
            container: container,
            videoFrameRate: nil,
            Part: part
        )

        return PlexMetadata(
            ratingKey: "100",
            type: "movie",
            title: "Test",
            Media: [media]
        )
    }

    private func makeAudioStream(id: Int, codec: String, channels: Int) -> PlexStream {
        PlexStream(
            _id: id,
            streamType: 2,
            index: nil,
            codec: codec,
            codecID: nil,
            language: "eng",
            languageCode: "eng",
            languageTag: nil,
            displayTitle: nil,
            title: nil,
            default: id == 10,
            forced: nil,
            selected: id == 10,
            bitDepth: nil,
            chromaLocation: nil,
            chromaSubsampling: nil,
            colorPrimaries: nil,
            colorRange: nil,
            colorSpace: nil,
            colorTrc: nil,
            DOVIBLCompatID: nil,
            DOVIBLPresent: nil,
            DOVIELPresent: nil,
            DOVILevel: nil,
            DOVIPresent: nil,
            DOVIProfile: nil,
            DOVIRPUPresent: nil,
            DOVIVersion: nil,
            frameRate: nil,
            height: nil,
            width: nil,
            level: nil,
            profile: nil,
            refFrames: nil,
            scanType: nil,
            audioChannelLayout: nil,
            channels: channels,
            bitrate: nil,
            samplingRate: 48_000,
            format: nil,
            key: nil,
            extendedDisplayTitle: nil,
            hearingImpaired: nil
        )
    }
}
