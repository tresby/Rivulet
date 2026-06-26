//
//  SubtitleOverlayView.swift
//  Rivulet
//
//  SwiftUI overlay view for rendering subtitles.
//

import SwiftUI
import CoreGraphics
import UIKit

/// Overlay view that displays current subtitle cues
struct SubtitleOverlayView: View {
    @ObservedObject var subtitleManager: SubtitleManager

    /// Vertical offset from bottom (for player controls)
    var bottomOffset: CGFloat = 100

    /// Current system caption appearance. Replaced wholesale when the user
    /// changes caption settings (via CaptionAppearance.changedNotification).
    @State private var captionStyle: CaptionStyle = CaptionAppearance.current()

    /// Base caption point size at the system's default size preference (tvOS points).
    /// The system size preference (`fontScale`) multiplies this — e.g. "extra small"
    /// scales it down, "extra large" up. Anchored to a fixed point size rather than a
    /// fraction of the overlay height, which is not a reliable 1080-point surface.
    private static let baseFontSize: CGFloat = 42

    private var captionFont: Font {
        captionStyle.font(ofSize: Self.baseFontSize * captionStyle.fontScale)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Bitmap subtitle cues (PGS, DVB-SUB) — positioned absolutely
                ForEach(subtitleManager.currentBitmapCues) { cue in
                    ForEach(Array(cue.rects.enumerated()), id: \.offset) { _, rect in
                        BitmapSubtitleRectView(
                            rect: rect,
                            viewSize: geometry.size,
                            referenceWidth: cue.referenceWidth,
                            referenceHeight: cue.referenceHeight
                        )
                    }
                }

                // Text subtitle cues — anchored to bottom
                VStack {
                    Spacer()

                    if !subtitleManager.currentCues.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(subtitleManager.currentCues) { cue in
                                SubtitleTextView(text: cue.text, font: captionFont, style: captionStyle)
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.bottom, bottomOffset)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .allowsHitTesting(false)  // Don't interfere with player controls
        .onAppear { captionStyle = CaptionAppearance.current() }
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.changedNotification)) { _ in
            captionStyle = CaptionAppearance.current()
        }
        // Settings can change while the app is suspended; re-read on foreground.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            captionStyle = CaptionAppearance.current()
        }
    }
}

/// Individual subtitle text styled from the system caption appearance settings.
private struct SubtitleTextView: View {
    let text: String

    /// Resolved caption font (system font descriptor at the size Apple bases on the
    /// presentation height, scaled by the system size preference).
    let font: Font

    /// System caption appearance (foreground/background/edge).
    let style: CaptionStyle

    var body: some View {
        // The system background box is applied for every edge style (it stays
        // invisible when the system background opacity is 0 — honoring "no box").
        styledText
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(style.backgroundColor.opacity(style.backgroundOpacity))
            )
    }

    /// The text with its system edge treatment (outline / drop shadow / plain).
    @ViewBuilder
    private var styledText: some View {
        switch style.edge {
        case .uniform:
            // 8-direction black outline (no per-character stroke on tvOS).
            let offsets: [(CGFloat, CGFloat)] = [
                (-2, -2), ( 0, -2), ( 2, -2),
                (-2,  0),           ( 2,  0),
                (-2,  2), ( 0,  2), ( 2,  2)
            ]
            ZStack {
                ForEach(Array(offsets.enumerated()), id: \.offset) { _, delta in
                    base
                        .foregroundColor(.black)
                        .offset(x: delta.0, y: delta.1)
                }
                base.foregroundColor(style.foreground)
            }

        case .dropShadow:
            base
                .foregroundColor(style.foreground)
                .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)

        default:
            base.foregroundColor(style.foreground)
        }
    }

    private var base: some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(.center)
            .lineLimit(4)
    }
}

/// Renders a single bitmap subtitle rect as a CGImage, positioned in video coordinates
private struct BitmapSubtitleRectView: View {
    let rect: BitmapSubtitleRect
    let viewSize: CGSize
    /// Codec-reported reference resolution that the rect coordinates are authored
    /// against. 0 means the codec didn't report it; fall back to the HD spec
    /// (1920×1080), which matches Blu-ray PGS authoring.
    let referenceWidth: Int
    let referenceHeight: Int

    var body: some View {
        if let image = createImage() {
            let refW: CGFloat = referenceWidth > 0 ? CGFloat(referenceWidth) : 1920
            let refH: CGFloat = referenceHeight > 0 ? CGFloat(referenceHeight) : 1080
            let scaleX = viewSize.width / refW
            let scaleY = viewSize.height / refH
            let scaledWidth = CGFloat(rect.width) * scaleX
            let scaledHeight = CGFloat(rect.height) * scaleY
            let scaledX = CGFloat(rect.x) * scaleX
            let scaledY = CGFloat(rect.y) * scaleY

            Image(decorative: image, scale: 1.0)
                .resizable()
                .frame(width: scaledWidth, height: scaledHeight)
                .position(x: scaledX + scaledWidth / 2, y: scaledY + scaledHeight / 2)
        }
    }

    private func createImage() -> CGImage? {
        let width = rect.width
        let height = rect.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let expectedSize = height * bytesPerRow
        guard rect.imageData.count >= expectedSize else { return nil }

        return rect.imageData.withUnsafeBytes { rawBuf -> CGImage? in
            guard let baseAddress = rawBuf.baseAddress else { return nil }

            guard let provider = CGDataProvider(data: rect.imageData as CFData) else { return nil }

            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.gray

        SubtitleOverlayView(
            subtitleManager: {
                let manager = SubtitleManager()
                // Note: In real usage, cues come from parsed subtitle file
                return manager
            }()
        )
    }
}
