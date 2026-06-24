//
//  SettingsModalFlows.swift
//  Rivulet
//
//  Thin SwiftUI wrappers presented as focus-contained modals FROM the UIKit
//  Settings pages (same proven pattern as the Plex sign-in modal). They reuse
//  the existing, working SwiftUI leaf views — the numeric PIN pad and the
//  text-entry add-source forms — which are tightly coupled to SwiftUI's
//  List/keyboard environment and not worth re-deriving in UIKit. Each takes an
//  explicit `onClose` so dismissal is deterministic (the host VC dismisses the
//  presentation and reloads its row list). Presented modals live outside the
//  sidebar shell, so the focus wedge does not apply here.
//

import SwiftUI

// MARK: - Profile PIN entry

/// Wraps `PinEntrySheet` with the verify-and-switch logic from
/// `UserProfileSettingsView.verifyAndSwitch`. Calls `onClose` on success or
/// cancel; shows an inline error on a wrong PIN.
struct ProfilePinFlow: View {
    let user: PlexHomeUser
    let onClose: () -> Void

    @StateObject private var profileManager = PlexUserProfileManager.shared
    @State private var error: String?

    init(user: PlexHomeUser, initialError: String?, onClose: @escaping () -> Void) {
        self.user = user
        self.onClose = onClose
        _error = State(initialValue: initialError)
    }

    var body: some View {
        PinEntrySheet(
            user: user,
            error: $error,
            onSubmit: { pin, rememberPin in
                Task {
                    let success = await profileManager.selectUser(user, pin: pin)
                    if success {
                        if rememberPin { profileManager.rememberPin(pin, for: user) }
                        onClose()
                    } else {
                        error = "Incorrect PIN. Please try again."
                    }
                }
            },
            onCancel: onClose
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.6))
    }
}

// MARK: - Add Live TV source flow

/// Hosts the existing add-source picker + forms in a self-contained
/// `NavigationStack`. Sub-pages push within the modal; Menu pops a sub-page or
/// closes the modal at the picker root. The forms call `onComplete` (→ close)
/// after a source is added.
struct AddLiveTVSourceFlow: View {
    let onClose: () -> Void

    @State private var path: [SettingsPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                AddLiveTVSourcePickerView(focusedSettingId: .constant(nil),
                                          onNavigate: { path.append($0) })
            }
            .navigationTitle("Add Live TV Source")
            .navigationDestination(for: SettingsPage.self) { page in
                List {
                    switch page {
                    case .addPlexLiveTV:
                        AddPlexLiveTVSettingsView(focusedSettingId: .constant(nil), onComplete: onClose)
                    case .addDispatcharrSource:
                        AddDispatcharrSettingsView(focusedSettingId: .constant(nil), onComplete: onClose)
                    case .addM3USource:
                        AddM3USettingsView(focusedSettingId: .constant(nil), onComplete: onClose)
                    default:
                        EmptyView()
                    }
                }
                .navigationTitle(page.title)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.85))
        .onExitCommand {
            if path.isEmpty { onClose() } else { path.removeLast() }
        }
    }
}

