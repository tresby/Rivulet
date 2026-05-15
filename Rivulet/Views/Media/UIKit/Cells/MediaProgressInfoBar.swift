//
//  MediaProgressInfoBar.swift
//  Rivulet
//
//  Reusable bottom-bar composition shared by `ContinueWatchingCell` and
//  in-progress tiles in `PosterCell`. Mirrors SwiftUI
//  `ContinueWatchingCard.bottomInfoBar` (`ContinueWatchingCard.swift:105`):
//
//    [▶︎]  [▓▓▓░░ progress 44pt]  S1, E2 • 35m
//
//  Components:
//   - play.fill icon (18pt semibold)
//   - 44pt-wide capsule progress (white core on white-0.3 backing),
//     hidden when not in progress
//   - info text (20pt medium, white-0.6): "S{n}, E{n}" for episodes
//     plus remaining-or-duration ("1h 7m" / "35m left")
//
//  The companion view here is `MediaBottomGradient` — a CAGradientLayer
//  that subclasses `UIView` so callers can pin it to the bottom area of
//  any artwork-bearing cell without re-implementing the stops each time.
//

import UIKit

@MainActor
final class MediaProgressInfoBar: UIView {

    private let playIcon = UIImageView()
    private let progressContainer = UIView()
    private let progressBackground = UIView()
    private let progressFill = UIView()
    private let infoLabel = UILabel()
    private let stack = UIStackView()

    private var progressFillWidthConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playIcon.image = UIImage(systemName: "play.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        playIcon.tintColor = UIColor.white.withAlphaComponent(0.6)
        playIcon.contentMode = .scaleAspectFit

        progressContainer.translatesAutoresizingMaskIntoConstraints = false
        progressBackground.translatesAutoresizingMaskIntoConstraints = false
        progressBackground.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        progressBackground.layer.cornerRadius = 2
        progressBackground.layer.cornerCurve = .continuous
        progressBackground.clipsToBounds = true
        progressContainer.addSubview(progressBackground)

        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = .white
        progressFill.layer.cornerRadius = 2
        progressFill.layer.cornerCurve = .continuous
        progressBackground.addSubview(progressFill)

        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = .systemFont(ofSize: 20, weight: .medium)
        infoLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        infoLabel.numberOfLines = 1

        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(playIcon)
        stack.addArrangedSubview(progressContainer)
        stack.addArrangedSubview(infoLabel)
        addSubview(stack)

        progressFillWidthConstraint = progressFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            playIcon.widthAnchor.constraint(equalToConstant: 22),
            playIcon.heightAnchor.constraint(equalToConstant: 22),

            progressContainer.widthAnchor.constraint(equalToConstant: 44),
            progressContainer.heightAnchor.constraint(equalToConstant: 4),
            progressBackground.topAnchor.constraint(equalTo: progressContainer.topAnchor),
            progressBackground.bottomAnchor.constraint(equalTo: progressContainer.bottomAnchor),
            progressBackground.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor),
            progressBackground.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),

            progressFill.leadingAnchor.constraint(equalTo: progressBackground.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressBackground.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressBackground.bottomAnchor),
            progressFillWidthConstraint
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: PlexMetadata) {
        // Show progress capsule only when 0 < watchProgress < 1
        // (mirrors SwiftUI's `if let progress, progress > 0 && progress < 1`).
        let p = item.watchProgress ?? 0
        if p > 0 && p < 1 {
            progressContainer.isHidden = false
            progressFillWidthConstraint.constant = 44 * CGFloat(p)
        } else {
            progressContainer.isHidden = true
            progressFillWidthConstraint.constant = 0
        }
        infoLabel.text = infoText(for: item)
    }

    func reset() {
        progressContainer.isHidden = true
        progressFillWidthConstraint.constant = 0
        infoLabel.text = nil
    }

    /// "S1, E2 • 35m" or "1h 7m". Mirrors SwiftUI
    /// `ContinueWatchingCard.infoText` exactly.
    private func infoText(for item: PlexMetadata) -> String {
        var parts: [String] = []
        if item.type == "episode" {
            let season = item.parentIndex ?? 0
            let episode = item.index ?? 0
            parts.append("S\(season), E\(episode)")
        }
        if let remaining = item.remainingTimeFormatted {
            parts.append(remaining)
        } else if let duration = item.durationFormatted {
            parts.append(duration)
        }
        return parts.joined(separator: " \u{2022} ")
    }
}

// MARK: - Bottom gradient

/// Bottom darkening gradient used behind `MediaProgressInfoBar` so the
/// text + icon stay legible over bright artwork. Stops match SwiftUI:
/// `clear@0.3 -> black-0.7@0.7 -> black-0.85@1.0`.
@MainActor
final class MediaBottomGradient: UIView {

    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        gradient.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.7).cgColor,
            UIColor.black.withAlphaComponent(0.85).cgColor
        ]
        gradient.locations = [0.3, 0.7, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}
