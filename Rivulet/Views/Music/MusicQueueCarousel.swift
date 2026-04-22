//
//  MusicQueueCarousel.swift
//  Rivulet
//
//  Horizontal queue carousel for Apple Music tvOS-style Now Playing.
//

import SwiftUI

struct MusicQueueCarousel: View {
    @ObservedObject var musicQueue: MusicQueue

    private let cardSize: CGFloat = 304
    private let spacing: CGFloat = 34

    private var items: [MusicTrack] {
        guard let current = musicQueue.currentTrack else { return [] }
        return [current] + musicQueue.queue
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: spacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, track in
                    carouselCard(track: track, isCurrent: offset == 0, queueIndex: offset - 1)
                }
            }
            .padding(.horizontal, 220)
            .padding(.vertical, 12)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .frame(height: 410)
    }

    private func carouselCard(track: MusicTrack, isCurrent: Bool, queueIndex: Int) -> some View {
        Button {
            if !isCurrent, queueIndex >= 0 {
                musicQueue.jumpToQueueItem(at: queueIndex)
            }
        } label: {
            VStack(spacing: 10) {
                trackArtView(for: track)
                    .frame(width: cardSize, height: cardSize)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 8)

                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        if isCurrent && musicQueue.playbackState == .playing {
                            PlaybackIndicator(isPlaying: true, size: .small)
                        }

                        Text(track.title)
                            .font(.system(size: 20, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(width: cardSize)
                    .multilineTextAlignment(.center)

                    Text(track.artistName ?? track.albumTitle ?? "")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: cardSize)
                        .multilineTextAlignment(.center)
                }
            }
            .opacity(isCurrent ? 1 : 0.96)
        }
        .buttonStyle(.card)
        .disabled(isCurrent)
    }

    private func trackArtView(for track: MusicTrack) -> some View {
        Group {
            if let url = artURL(for: track) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
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
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.secondary)
            }
    }

    private func artURL(for track: MusicTrack) -> URL? {
        track.artwork.poster
    }
}
