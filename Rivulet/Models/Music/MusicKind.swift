//
//  MusicKind.swift
//  Rivulet
//
//  Type discriminator for MusicItem enum cases.
//

import Foundation

enum MusicKind: String, Sendable, Hashable, Codable {
    case artist
    case album
    case track
}
