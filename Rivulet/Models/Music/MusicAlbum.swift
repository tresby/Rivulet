//
//  MusicAlbum.swift
//  Rivulet
//
//  Agnostic album shape for browse/grid/detail.
//

import Foundation

struct MusicAlbum: Identifiable, Hashable, Sendable {
    var id: MediaItemRef { ref }
    let ref: MediaItemRef
    let title: String
    let sortTitle: String?
    let artistRef: MediaItemRef?
    let artistName: String?
    let year: Int?
    let artwork: MediaArtwork
    let trackCount: Int?
    let totalDuration: TimeInterval?
    let genres: [String]
    let userState: MusicUserState
}
