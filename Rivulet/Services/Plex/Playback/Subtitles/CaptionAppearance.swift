import SwiftUI
import CoreText
import MediaAccessibility

// MARK: - CaptionStyle

/// Snapshot of the system caption appearance preferences.
struct CaptionStyle: Equatable {

    /// Text/foreground color.
    var foreground: Color

    /// Character-cell background color.
    var backgroundColor: Color

    /// Opacity of the character-cell background (0...1).
    var backgroundOpacity: Double

    /// Font size multiplier derived from the system relative-character-size preference.
    /// Applied on top of the size Apple bases on the presentation (view) height.
    var fontScale: CGFloat

    /// System caption font descriptor. `nil` falls back to the system sans font.
    var fontDescriptor: CTFontDescriptor?

    /// Text edge (shadow/raised/etc.) style.
    var edge: Edge

    enum Edge: Equatable {
        case none
        case dropShadow
        case raised
        case depressed
        case uniform
    }

    /// Builds the SwiftUI font for the system caption settings at a concrete point size.
    /// Uses the configured caption font descriptor when available.
    func font(ofSize size: CGFloat) -> Font {
        if let fontDescriptor {
            return Font(CTFontCreateWithFontDescriptor(fontDescriptor, size, nil))
        }
        return .system(size: size, weight: .medium)
    }

    static let `default` = CaptionStyle(
        foreground: .white,
        backgroundColor: .black,
        backgroundOpacity: 0.75,
        fontScale: 1.0,
        fontDescriptor: nil,
        edge: .dropShadow
    )

    static func == (lhs: CaptionStyle, rhs: CaptionStyle) -> Bool {
        lhs.foreground == rhs.foreground
            && lhs.backgroundColor == rhs.backgroundColor
            && lhs.backgroundOpacity == rhs.backgroundOpacity
            && lhs.fontScale == rhs.fontScale
            && lhs.edge == rhs.edge
            && descriptorsEqual(lhs.fontDescriptor, rhs.fontDescriptor)
    }

    private static func descriptorsEqual(_ a: CTFontDescriptor?, _ b: CTFontDescriptor?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (l?, r?): return CFEqual(l, r)
        default: return false
        }
    }
}

// MARK: - CaptionAppearance

enum CaptionAppearance {

    /// Clamps a MediaAccessibility relative-character-size value to a usable font scale.
    ///
    /// `MACaptionAppearanceGetRelativeCharacterSize` already returns the size as a
    /// multiplicative scale factor (≈1.0 at the default), NOT an offset — so it is
    /// used directly. A non-positive value means "unset"; treat that as 1.0.
    static func fontScale(forRelativeSize relative: CGFloat) -> CGFloat {
        guard relative > 0 else { return 1.0 }
        return min(max(relative, 0.5), 2.0)
    }

    /// Reads the current system caption style from MediaAccessibility.
    ///
    /// Uses the `.user` domain so that user-configured overrides take effect.
    /// Each value is fetched with `.useValue` so the system value is authoritative.
    static func current() -> CaptionStyle {
        var behavior = MACaptionAppearanceBehavior.useValue

        // Foreground color
        let fgUnmanaged = MACaptionAppearanceCopyForegroundColor(.user, &behavior)
        let foreground = Color(fgUnmanaged.takeRetainedValue() as CGColor)

        // Background color + opacity — the box drawn directly behind the glyphs.
        let bgCG = MACaptionAppearanceCopyBackgroundColor(.user, &behavior).takeRetainedValue()
        let bgOpacity = Double(MACaptionAppearanceGetBackgroundOpacity(.user, &behavior))

        // Window color + opacity — the larger region box. Several built-in styles
        // express their "background" via the window rather than the character
        // background, so fall back to it when the character background is clear.
        let windowCG = MACaptionAppearanceCopyWindowColor(.user, &behavior).takeRetainedValue()
        let windowOpacity = Double(MACaptionAppearanceGetWindowOpacity(.user, &behavior))

        let useWindow = bgOpacity <= 0.01 && windowOpacity > 0.01
        let backgroundColor = Color(useWindow ? windowCG : bgCG)
        let backgroundOpacity = useWindow ? windowOpacity : bgOpacity

        // Font scale
        let relative = MACaptionAppearanceGetRelativeCharacterSize(.user, &behavior)
        let scale = fontScale(forRelativeSize: relative)

        // Font (system caption font descriptor)
        let fontDescriptor = MACaptionAppearanceCopyFontDescriptorForStyle(.user, &behavior, .default)
            .takeRetainedValue()

        // Edge style
        let maEdge = MACaptionAppearanceGetTextEdgeStyle(.user, &behavior)
        let edge: CaptionStyle.Edge
        switch maEdge {
        case .dropShadow: edge = .dropShadow
        case .raised:     edge = .raised
        case .depressed:  edge = .depressed
        case .uniform:    edge = .uniform
        default:          edge = .none
        }

        #if DEBUG
        print("""
        [CaptionAppearance] relative=\(relative) scale=\(scale) \
        bgOpacity=\(bgOpacity) windowOpacity=\(windowOpacity) \
        usingWindow=\(useWindow) effectiveBgOpacity=\(backgroundOpacity) edge=\(edge)
        """)
        #endif

        return CaptionStyle(
            foreground: foreground,
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            fontScale: scale,
            fontDescriptor: fontDescriptor,
            edge: edge
        )
    }

    /// Posted by the system whenever the user changes caption appearance settings.
    ///
    /// Bridged from `kMACaptionAppearanceSettingsChangedNotification`.
    static let changedNotification = Notification.Name(
        kMACaptionAppearanceSettingsChangedNotification as String
    )
}
