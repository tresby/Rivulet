//
//  AetherSubtitleOverlayView.swift
//  Rivulet
//
//  SwiftUI overlay that renders subtitle cues from an AetherSubtitleModel.
//  Mounted in AVPlayerViewController.contentOverlayView (above video, below
//  AVKit's transport bar) via a retained UIHostingController child VC.
//  See AetherPlayerViewController.swift for the mounting code.
//
//  Text layout reference: Sodalite/Player/Subtitles/SubtitleOverlayView.swift
//  Key divergence: we mount in contentOverlayView, Sodalite mounts in self.view
//  because it suppresses AVKit chrome. We keep AVKit's native controls.
//
//  controlsVisible insets:
//    true  -> 280 pt bottom padding (clears the transport bar gradient band)
//    false -> 80 pt bottom padding (minimal clear of screen edge)
//

import SwiftUI

// MARK: - AetherSubtitleOverlayView

struct AetherSubtitleOverlayView: View {

    @ObservedObject var model: AetherSubtitleModel

    /// Current caption appearance. Replaced wholesale on CaptionAppearance changes.
    var style: CaptionStyle

    /// True when AVKit's transport bar is visible; lifts text above it.
    var controlsVisible: Bool

    // Bottom padding constants (pts).
    private static let controlsVisiblePadding: CGFloat = 280
    private static let defaultPadding: CGFloat = 80

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Bitmap cues: render all simultaneously (PGS can emit multiples).
                ForEach(model.activeCues.filter(\.isBitmap), id: \.id) { cue in
                    if case .image(let cgImage, let pos) = cue.body {
                        bitmapCue(cgImage: cgImage, position: pos, size: geo.size)
                    }
                }

                // Text cues: stack vertically at bottom-centre.
                VStack(spacing: 4) {
                    ForEach(model.activeCues.filter(\.isText), id: \.id) { cue in
                        if case .text(let string) = cue.body {
                            styledText(string, size: geo.size)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                .padding(.bottom, controlsVisible
                    ? Self.controlsVisiblePadding
                    : Self.defaultPadding)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Bitmap cue

    @ViewBuilder
    private func bitmapCue(cgImage: CGImage, position: CGRect, size: CGSize) -> some View {
        let frameW = position.width  * size.width
        let frameH = position.height * size.height
        let originX = position.minX  * size.width
        let originY = position.minY  * size.height

        Image(decorative: cgImage, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .frame(width: frameW, height: frameH)
            .offset(x: originX, y: originY)
    }

    // MARK: - Text cue

    @ViewBuilder
    private func styledText(_ string: String, size: CGSize) -> some View {
        let maxWidth = max(0, size.width - 240)
        let baseFont = Font.system(size: 28 * style.fontScale, weight: .semibold)

        switch style.edge {
        case .dropShadow:
            Text(string)
                .font(baseFont)
                .foregroundStyle(style.foreground)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(style.backgroundColor.opacity(style.backgroundOpacity))
                )
                .frame(maxWidth: maxWidth)

        case .uniform:
            // 8-direction black outline (no per-character stroke on tvOS).
            let offsets: [(CGFloat, CGFloat)] = [
                (-2, -2), ( 0, -2), ( 2, -2),
                (-2,  0),           ( 2,  0),
                (-2,  2), ( 0,  2), ( 2,  2)
            ]
            ZStack {
                ForEach(Array(offsets.enumerated()), id: \.offset) { _, delta in
                    Text(string)
                        .font(baseFont)
                        .foregroundStyle(Color.black)
                        .multilineTextAlignment(.center)
                        .offset(x: delta.0, y: delta.1)
                }
                Text(string)
                    .font(baseFont)
                    .foregroundStyle(style.foreground)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: maxWidth)

        default:
            // .none / .raised / .depressed: solid background box.
            Text(string)
                .font(baseFont)
                .foregroundStyle(style.foreground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(style.backgroundColor.opacity(style.backgroundOpacity))
                )
                .frame(maxWidth: maxWidth)
        }
    }
}

// MARK: - AetherSubtitleCue helpers

private extension AetherSubtitleCue {
    var isText: Bool {
        if case .text = body { return true }
        return false
    }
    var isBitmap: Bool {
        if case .image = body { return true }
        return false
    }
}
