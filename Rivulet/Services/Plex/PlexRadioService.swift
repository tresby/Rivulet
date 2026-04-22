//
//  PlexRadioService.swift
//  Rivulet
//
//  Plex radio API integration — generates dynamic stations from artists/tracks.
//

import Foundation
import Combine

/// Manages Plex radio station generation, fetching radio track lists
/// from the Plex API and feeding them into MusicQueue.
@MainActor
final class PlexRadioService: ObservableObject {

    // MARK: - Singleton

    static let shared = PlexRadioService()

    // MARK: - Published State

    @Published var isLoading = false
    @Published var currentRadioTitle: String?
    @Published var error: String?

    // MARK: - Initialization

    private init() {}

    // MARK: - Artist Radio

    /// Start a radio station based on an artist.
    /// Fetches related tracks from Plex and queues them for playback.
    ///
    /// - Parameters:
    ///   - artistRatingKey: The ratingKey of the artist to base the radio on
    ///   - sectionId: The library section ID containing the artist
    func startArtistRadio(artistRatingKey: String, sectionId: String) async {
        isLoading = true
        error = nil
        currentRadioTitle = nil

        defer { isLoading = false }

        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else {
            error = "Not connected to server"
            return
        }

        // Plex radio endpoint for artist-based stations
        // The radioKey format is: station://library/sections/{sectionId}/artist/{artistRatingKey}
        let radioKey = "station://library/sections/\(sectionId)/artist/\(artistRatingKey)"
        let encodedRadioKey = radioKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? radioKey

        guard var components = URLComponents(string: "\(serverURL)/hubs/sections/\(sectionId)") else {
            error = "Invalid URL"
            return
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: "8"),         // type 8 = tracks
            URLQueryItem(name: "radioKey", value: encodedRadioKey),
            URLQueryItem(name: "count", value: "50"),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]

        guard let url = components.url else {
            error = "Invalid URL"
            return
        }

        do {
            let tracks = try await fetchRadioTracks(from: url, serverURL: serverURL, token: token)

            if tracks.isEmpty {
                error = "No tracks found for radio station"
                return
            }

            // Start playing the first track and queue the rest
            MusicQueue.shared.playAlbum(tracks: tracks)
            currentRadioTitle = "Artist Radio"
        } catch {
            self.error = "Failed to load radio: \(error.localizedDescription)"
        }
    }

    // MARK: - Track Radio

    /// Start a radio station based on a specific track.
    /// Creates a station of similar tracks.
    ///
    /// - Parameters:
    ///   - trackRatingKey: The ratingKey of the track to base the radio on
    ///   - sectionId: The library section ID containing the track
    func startTrackRadio(trackRatingKey: String, sectionId: String) async {
        isLoading = true
        error = nil
        currentRadioTitle = nil

        defer { isLoading = false }

        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else {
            error = "Not connected to server"
            return
        }

        // Track-based radio station key
        let radioKey = "station://library/sections/\(sectionId)/track/\(trackRatingKey)"
        let encodedRadioKey = radioKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? radioKey

        guard var components = URLComponents(string: "\(serverURL)/hubs/sections/\(sectionId)") else {
            error = "Invalid URL"
            return
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: "8"),
            URLQueryItem(name: "radioKey", value: encodedRadioKey),
            URLQueryItem(name: "count", value: "50"),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]

        guard let url = components.url else {
            error = "Invalid URL"
            return
        }

        do {
            let tracks = try await fetchRadioTracks(from: url, serverURL: serverURL, token: token)

            if tracks.isEmpty {
                error = "No tracks found for radio station"
                return
            }

            MusicQueue.shared.playAlbum(tracks: tracks)
            currentRadioTitle = "Track Radio"
        } catch {
            self.error = "Failed to load radio: \(error.localizedDescription)"
        }
    }

    // MARK: - Load More

    /// Fetches additional tracks for the current radio station and appends to queue.
    /// Call this when the queue is running low to maintain continuous playback.
    func loadMoreTracks(sectionId: String, radioKey: String) async {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else { return }

        let encodedRadioKey = radioKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? radioKey

        guard var components = URLComponents(string: "\(serverURL)/hubs/sections/\(sectionId)") else { return }

        components.queryItems = [
            URLQueryItem(name: "type", value: "8"),
            URLQueryItem(name: "radioKey", value: encodedRadioKey),
            URLQueryItem(name: "count", value: "25"),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]

        guard let url = components.url else { return }

        do {
            let tracks = try await fetchRadioTracks(from: url, serverURL: serverURL, token: token)
            MusicQueue.shared.addToEnd(tracks: tracks)
        } catch {
            print("PlexRadioService: Failed to load more tracks: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    /// Fetches tracks from a Plex radio/hub endpoint.
    /// The response is a hub container with metadata items (tracks).
    private func fetchRadioTracks(from url: URL, serverURL: String, token: String) async throws -> [MusicTrack] {
        let headers = [
            "Accept": "application/json",
            "X-Plex-Token": token,
            "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
            "X-Plex-Platform": PlexAPI.platform,
            "X-Plex-Device-Name": PlexAPI.deviceName,
            "X-Plex-Product": PlexAPI.productName
        ]

        let data = try await PlexNetworkManager.shared.requestData(url, method: "GET", headers: headers)

        // The response can be either a MediaContainer with Metadata, or a Hub container.
        // Try standard MediaContainer first.
        struct RadioResponse: Codable {
            struct Container: Codable {
                var Metadata: [PlexMetadata]?
                var Hub: [HubItem]?
            }
            struct HubItem: Codable {
                var Metadata: [PlexMetadata]?
            }
            var MediaContainer: Container
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(RadioResponse.self, from: data)

        let machineID = PlexAuthManager.shared.selectedServer?.machineIdentifier ?? "unknown"
        let providerID = "plex:\(machineID)"

        let rawTracks: [PlexMetadata]
        // Direct metadata
        if let tracks = response.MediaContainer.Metadata, !tracks.isEmpty {
            rawTracks = tracks.filter { $0.type == "track" }
        } else if let hubs = response.MediaContainer.Hub {
            // Metadata nested in hubs
            rawTracks = hubs.flatMap { $0.Metadata ?? [] }.filter { $0.type == "track" }
        } else {
            rawTracks = []
        }

        return rawTracks.map {
            PlexMusicMapper.track($0, providerID: providerID, serverURL: serverURL, authToken: token)
        }
    }
}
