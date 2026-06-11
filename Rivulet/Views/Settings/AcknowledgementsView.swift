//
//  AcknowledgementsView.swift
//  Rivulet
//
//  Full-screen "Licenses & Legal" overlay shown from Settings → About.
//  Lists Rivulet's own license posture plus the full text of every bundled
//  third-party open-source license (FFmpeg LGPL, libdovi MIT, Sentry MIT).
//
//  tvOS note: a plain wall of Text is not scrollable with the remote — the focus
//  engine drives scrolling. Each block is therefore .focusable(), so navigating
//  up/down moves focus and auto-scrolls the content.
//

import SwiftUI

struct AcknowledgementsView: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 0) {
                Text("Licenses & Legal")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 48)
                    .padding(.bottom, 24)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // Rivulet's own license + content posture.
                        SectionHeader(title: "About Rivulet")
                        FocusableBlock(text: OpenSourceLicenses.appLicense)

                        // Each bundled dependency: a summary block followed by its
                        // full, verbatim license text (monospaced).
                        ForEach(OpenSourceLicenses.entries) { entry in
                            SectionHeader(title: entry.name)
                            FocusableBlock(text: entry.summary)
                            ForEach(Array(paragraphs(of: entry.licenseText).enumerated()), id: \.offset) { _, para in
                                FocusableBlock(text: para, monospaced: true)
                            }
                        }
                    }
                    .frame(maxWidth: 1400, alignment: .leading)
                    .padding(.horizontal, 80)
                    .padding(.bottom, 80)
                }
            }
        }
        .onExitCommand { isPresented = false }
    }

    /// Split a license into paragraph-sized, individually focusable chunks so the
    /// tvOS focus engine can scroll through long texts.
    private func paragraphs(of text: String) -> [String] {
        text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Building blocks

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 32, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 28)
            .padding(.bottom, 4)
    }
}

/// A focusable text block. Focus is required for the surrounding ScrollView to
/// scroll on tvOS; the subtle glass background marks the focused block.
private struct FocusableBlock: View {
    let text: String
    var monospaced: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        Text(text)
            .font(monospaced ? .system(size: 22, design: .monospaced) : .system(size: 26))
            .foregroundStyle(.white.opacity(isFocused ? 0.95 : 0.65))
            .lineSpacing(monospaced ? 2 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(isFocused ? 0.12 : 0.0))
            )
            .focusable()
            .focused($isFocused)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
