//
//  MusicNowPlayingView.swift
//  Rivulet
//
//  Apple Music tvOS-inspired now playing screen.
//

import SwiftUI

struct MusicNowPlayingView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var showQueue = false

    var body: some View {
        ZStack {
            albumArtBackdrop

            VStack(spacing: 0) {
                Text(albumName)
                    .font(.system(size: 21, weight: .regular))
                    .lineLimit(1)
                    .padding(.top, 44)

                Spacer(minLength: showQueue ? 30 : 74)

                if showQueue {
                    queueStage
                } else {
                    defaultStage
                }

                Spacer(minLength: 36)

                MusicProgressBar(
                    currentTime: musicQueue.currentTime,
                    duration: musicQueue.duration,
                    isExpanded: true,
                    onSeek: { time in musicQueue.seek(to: time) }
                )
                .padding(.horizontal, 56)
                .padding(.bottom, 10)

                bottomBar
                    .padding(.horizontal, 56)
                    .padding(.bottom, 34)
            }

            if !showQueue {
                defaultActionRail
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.28), value: showQueue)
        .onExitCommand {
            if showQueue {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showQueue = false
                }
            } else {
                isPresented = false
            }
        }
        .onPlayPauseCommand {
            musicQueue.togglePlayPause()
        }
        .onMoveCommand { direction in
            switch direction {
            case .down where !showQueue:
                withAnimation(.easeInOut(duration: 0.25)) {
                    showQueue = true
                }
            case .up where showQueue:
                withAnimation(.easeInOut(duration: 0.25)) {
                    showQueue = false
                }
            case .left where !showQueue:
                musicQueue.skipToPrevious()
            case .right where !showQueue:
                musicQueue.skipToNext()
            default:
                break
            }
        }
    }

    private var defaultStage: some View {
        VStack(spacing: 14) {
            albumArtView
                .frame(width: 344, height: 344)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.28), radius: 16, y: 10)

            HStack(spacing: 8) {
                if musicQueue.playbackState == .playing {
                    PlaybackIndicator(isPlaying: true, size: .small)
                }

                Text(trackTitle)
                    .font(.system(size: 22, weight: .medium))
                    .lineLimit(1)
            }

            Text(artistName)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var queueStage: some View {
        VStack(spacing: 24) {
            MusicQueueCarousel(musicQueue: musicQueue)
            queueControlsRow
        }
    }

    private var defaultActionRail: some View {
        VStack(spacing: 12) {
            circleButton(systemImage: "star") { }
            contextMenuButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 60)
        .padding(.top, 250)
    }

    private var queueControlsRow: some View {
        HStack(spacing: 12) {
            circleButton(systemImage: "shuffle") {
                musicQueue.toggleShuffle()
            }

            circleButton(systemImage: repeatIcon) {
                musicQueue.cycleRepeatMode()
            }

            circleButton(systemImage: "star") { }
            contextMenuButton
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("Info") { }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color.white.opacity(0.16))

            Spacer()

            HStack(spacing: 12) {
                circleButton(systemImage: "pin") { }
                circleButton(systemImage: "quote.bubble") { }
                circleButton(systemImage: "list.bullet", tint: showQueue ? Color.white.opacity(0.28) : Color.white.opacity(0.16)) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showQueue.toggle()
                    }
                }
            }
        }
    }

    private var contextMenuButton: some View {
        Button { } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(Color.white.opacity(0.16))
        .contextMenu {
            if let track = musicQueue.currentTrack {
                Button {
                    musicQueue.addNext(track: track)
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    musicQueue.addToEnd(track: track)
                } label: {
                    Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }
    }

    private func circleButton(systemImage: String, tint: Color = Color.white.opacity(0.16), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(tint)
    }

    private var albumArtView: some View {
        Group {
            if let thumbURL = albumArtURL {
                CachedAsyncImage(url: thumbURL) { phase in
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
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 54, weight: .regular))
                    .foregroundStyle(.secondary)
            }
    }

    private var albumArtBackdrop: some View {
        Group {
            if let thumbURL = albumArtURL {
                CachedAsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 90)
                            .scaleEffect(1.35)
                            .saturation(1.15)
                            .overlay {
                                LinearGradient(
                                    colors: [
                                        Color.black.opacity(0.2),
                                        Color.black.opacity(0.48),
                                        Color.black.opacity(0.72)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                            .overlay {
                                RadialGradient(
                                    colors: [Color.clear, Color.black.opacity(0.42)],
                                    center: .center,
                                    startRadius: 140,
                                    endRadius: 900
                                )
                            }
                    default:
                        fallbackBackdrop
                    }
                }
            } else {
                fallbackBackdrop
            }
        }
    }

    private var fallbackBackdrop: some View {
        LinearGradient(
            colors: [
                Color(red: 0.34, green: 0.33, blue: 0.16),
                Color(red: 0.16, green: 0.16, blue: 0.1),
                Color.black
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            RadialGradient(
                colors: [Color.white.opacity(0.08), Color.clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 520
            )
        }
    }

    private var trackTitle: String {
        musicQueue.currentTrack?.title ?? "Not Playing"
    }

    private var artistName: String {
        musicQueue.currentTrack?.artistName ?? musicQueue.currentTrack?.albumTitle ?? "Unknown Artist"
    }

    private var albumName: String {
        let value = musicQueue.currentTrack?.albumTitle ?? ""
        return value.isEmpty ? "Now Playing" : value
    }

    private var albumArtURL: URL? {
        musicQueue.currentTrack?.artwork.poster
    }

    private var repeatIcon: String {
        switch musicQueue.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}
