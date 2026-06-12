//
//  WhatsNewView.swift
//  Rivulet
//
//  Shows a one-time "What's New" overlay when the app updates
//  to a version with a changelog entry.
//

import SwiftUI


struct WhatsNewView: View {
    @Binding var isPresented: Bool
    let version: String

    @FocusState private var focusedItem: FocusItem?

    private enum FocusItem: Hashable {
        case feature(Int)
        case continueButton
    }

    private var features: [String] {
        Self.features(for: version) ?? []
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            card
            Spacer(minLength: 0)
        }
        .onAppear {
            focusedItem = .continueButton
        }
        .onExitCommand {
            isPresented = false
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            // Header (fixed above the scroll area)
            VStack(spacing: 8) {
                Text("What's New")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)

                Text("Version \(version)")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 40)
            .padding(.bottom, 24)

            // Scrollable feature list. Each row is focusable so the
            // tvOS focus engine auto-scrolls the ScrollView when the
            // user navigates up/down through the items.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                        featureRow(text: feature, isFocused: focusedItem == .feature(index))
                            .focusable(true)
                            .focused($focusedItem, equals: .feature(index))
                            .focusEffectDisabled()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: 460)

            // Continue button (fixed below the scroll area) — always
            // visible and receives initial focus.
            Button {
                isPresented = false
            } label: {
                Text("Continue")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(focusedItem == .continueButton ? .black : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(focusedItem == .continueButton ? .white : .white.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                focusedItem == .continueButton ? .clear : .white.opacity(0.15),
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)
            .focused($focusedItem, equals: .continueButton)
            .focusEffectDisabled()
            .scaleEffect(focusedItem == .continueButton ? 1.04 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focusedItem)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 36)
        }
        .frame(width: 620)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.black.opacity(0.3))
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private func featureRow(text: String, isFocused: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(.white.opacity(isFocused ? 0.9 : 0.5))
                .frame(width: 8, height: 8)
                .padding(.top, 13)

            Text(text)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(isFocused ? 1.0 : 0.85))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? .white.opacity(0.14) : .clear)
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
    }

    // MARK: - Changelog Data

    static let changelogs: [(version: String, features: [String])] = [
        ("1.0.0 (50)", [
            "Refactored most views to UIKit. Performance should be much better.",
            "Added AetherEngine as a third video player option.",
            "Bug fixes.",
            "Live TV fixes coming soon!",
        ]),
        ("1.0.0 (47)", [
            "New Discover page — browse Popular, Top Rated, Now Playing, and Upcoming content from TMDB",
            "Plex Watchlist integration — saved items appear on Home and you can add/remove from anywhere",
            "Hero bookmark button now toggles your Plex Watchlist. Mark Watched moved to the detail page",
        ]),
        ("1.0.0 (46)", [
            "Fixed watched episodes not automatically playing",
            "Fixed some animation jank",
            "Updated heros to be apple-esque. Not perfect yet",
            "Fixed library sorting",
        ]),
        ("1.0.0 (44)", [
            "Built a completely custom video player using ffmpeg and internal tvOS tools. The end-goal is playback as smooth as Infuse. Its working well in all my tests, but please open any issues if you experience them",
            "Re-styled many GUI elements to match Apple TV+ style and functionality",
            "Apples built-in player (AVPlayer) can be used if desired. Toggle in settings.",
            "Currently re-working the music library style to match the Apple Music app, and am working on functionality to match PlexAmp. Its a WIP now but wanted to get something out.",
        ]),
        ("1.0.0 (40)", [
            "Fun depth effects on posters, because why not",
            "Redesigned season and episode navigation for TV shows",
            "Sort libraries by title, date added, rating, and more",
            "Option to hide recently added from library views",
            "Smoother video playback when Match Content is off",
            "Continuing Dolby Vision improvements",
            "General performance and stability improvements",
        ]),
        ("1.0.0 (38)", [
            "Faster video startup",
            "Default sizing is slightly larger",
            "Display Size setting now affects all sizes",
            "Improved Dolby Vision support for more video formats",
            "Playback now integrates with Apple's Now Playing for control from other Apple devices",
            "Scroll down an episode details page to get to Seasons and episode list",
        ]),
        ("1.0.0 (37)", [
            "You can now save your PIN for Plex Home profiles",
            "Live TV is more reliable with automatic stream recovery",
            "Support for more controller types",
            "PIP now works in Live TV",
            "Better multiview handling in Live TV",
            "Live TV scrubbing controls",
            "Continuuing efforts to stop audio buffer on HomePods",
            "Only show Post Video screen on tv shows with a next up episode",
        ]),
        ("1.0.0 (36)", [
            "Trying an experimental Dolby Vision player; If DV does not work, or works well, let me know",
            "Added Plex Home Account support. Enable it in settings",
            "Added shuffle buttons to Seasons and Series",
            "Library sections now appear individually on Home - Long-press libraries to toggle Home visibility",
            "Fixed navigation bugs",
            "Fixed some Add Live TV GUI issues",
            "Fixed some Live TV endpoint issues and added more error logging to pinpoint more",
            "Fixed audio not stopping",
            "Added Changelog popup and section in settings",
            "Removed percentage from Post Video summary",
            "Added background to post video summary"
        ]),
    ]

    static func features(for version: String) -> [String]? {
        changelogs.first(where: { $0.version == version })?.features
    }
}
