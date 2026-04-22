//
//  MusicVisualizerView.swift
//  Rivulet
//
//  Full-screen audio visualizer with animated bars.
//  Uses timer-driven simulated data as a placeholder for real audio taps.
//

import SwiftUI

struct MusicVisualizerView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var barHeights: [CGFloat] = Array(repeating: 0.1, count: 32)
    @State private var showControls = false
    @State private var animationTimer: Timer?
    @FocusState private var isFocused: Bool

    private let barCount = 32

    var body: some View {
        ZStack {
            // Background: faint album art
            albumArtBackdrop

            // Visualizer bars
            visualizerBars

            // Controls overlay (shown on interaction)
            if showControls {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .focusable()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            startAnimation()
        }
        .onDisappear {
            stopAnimation()
        }
        .onExitCommand {
            if showControls {
                showControls = false
            } else {
                isPresented = false
            }
        }
        .onPlayPauseCommand {
            musicQueue.togglePlayPause()
        }
        .onMoveCommand { _ in
            revealControls()
        }
        .animation(.easeInOut(duration: 0.3), value: showControls)
    }

    // MARK: - Visualizer Bars

    private var visualizerBars: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width * 0.8
            let barWidth = totalWidth / CGFloat(barCount * 2 - 1)
            let maxHeight = geometry.size.height * 0.6

            HStack(spacing: barWidth) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(barGradient(for: index))
                        .frame(
                            width: barWidth,
                            height: max(barWidth, maxHeight * barHeights[index])
                        )
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, geometry.size.width * 0.1)
            .padding(.bottom, geometry.size.height * 0.15)
        }
    }

    private func barGradient(for index: Int) -> some ShapeStyle {
        let position = CGFloat(index) / CGFloat(barCount - 1)
        // Gradient from blue-ish to purple-ish across the bars
        let hue = 0.55 + position * 0.15 // Range: 0.55 to 0.70
        return Color(hue: hue, saturation: 0.6, brightness: 0.9).opacity(0.7)
    }

    // MARK: - Album Art Backdrop

    private var albumArtBackdrop: some View {
        ZStack {
            Color.black

            if let url = albumArtURL {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 80)
                            .scaleEffect(1.4)
                            .opacity(0.15)
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack {
            Spacer()

            HStack(spacing: 40) {
                // Album art
                if let url = albumArtURL {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Rectangle().fill(Color(white: 0.15))
                        }
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Track info
                VStack(alignment: .leading, spacing: 4) {
                    Text(musicQueue.currentTrack?.title ?? "Not Playing")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(musicQueue.currentTrack?.artistName ?? musicQueue.currentTrack?.albumTitle ?? "")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer()

                // Playback state indicator
                if musicQueue.playbackState == .playing {
                    PlaybackIndicator(isPlaying: true, size: .large)
                } else {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 30)
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.9)
            )
        }
    }

    // MARK: - Animation

    private func startAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard musicQueue.playbackState == .playing else {
                    // When paused, smoothly decay bars
                    withAnimation(.easeOut(duration: 0.5)) {
                        for i in 0..<barCount {
                            barHeights[i] = max(0.05, barHeights[i] * 0.9)
                        }
                    }
                    return
                }

                withAnimation(.easeInOut(duration: 0.1)) {
                    for i in 0..<barCount {
                        // Simulate audio spectrum: center bars tend higher
                        let centerWeight = 1.0 - abs(CGFloat(i) / CGFloat(barCount - 1) - 0.5) * 0.6
                        let randomHeight = CGFloat.random(in: 0.1...0.95) * centerWeight
                        // Smooth transition: blend with previous value
                        barHeights[i] = barHeights[i] * 0.3 + randomHeight * 0.7
                    }
                }
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func revealControls() {
        showControls = true
        // Auto-hide after 5 seconds
        Task {
            try? await Task.sleep(for: .seconds(5))
            await MainActor.run {
                showControls = false
            }
        }
    }

    // MARK: - Helpers

    private var albumArtURL: URL? {
        musicQueue.currentTrack?.artwork.poster
    }
}
