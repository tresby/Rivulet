// RivuletTests/Unit/MusicItemTests.swift
import XCTest
@testable import Rivulet

final class MusicItemTests: XCTestCase {

    private func makeArtist(id: String = "a1") -> MusicArtist {
        MusicArtist(
            ref: MediaItemRef(providerID: "plex:x", itemID: id),
            name: "Artist Name",
            sortName: nil,
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            genres: [],
            yearRange: nil,
            userState: .empty
        )
    }

    private func makeAlbum(id: String = "b1") -> MusicAlbum {
        MusicAlbum(
            ref: MediaItemRef(providerID: "plex:x", itemID: id),
            title: "Album Title",
            sortTitle: nil,
            artistRef: nil,
            artistName: "Artist Name",
            year: 2020,
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            trackCount: 10,
            totalDuration: 3600,
            genres: [],
            userState: .empty
        )
    }

    private func makeTrack(id: String = "t1") -> MusicTrack {
        MusicTrack(
            ref: MediaItemRef(providerID: "plex:x", itemID: id),
            title: "Track Title",
            albumRef: nil,
            albumTitle: "Album Title",
            artistRef: nil,
            artistName: "Artist Name",
            trackNumber: 3,
            discNumber: nil,
            duration: 240,
            audioCodec: "flac",
            bitrate: 1_000_000,
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            userState: .empty
        )
    }

    func test_artist_case_exposes_fields() {
        let item = MusicItem.artist(makeArtist())
        XCTAssertEqual(item.kind, .artist)
        XCTAssertEqual(item.title, "Artist Name")
        XCTAssertEqual(item.ref.itemID, "a1")
    }

    func test_album_case_exposes_fields() {
        let item = MusicItem.album(makeAlbum())
        XCTAssertEqual(item.kind, .album)
        XCTAssertEqual(item.title, "Album Title")
        XCTAssertEqual(item.ref.itemID, "b1")
    }

    func test_track_case_exposes_fields() {
        let item = MusicItem.track(makeTrack())
        XCTAssertEqual(item.kind, .track)
        XCTAssertEqual(item.title, "Track Title")
        XCTAssertEqual(item.ref.itemID, "t1")
    }

    func test_id_equals_ref() {
        let item = MusicItem.artist(makeArtist(id: "abc"))
        XCTAssertEqual(item.id, MediaItemRef(providerID: "plex:x", itemID: "abc"))
    }
}
