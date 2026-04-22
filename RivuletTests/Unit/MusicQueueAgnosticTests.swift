// RivuletTests/Unit/MusicQueueAgnosticTests.swift
import XCTest
@testable import Rivulet

@MainActor
final class MusicQueueAgnosticTests: XCTestCase {

    private func makeTrack(id: String, title: String = "T") -> MusicTrack {
        MusicTrack(
            ref: MediaItemRef(providerID: "plex:x", itemID: id),
            title: title,
            albumRef: nil, albumTitle: nil,
            artistRef: nil, artistName: nil,
            trackNumber: nil, discNumber: nil,
            duration: 240,
            audioCodec: nil, bitrate: nil,
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            userState: .empty
        )
    }

    func test_playAlbum_sets_currentTrack_and_queue() async {
        let queue = MusicQueue.shared
        queue.clear()
        let tracks = [makeTrack(id: "1"), makeTrack(id: "2"), makeTrack(id: "3")]

        queue.playAlbum(tracks: tracks, startingAt: 0)

        XCTAssertEqual(queue.currentTrack?.ref.itemID, "1")
        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["2", "3"])
        XCTAssertTrue(queue.history.isEmpty)
    }

    func test_playAlbum_startingAt_middle() async {
        let queue = MusicQueue.shared
        queue.clear()
        let tracks = [makeTrack(id: "1"), makeTrack(id: "2"), makeTrack(id: "3")]

        queue.playAlbum(tracks: tracks, startingAt: 1)

        XCTAssertEqual(queue.currentTrack?.ref.itemID, "2")
        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["3"])
        XCTAssertEqual(queue.history.map(\.ref.itemID), ["1"])
    }

    func test_playNow_clears_queue() async {
        let queue = MusicQueue.shared
        queue.playAlbum(tracks: [makeTrack(id: "1"), makeTrack(id: "2")], startingAt: 0)
        queue.playNow(track: makeTrack(id: "99"))

        XCTAssertEqual(queue.currentTrack?.ref.itemID, "99")
        XCTAssertTrue(queue.queue.isEmpty)
        XCTAssertTrue(queue.history.isEmpty)
    }
}
