//
//  MusicLyricsView.swift
//  Rivulet
//
//  Lyrics overlay for Now Playing. Supports static text and timed lyrics.
//  Currently a placeholder with structure for future lyric parsing.
//

import SwiftUI

/// Parsed lyric line with optional timestamp for synced lyrics
struct LyricLine: Identifiable {
    let id = UUID()
    let timestamp: TimeInterval? // nil for static lyrics
    let text: String
}

struct MusicLyricsView: View {
    let track: MusicTrack?
    let currentTime: TimeInterval
    @Binding var isPresented: Bool

    @State private var lyrics: [LyricLine] = []
    @State private var isLoading = true
    @State private var hasLyrics = false
    @FocusState private var isFocused: Bool

    /// Whether these lyrics are synced (have timestamps)
    private var isSynced: Bool {
        lyrics.contains(where: { $0.timestamp != nil })
    }

    /// Index of the current line based on playback time
    private var currentLineIndex: Int? {
        guard isSynced else { return nil }
        let timed = lyrics.filter { $0.timestamp != nil }
        for (index, line) in timed.enumerated().reversed() {
            if let ts = line.timestamp, currentTime >= ts {
                return lyrics.firstIndex(where: { $0.id == line.id })
            }
        }
        return nil
    }

    var body: some View {
        ZStack {
            // Glass background
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header
                    .padding(.top, 60)
                    .padding(.horizontal, 80)

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if !hasLyrics {
                    Spacer()
                    noLyricsView
                    Spacer()
                } else {
                    // Lyrics content
                    lyricsContent
                }
            }
        }
        .focusable()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            loadLyrics()
        }
        .onExitCommand {
            isPresented = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(track?.title ?? "Unknown")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(track?.artistName ?? track?.albumTitle ?? "")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            Text("Lyrics")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Lyrics Content

    private var lyricsContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    Spacer(minLength: 200)

                    ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                        let isCurrentLine = currentLineIndex == index
                        Text(line.text)
                            .font(.system(size: isCurrentLine ? 32 : 26, weight: isCurrentLine ? .bold : .regular))
                            .foregroundStyle(.white.opacity(isCurrentLine ? 1.0 : 0.35))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 120)
                            .id(line.id)
                            .animation(.easeInOut(duration: 0.3), value: isCurrentLine)
                    }

                    Spacer(minLength: 200)
                }
            }
            .onChange(of: currentLineIndex) { _, newIndex in
                guard let newIndex, lyrics.indices.contains(newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    proxy.scrollTo(lyrics[newIndex].id, anchor: .center)
                }
            }
        }
        .padding(.top, 24)
    }

    // MARK: - No Lyrics

    private var noLyricsView: some View {
        VStack(spacing: 20) {
            Image(systemName: "text.quote")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.3))

            Text("No Lyrics Available")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))

            Text("Lyrics will appear here when available for the current track.")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
    }

    // MARK: - Lyric Loading

    private func loadLyrics() {
        // Stub: In the future, this would fetch lyrics from Plex metadata,
        // an external lyrics API, or parse embedded LRC data.
        //
        // Plex can store lyrics in the track metadata or as a sidecar file.
        // Synced lyrics use LRC format: [mm:ss.xx] Lyric text
        //
        // For now, we show the "No Lyrics Available" placeholder.
        isLoading = false
        hasLyrics = false
    }

    /// Parses LRC format lyrics into LyricLine array.
    /// LRC format: [mm:ss.xx] Lyric text
    /// Reserved for future use when lyrics data is available.
    static func parseLRC(_ lrcText: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let pattern = /\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)/

        for rawLine in lrcText.components(separatedBy: .newlines) {
            if let match = rawLine.firstMatch(of: pattern) {
                let minutes = Double(match.1) ?? 0
                let seconds = Double(match.2) ?? 0
                let centiseconds = Double(match.3) ?? 0
                let divisor = match.3.count == 3 ? 1000.0 : 100.0
                let timestamp = minutes * 60 + seconds + centiseconds / divisor
                let text = String(match.4).trimmingCharacters(in: .whitespaces)

                if !text.isEmpty {
                    lines.append(LyricLine(timestamp: timestamp, text: text))
                }
            } else {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("[") {
                    lines.append(LyricLine(timestamp: nil, text: trimmed))
                }
            }
        }

        return lines
    }
}
