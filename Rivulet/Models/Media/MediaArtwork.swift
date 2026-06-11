//
//  MediaArtwork.swift
//  Rivulet
//
//  Resolved artwork URLs for a media item. The provider builds these at
//  construction time so views never construct backend-specific URLs.
//  Each is optional because not every backend has every kind.
//

import Foundation

struct MediaArtwork: Hashable, Sendable, Codable {
    let poster: URL?
    let backdrop: URL?
    let thumbnail: URL?
    let logo: URL?
}
