//
//  HeroButtonRowView.swift
//  Rivulet
//
//  Native UIKit version of `HeroButtonRow`. Four focusable buttons:
//
//    [ Play ] [ 🔖 ] [ ⓘ ] [ › ]
//
//  Focus styling mirrors the SwiftUI `AppStoreActionButtonStyle`:
//    - unfocused: white-20% background + ultra-thin material overlay +
//      white-20% 0.5pt stroke, scale 1.0
//    - focused: solid white background, no stroke, scale 1.08
//    - pressed: -5% scale
//
//  Animation: spring(response 0.25, damping 0.8) for focus,
//             spring(response 0.15, damping 0.9) for press.
//

import UIKit

@MainActor
final class HeroButtonRowView: UIView {

    enum HeroButton {
        case play, watchlist, info, next
    }

    // MARK: - Buttons

    let playButton = HeroPillButton()
    let watchlistButton = HeroCircleButton()
    let infoButton = HeroCircleButton()
    let nextButton = HeroCircleButton()

    private let stack = UIStackView()

    // MARK: - State

    var canAdvance: Bool = false {
        didSet {
            nextButton.isHidden = !canAdvance
        }
    }

    var isOnWatchlist: Bool = false {
        didSet {
            let name = isOnWatchlist ? "bookmark.fill" : "bookmark"
            watchlistButton.setImage(UIImage(systemName: name), for: .normal)
        }
    }

    var isResolvingPlay: Bool = false {
        didSet {
            playButton.isShowingSpinner = isResolvingPlay
        }
    }

    // MARK: - Callbacks

    var onPlay: (() -> Void)?
    var onWatchlist: (() -> Void)?
    var onInfo: (() -> Void)?
    var onNext: (() -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        playButton.title = "Play"
        playButton.iconImage = UIImage(systemName: "play.fill")
        watchlistButton.setImage(UIImage(systemName: "bookmark"), for: .normal)
        infoButton.setImage(UIImage(systemName: "info.circle"), for: .normal)
        nextButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)

        playButton.accessibilityLabel = "Play"
        watchlistButton.accessibilityLabel = "Toggle Watchlist"
        infoButton.accessibilityLabel = "More info"
        nextButton.accessibilityLabel = "Next featured item"

        playButton.addTarget(self, action: #selector(playTapped), for: .primaryActionTriggered)
        watchlistButton.addTarget(self, action: #selector(watchlistTapped), for: .primaryActionTriggered)
        infoButton.addTarget(self, action: #selector(infoTapped), for: .primaryActionTriggered)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .primaryActionTriggered)

        stack.axis = .horizontal
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(playButton)
        stack.addArrangedSubview(watchlistButton)
        stack.addArrangedSubview(infoButton)
        stack.addArrangedSubview(nextButton)
        nextButton.isHidden = true

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    /// Default focus target is Play; if Play is hidden (never, but defensive)
    /// fall back to Watchlist.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if !playButton.isHidden { return [playButton] }
        if !watchlistButton.isHidden { return [watchlistButton] }
        return super.preferredFocusEnvironments
    }

    // MARK: - Targets

    @objc private func playTapped() { onPlay?() }
    @objc private func watchlistTapped() { onWatchlist?() }
    @objc private func infoTapped() { onInfo?() }
    @objc private func nextTapped() { onNext?() }
}

// MARK: - Pill button (Play)

/// 66pt-tall pill button with an SF Symbol icon + label. Switches the icon
/// for a `UIActivityIndicatorView` while `isShowingSpinner` is true.
@MainActor
final class HeroPillButton: UIControl {

    var title: String = "" {
        didSet { titleLabel.text = title }
    }

    var iconImage: UIImage? {
        didSet {
            iconView.image = iconImage?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        }
    }

    var isShowingSpinner: Bool = false {
        didSet {
            iconView.isHidden = isShowingSpinner
            if isShowingSpinner {
                spinner.startAnimating()
            } else {
                spinner.stopAnimating()
            }
        }
    }

    private let background = UIView()
    /// SwiftUI's `.ultraThinMaterial` is the second background under the
    /// solid fill (it shows through when unfocused, fades out on focus).
    /// On tvOS the modern system materials (`.systemUltraThinMaterial*`,
    /// `.systemThinMaterial*`) are iOS-only, so SwiftUI falls back to a
    /// traditional blur internally. We use `UIBlurEffect(style: .regular)`
    /// which is the closest publicly-available tvOS equivalent — it
    /// auto-adapts to the user interface style and renders as a thin
    /// dark blur over the hero backdrop.
    private let materialBackground = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let strokeLayer = CAShapeLayer()
    private let contentStack = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private let cornerRadius: CGFloat = 33  // height/2 (height=66)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = false

        background.translatesAutoresizingMaskIntoConstraints = false
        background.layer.cornerRadius = cornerRadius
        background.layer.cornerCurve = .continuous
        background.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        background.isUserInteractionEnabled = false
        addSubview(background)

        materialBackground.translatesAutoresizingMaskIntoConstraints = false
        materialBackground.layer.cornerRadius = cornerRadius
        materialBackground.layer.cornerCurve = .continuous
        materialBackground.clipsToBounds = true
        materialBackground.isUserInteractionEnabled = false
        addSubview(materialBackground)

        strokeLayer.fillColor = UIColor.clear.cgColor
        strokeLayer.strokeColor = UIColor.white.withAlphaComponent(0.2).cgColor
        strokeLayer.lineWidth = 0.5
        layer.addSublayer(strokeLayer)

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .white

        contentStack.axis = .horizontal
        contentStack.spacing = 10
        contentStack.alignment = .center
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.isUserInteractionEnabled = false
        contentStack.addArrangedSubview(spinner)
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 66),

            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),

