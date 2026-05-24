//
//  LibrarySettingsView.swift
//  Rivulet
//
//  Library visibility and ordering settings
//

import SwiftUI

struct LibrarySettingsView: View {
    @Binding var focusedSettingId: String?
    @StateObject private var dataStore = PlexDataStore.shared
    @StateObject private var librarySettings = LibrarySettingsManager.shared
    @State private var reorderingLibrary: PlexLibrary?

    init(focusedSettingId: Binding<String?> = .constant(nil)) {
        self._focusedSettingId = focusedSettingId
    }

    var body: some View {
        Group {
            if dataStore.libraries.isEmpty {
                Text("Connect to a Plex server to manage library visibility.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ForEach(orderedLibraries, id: \.key) { library in
                    LibraryVisibilityRow(
                        library: library,
                        isVisible: librarySettings.isLibraryVisible(library.key),
                        isShownOnHome: (library.isVideoLibrary || library.isMusicLibrary) ? librarySettings.isLibraryShownOnHome(library.key) : nil,
                        onToggle: {
                            librarySettings.toggleVisibility(for: library.key)
                        },
                        onReorder: {
                            reorderingLibrary = library
                        },
                        onToggleHome: {
                            let allMediaKeys = orderedLibraries
                                .filter { $0.isVideoLibrary || $0.isMusicLibrary }
                                .map { $0.key }
                            librarySettings.toggleHomeVisibility(for: library.key, allLibraryKeys: allMediaKeys)
                        },
                        onFocusChange: { if $0 { focusedSettingId = "libraryRow" } }
                    )
                }

                SettingsActionRow(
                    title: "Add All",
                    action: {
                        librarySettings.showAllLibraries(orderedLibraries.map { $0.key })
                    },
                    onFocusChange: { if $0 { focusedSettingId = "addAllLibraries" } }
                )

                SettingsActionRow(
                    title: "Remove All",
                    isDestructive: true,
                    action: {
                        librarySettings.hideAllLibraries(orderedLibraries.map { $0.key })
                    },
                    onFocusChange: { if $0 { focusedSettingId = "removeAllLibraries" } }
                )
            }
        }
        .sheet(item: $reorderingLibrary) { library in
            LibraryReorderSheet(
                library: library,
                librarySettings: librarySettings,
                allLibraries: orderedLibraries,
                onDismiss: { reorderingLibrary = nil }
            )
        }
        .onAppear {
            // Refresh against the server every time the user enters
            // this screen — they're explicitly in "manage my libraries"
            // territory, so a freshly-added Plex library should be
            // visible here without an app restart. Complements the
            // scenePhase=.active auto-refresh wired in ContentView for
            // the silent case.
            Task { await dataStore.refreshLibraries() }
        }
    }

    /// Libraries sorted by user preference
    private var orderedLibraries: [PlexLibrary] {
        librarySettings.sortLibraries(dataStore.libraries.filter { $0.isVideoLibrary || $0.isMusicLibrary })
    }
}

// MARK: - Library Visibility Row

private struct LibraryVisibilityRow: View {
    let library: PlexLibrary
    let isVisible: Bool
    let isShownOnHome: Bool?
    let onToggle: () -> Void
    let onReorder: () -> Void
    let onToggleHome: () -> Void
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool

    private var iconName: String {
        switch library.type {
        case "movie": return "film.fill"
        case "show": return "tv.fill"
        case "artist": return "music.note"
        case "photo": return "photo.fill"
        default: return "folder.fill"
        }
    }

    private var iconColor: Color {
        switch library.type {
        case "movie": return .blue
        case "show": return .purple
        case "artist": return .pink
        case "photo": return .green
        default: return .gray
        }
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(iconColor.gradient)
                        .frame(width: 64, height: 64)

                    Image(systemName: iconName)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(library.title)
                        .font(.system(size: 32))

                    if let showOnHome = isShownOnHome {
                        Text(showOnHome ? "On Home" : "Hidden from Home")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(isVisible ? "On" : "Off")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
        }
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
        .contextMenu {
            Button { onReorder() } label: {
                Label("Reorder", systemImage: "arrow.up.arrow.down")
            }

            if isShownOnHome != nil {
                Button { onToggleHome() } label: {
                    if isShownOnHome == true {
                        Label("Hide from Home", systemImage: "house")
                    } else {
                        Label("Show on Home", systemImage: "house.fill")
                    }
                }
            }
        }
    }
}

// MARK: - Library Reorder Sheet

struct LibraryReorderSheet: View {
    let library: PlexLibrary
    @ObservedObject var librarySettings: LibrarySettingsManager
    let allLibraries: [PlexLibrary]
    let onDismiss: () -> Void

    @FocusState private var focusedButton: ReorderButton?

    private enum ReorderButton: Hashable {
        case up, down, done
    }

    private var currentIndex: Int? {
        let sortedLibraries = librarySettings.sortLibraries(allLibraries)
        return sortedLibraries.firstIndex(where: { $0.key == library.key })
    }

    private var canMoveUp: Bool {
        guard let index = currentIndex else { return false }
        return index > 0
    }

    private var canMoveDown: Bool {
        guard let index = currentIndex else { return false }
        let sortedLibraries = librarySettings.sortLibraries(allLibraries)
        return index < sortedLibraries.count - 1
    }

    private var positionText: String {
        let sortedLibraries = librarySettings.sortLibraries(allLibraries)
        guard let index = currentIndex else { return "Reorder Library" }
        return "Position \(index + 1) of \(sortedLibraries.count)"
    }

    private func moveUp() {
        guard let orderIndex = librarySettings.libraryOrder.firstIndex(of: library.key),
              orderIndex > 0 else { return }
        librarySettings.moveLibrary(from: orderIndex, to: orderIndex - 1)
    }

    private func moveDown() {
        guard let orderIndex = librarySettings.libraryOrder.firstIndex(of: library.key),
              orderIndex < librarySettings.libraryOrder.count - 1 else { return }
        librarySettings.moveLibrary(from: orderIndex, to: orderIndex + 2)
    }

    var body: some View {
        VStack(spacing: 36) {
            VStack(spacing: 18) {
                Text(library.title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)

                Text(positionText)
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 48)

            VStack(spacing: 12) {
                Button {
                    moveUp()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 26, weight: .semibold))
                        Text("Move Up")
                            .font(.system(size: 28, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .focused($focusedButton, equals: .up)
                .disabled(!canMoveUp)

                Button {
                    moveDown()
                } label: {
                    HStack {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 26, weight: .semibold))
                        Text("Move Down")
                            .font(.system(size: 28, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .focused($focusedButton, equals: .down)
                .disabled(!canMoveDown)
            }
            .padding(.horizontal, 56)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .tint(.blue)
            .focused($focusedButton, equals: .done)
            .padding(.horizontal, 56)
            .padding(.bottom, 48)
        }
        .frame(width: 480)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.black.opacity(0.3))
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if canMoveUp {
                    focusedButton = .up
                } else if canMoveDown {
                    focusedButton = .down
                } else {
                    focusedButton = .done
                }
            }
        }
        .onExitCommand {
            onDismiss()
        }
    }
}

#Preview {
    LibrarySettingsView()
}
