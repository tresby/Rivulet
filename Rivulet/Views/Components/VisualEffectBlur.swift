//
//  VisualEffectBlur.swift
//  Rivulet
//
//  A tvOS-safe frosted blur for SwiftUI. tvOS has no systemMaterial blur styles
//  (those are iOS-only), so wrap a UIVisualEffectView with a legacy
//  `UIBlurEffect.Style`. Used by full-screen SwiftUI overlays (e.g. the sidebar
//  "Applying…" cover). For card popups, prefer the UIKit `InfoPopupViewController`
//  / `ConfirmationPopupViewController` chrome, which use Liquid Glass.
//

import SwiftUI
import UIKit

struct VisualEffectBlur: UIViewRepresentable {
    var style: UIBlurEffect.Style = .dark

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