            materialBackground.topAnchor.constraint(equalTo: topAnchor),
            materialBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            materialBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialBackground.trailingAnchor.constraint(equalTo: trailingAnchor),

            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),

            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])

        iconView.isHidden = isShowingSpinner
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        strokeLayer.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                        cornerRadius: cornerRadius).cgPath
        strokeLayer.frame = bounds
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [self] in
            applyFocusVisuals(focused: nowFocused)
        }
    }

    private func applyFocusVisuals(focused: Bool) {
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
            self.background.backgroundColor = focused ? .white : UIColor.white.withAlphaComponent(0.2)
            self.materialBackground.alpha = focused ? 0 : 1
            self.strokeLayer.opacity = focused ? 0 : 1
            self.titleLabel.textColor = focused ? .black : .white
            self.iconView.tintColor = focused ? .black : .white
            self.spinner.color = focused ? .black : .white
        }
    }

    // MARK: - Press feedback

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesBegan(presses, with: event)
        for p in presses where p.type == .select {
            UIView.animate(withDuration: 0.15, delay: 0, usingSpringWithDamping: 0.9,
                           initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = CGAffineTransform(scaleX: 0.95 * (self.isFocused ? 1.08 : 1.0),
                                                   y: 0.95 * (self.isFocused ? 1.08 : 1.0))
            }
            return
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        for p in presses where p.type == .select {
            applyFocusVisuals(focused: isFocused)
            sendActions(for: .primaryActionTriggered)
            return
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        applyFocusVisuals(focused: isFocused)
    }
}

// MARK: - Circle button (Watchlist / Info / Next)

/// 66×66pt circular button with a single SF Symbol. Same focus visuals as
/// `HeroPillButton` but no label.
@MainActor
final class HeroCircleButton: UIControl {

    private let background = UIView()
    /// See `HeroPillButton.materialBackground` for the rationale on the
    /// tvOS material approximation.
    private let materialBackground = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let strokeLayer = CAShapeLayer()
    private let iconView = UIImageView()

    private let cornerRadius: CGFloat = 33

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = false

        background.translatesAutoresizingMaskIntoConstraints = false
        background.layer.cornerRadius = cornerRadius
        background.layer.cornerCurve = .continuous
        background.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        background.isUserInteractionEnabled = false
        addSubview(background)

        materialBackground.translatesAutoresizingMaskIntoConstraints = false
        materialBackground.layer.cornerRadius = cornerRadius
        materialBackground.layer.cornerCurve = .continuous
        materialBackground.clipsToBounds = true
        materialBackground.isUserInteractionEnabled = false
        addSubview(materialBackground)

        strokeLayer.fillColor = UIColor.clear.cgColor
        strokeLayer.strokeColor = UIColor.white.withAlphaComponent(0.2).cgColor
        strokeLayer.lineWidth = 0.5
        layer.addSublayer(strokeLayer)

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 66),
            heightAnchor.constraint(equalToConstant: 66),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialBackground.topAnchor.constraint(equalTo: topAnchor),
            materialBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            materialBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        strokeLayer.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                        cornerRadius: cornerRadius).cgPath
        strokeLayer.frame = bounds
    }

    func setImage(_ image: UIImage?, for state: UIControl.State) {
        iconView.image = image?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [self] in
            applyFocusVisuals(focused: nowFocused)
        }
    }

    private func applyFocusVisuals(focused: Bool) {
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
            self.background.backgroundColor = focused ? .white : UIColor.white.withAlphaComponent(0.12)
            self.materialBackground.alpha = focused ? 0 : 1
            self.strokeLayer.opacity = focused ? 0 : 1
            self.iconView.tintColor = focused ? .black : .white
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesBegan(presses, with: event)
        for p in presses where p.type == .select {
            UIView.animate(withDuration: 0.15, delay: 0, usingSpringWithDamping: 0.9,
                           initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = CGAffineTransform(scaleX: 0.95 * (self.isFocused ? 1.08 : 1.0),
                                                   y: 0.95 * (self.isFocused ? 1.08 : 1.0))
            }
            return
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        for p in presses where p.type == .select {
            applyFocusVisuals(focused: isFocused)
            sendActions(for: .primaryActionTriggered)
            return
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        applyFocusVisuals(focused: isFocused)
    }
}

// MARK: - Paging dots

@MainActor
final class HeroPagingDotsView: UIView {
    private let stack = UIStackView()
    private var dots: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(count: Int, activeIndex: Int) {
        if dots.count != count {
            dots.forEach { $0.removeFromSuperview() }
            dots.removeAll()
            for _ in 0..<count {
                let dot = UIView()
                dot.translatesAutoresizingMaskIntoConstraints = false
                dot.layer.cornerRadius = 4
                dot.layer.cornerCurve = .continuous
                stack.addArrangedSubview(dot)
                NSLayoutConstraint.activate([
                    dot.heightAnchor.constraint(equalToConstant: 8)
                ])
                dots.append(dot)
            }
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            for (i, dot) in self.dots.enumerated() {
                let active = i == activeIndex
                let width: CGFloat = active ? 22 : 8
                // Update width constraint
                for c in dot.constraints where c.firstAttribute == .width {
                    dot.removeConstraint(c)
                }
                dot.widthAnchor.constraint(equalToConstant: width).isActive = true
                dot.backgroundColor = UIColor.white.withAlphaComponent(active ? 1.0 : 0.35)
            }
            self.layoutIfNeeded()
        }
    }
}
