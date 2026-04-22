//
//  MusicQueueListView.swift
//  Rivulet
//
//  Full queue list view with Now Playing, Up Next, and History sections.
//  Uses plain track rows with native context menus.
//

import SwiftUI

struct MusicQueueListView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var musicQueue = MusicQueue.shared

    var body: some View {
        ZStack {
            // Background
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                header
                    .padding(.horizontal, 80)
                    .padding(.top, 60)
                    .padding(.bottom, 24)

                // Content
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        // Now Playing section
                        if let current = musicQueue.currentTrack {
                            nowPlayingSection(track: current)
                        }

                        // Up Next section
                        if !musicQueue.queue.isEmpty {
                            upNextSection
                        }

                        // History section
                        if !musicQueue.history.isEmpty {
                            historySection
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.bottom, 60)
                }
            }
        }
        .onExitCommand {
            isPresented = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Queue")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            // Clear Queue button
            if musicQueue.isActive {
                Button {
                    musicQueue.clearQueue()
                    isPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 18, weight: .medium))
                        Text("Clear Queue")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
                .buttonStyle(AppStoreButtonStyle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Now Playing Section

    private func nowPlayingSection(track: MusicTrack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Now Playing")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            Button {
                // Already playing
            } label: {
                trackRow(
                    track: track,
                    showIndicator: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Up Next Section

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Up Next")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()

                Text("\(musicQueue.queue.count) tracks")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.3))
            }

            ForEach(Array(musicQueue.queue.enumerated()), id: \.element.ref) { index, track in
                Button {
                    musicQueue.jumpToQueueItem(at: index)
                } label: {
                    trackRow(
                        track: track,
                        number: index + 1
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        musicQueue.removeFromQueue(at: index)
                    } label: {
                        Label("Remove from Queue", systemImage: "minus.circle")
                    }
                }
            }
        }
    }

    // MARK: - History Section

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()

                Text("\(musicQueue.history.count) tracks")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.3))
            }

            ForEach(Array(musicQueue.history.enumerated()), id: \.element.ref) { index, track in
                Button {
                    musicQueue.playNow(track: track)
                } label: {
                    trackRow(
                        track: track,
                        isDimmed: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Track Row

    private func trackRow(
        track: MusicTrack,
        number: Int? = nil,
        showIndicator: Bool = false,
        isDimmed: Bool = false
    ) -> some View {
        HStack(spacing: 16) {
            // Track number or indicator
            if showIndicator {
                PlaybackIndicator(
                    isPlaying: musicQueue.playbackState == .playing,
                    size: .small
                )
                .frame(width: 24)
            } else if let number {
                Text("\(number)")
                    .font(.system(size: 16).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 24)
            }

            // Album art
            trackArtView(for: track)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Track info
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(isDimmed ? 0.5 : 0.9))
                    .lineLimit(1)

                Text(track.artistName ?? track.albumTitle ?? "")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(isDimmed ? 0.3 : 0.5))
                    .lineLimit(1)
            }

            Spacer()

            // Duration
            Text(formatDuration(track.duration))
                .font(.system(size: 16).monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.05))
        )
        .opacity(isDimmed ? 0.7 : 1.0)
    }

    // MARK: - Art

    private func trackArtView(for track: MusicTrack) -> some View {
        Group {
            if let url = artURL(for: track) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        artPlaceholder
                    }
                }
            } else {
                artPlaceholder
            }
        }
    }

    private var artPlaceholder: some View {
        Rectangle()
            .fill(Color(white: 0.15))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }

    private func artURL(for track: MusicTrack) -> URL? {
        track.artwork.poster
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
