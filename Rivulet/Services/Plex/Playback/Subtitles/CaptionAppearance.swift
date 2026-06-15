import SwiftUI
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
    var fontScale: CGFloat

    /// Text edge (shadow/raised/etc.) style.
    var edge: Edge

    enum Edge: Equatable {
        case none
        case dropShadow
        case raised
        case depressed
        case uniform
    }

    static let `default` = CaptionStyle(
        foreground: .white,
        backgroundColor: .black,
        backgroundOpacity: 0.75,
        fontScale: 1.0,
        edge: .dropShadow
    )
}

// MARK: - CaptionAppearance

enum CaptionAppearance {

    /// Clamps a MediaAccessibility relative-character-size value to a usable font scale.
    ///
    /// The MA API returns a relative adjustment (e.g. -0.5, 0, 0.5). This converts it
    /// to a multiplicative scale factor in [0.5, 2.0].
    static func fontScale(forRelativeSize relative: CGFloat) -> CGFloat {
        min(max(1.0 + relative, 0.5), 2.0)
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

        // Background color
        let bgUnmanaged = MACaptionAppearanceCopyBackgroundColor(.user, &behavior)
        let bgColor = Color(bgUnmanaged.takeRetainedValue() as CGColor)

        // Background opacity
        let bgOpacity = Double(MACaptionAppearanceGetBackgroundOpacity(.user, &behavior))

        // Font scale
        let relative = MACaptionAppearanceGetRelativeCharacterSize(.user, &behavior)
        let scale = fontScale(forRelativeSize: relative)

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

        return CaptionStyle(
            foreground: foreground,
            backgroundColor: bgColor,
            backgroundOpacity: bgOpacity,
            fontScale: scale,
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
