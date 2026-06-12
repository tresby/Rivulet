//
//  HeroBackdropView.swift
//  Rivulet
//
//  UIKit counterpart to `HeroBackdropLayer.swift`. A fixed full-bleed
//  backdrop image with a horizontal + vertical scrim, sitting behind the
//  home screen's collection view. Driven via `scrollViewDidScroll`: the
//  parent translates this view upward at a constant 1.4x the scroll rate to
//  produce the Apple TV "receding hero" effect (one steady rate, so it rides
//  the content's ease-out curve rather than kinking mid-scroll).
//
//  Image source is the same `ImageCacheManager.imageFullSize(for:)` used
//  by the SwiftUI version, with a 0.22s opacity crossfade on URL change
//  (matches `HeroBackdropImage`).
//

import UIKit

@MainActor
final class HeroBackdropView: UIView {

    private let currentImageView = UIImageView()
    private let previousImageView = UIImageView()
    private let horizontalScrim = CAGradientLayer()
    private let verticalScrim = CAGradientLayer()
    private let placeholderLayer = CAGradientLayer()

    private var currentURL: URL?
    private var loadTask: Task<Void, Never>?
    private var clearPreviousTask: Task<Void, Never>?

    private let crossfadeDuration: TimeInterval = 0.22

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .black
        isUserInteractionEnabled = false

        // Placeholder gradient (dark grey -> nearly-black) shows before the
        // first image resolves. Sits beneath both image views.
        placeholderLayer.colors = [
            UIColor(white: 0.15, alpha: 1).cgColor,
            UIColor(white: 0.05, alpha: 1).cgColor
        ]
        placeholderLayer.startPoint = CGPoint(x: 0.5, y: 0)
        placeholderLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(placeholderLayer)

        for iv in [previousImageView, currentImageView] {
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            addSubview(iv)
            NSLayoutConstraint.activate([
                iv.topAnchor.constraint(equalTo: topAnchor),
                iv.bottomAnchor.constraint(equalTo: bottomAnchor),
                iv.leadingAnchor.constraint(equalTo: leadingAnchor),
                iv.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        }
        previousImageView.alpha = 0
        currentImageView.alpha = 0

        // Horizontal scrim — matches HeroBackdropLayer's leading-to-trailing
        // gradient (0.88 -> 0.55 -> 0.08 -> clear at 0/0.28/0.55/0.7).
        horizontalScrim.colors = [
            UIColor.black.withAlphaComponent(0.88).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.withAlphaComponent(0.08).cgColor,
            UIColor.clear.cgColor
        ]
        horizontalScrim.locations = [0.0, 0.28, 0.55, 0.7]
        horizontalScrim.startPoint = CGPoint(x: 0, y: 0.5)
        horizontalScrim.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(horizontalScrim)

        // Vertical scrim — clear -> 0.15 -> 0.85 at 0/0.55/1 so content rows
        // below blend into the bottom of the art.
        verticalScrim.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.15).cgColor,
            UIColor.black.withAlphaComponent(0.85).cgColor
        ]
        verticalScrim.locations = [0.0, 0.55, 1.0]
        verticalScrim.startPoint = CGPoint(x: 0.5, y: 0)
        verticalScrim.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(verticalScrim)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // CALayer doesn't autoresize with bounds without explicit work.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderLayer.frame = bounds
        horizontalScrim.frame = bounds
        verticalScrim.frame = bounds
        CATransaction.commit()
    }

    // MARK: - API

    /// Load the backdrop for the supplied URL. Cancels any in-flight load.
    /// Crossfades over 0.22s when replacing an existing image. Setting nil
    /// shows the placeholder gradient.
    func setBackdrop(url: URL?) {
        guard url != currentURL else { return }
        loadTask?.cancel()
        clearPreviousTask?.cancel()

        guard let url else {
            currentURL = nil
            currentImageView.image = nil
            previousImageView.image = nil
            currentImageView.alpha = 0
            previousImageView.alpha = 0
            return
        }

        let oldImage = currentImageView.image
        currentURL = url

        loadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.imageFullSize(for: url)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.currentURL == url else { return }
                guard let image else { return }
                self.applyImage(image, replacing: oldImage)
            }
        }
    }

    private func applyImage(_ image: UIImage, replacing oldImage: UIImage?) {
        if let oldImage {
            previousImageView.image = oldImage
            previousImageView.alpha = 1
        } else {
            previousImageView.image = nil
            previousImageView.alpha = 0
        }
        currentImageView.image = image
        currentImageView.alpha = oldImage == nil ? 1 : 0

        if oldImage == nil {
            return  // No previous image — current is shown immediately.
        }

        UIView.animate(withDuration: crossfadeDuration, delay: 0, options: [.curveEaseInOut]) {
            self.currentImageView.alpha = 1
            self.previousImageView.alpha = 0
        } completion: { _ in
            // Defer clearing the previous image slightly so the layer composition
            // settles before we release the reference.
        }

        let totalNs = UInt64(crossfadeDuration * 1_000_000_000) + 50_000_000
        clearPreviousTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: totalNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.previousImageView.image = nil
            }
        }
    }

    /// Apply the scroll-driven parallax transform. A constant 1.4x of the scroll
    /// offset: the hero recedes faster than the content but at one steady rate,
    /// so it shares the content's ease-out curve instead of kinking. (Previously
    /// added a capped `min(72, offset * 0.72)` kicker, which changed the parallax
    /// rate at ~100pt of scroll and read as a different motion from the rows.)
    func applyScrollOffset(_ offset: CGFloat) {
        let clamped = max(0, offset)
        let translation = -clamped * 1.4
        transform = CGAffineTransform(translationX: 0, y: translation)
    }
}
