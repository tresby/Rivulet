//
//  FocusableActionButton.swift
//  Rivulet
//
//  A focusable rounded button for the expanded-detail action row (Play pill +
//  circle buttons). Renders its own background; the caller adds the content
//  (icon / label / progress) as subviews and registers which of those should
//  invert to black on focus. On tvOS the focus engine focuses it (canBecomeFocused)
//  and Select fires `.primaryActionTriggered`; the focused appearance (scale +
//  white fill + inverted content) animates on the UIFocusAnimationCoordinator so
//  it rides the system focus animation. Mirrors the focus pattern used by the
//  below-fold cells (see BelowFoldCells.swift).
//
//  These buttons are only focusable while an ancestor (the chrome) is
//  user-interaction-enabled — i.e. in `.expandedDetail` mode, not in
//  carousel-stable — so the carousel's focusless-modal model is unaffected.
//

import UIKit

final class FocusableActionButton: UIControl {
    /// Content views recolored to black on focus (UIImageView via tintColor,
    /// UILabel via textColor). Set by the builder after adding content.
    var invertOnFocus: [UIView] = []

    /// Plain views whose backgroundColor inverts on focus — e.g. the Play
    /// progress track, which is white at rest and would vanish on the white
    /// focused fill. Focused → dark, resting → translucent white (matches
    /// SwiftUI's track color).
    var invertBackgroundOnFocus: [UIView] = []

    /// Invoked on Select (`.primaryActionTriggered`).
    var onPrimaryAction: (() -> Void)?

    private let restingFill = UIColor.white.withAlphaComponent(0.15)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = restingFill
        layer.cornerCurve = .continuous
        addTarget(self, action: #selector(primary), for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func primary() { fireOnce() }

    // On tvOS a bare UIControl's `.primaryActionTriggered` is unreliable for the
    // remote Select press (it's delivered to the FOCUSED view's press handlers).
    // Handle it here too, debounced so primaryActionTriggered + pressesEnded
    // can't double-fire. Mirrors AboutCardControl.
    private var lastFireTime: CFTimeInterval = 0
    private func fireOnce() {
        let now = CACurrentMediaTime()
        guard now - lastFireTime > 0.3 else { return }
        lastFireTime = now
        onPrimaryAction?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { return }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { fireOnce(); return }
        super.pressesEnded(presses, with: event)
    }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.transform = focused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
            self.backgroundColor = focused ? .white : self.restingFill
            for v in self.invertOnFocus {
                if let iv = v as? UIImageView { iv.tintColor = focused ? .black : .white }
                if let lb = v as? UILabel { lb.textColor = focused ? .black : .white }
            }
            for v in self.invertBackgroundOnFocus {
                v.backgroundColor = focused
                    ? UIColor.black.withAlphaComponent(0.2)
                    : UIColor.white.withAlphaComponent(0.25)
            }
        }
    }
}
