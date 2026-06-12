//
//  AmbientBackdropView.swift
//  Rivulet
//
//  The page's ambient background — the Apple TV -style color wash. A single
//  artwork image stretched full-bleed UNDERNEATH the home's frosted material
//  (`backgroundBlurView` sits in front and diffuses it into an unrecognizable
//  tint field), plus a vertical vignette so the lower half stays dark behind
//  shelf labels.
//
//  Behavior pinned from the references (Docs/atv_ref/below_home_hero_ref.* and
//  the Apple TV app screenshot pass, 2026-06-10): the wash clearly derives
//  from content (blue one screen, warm gray another), is smoky/uneven (a
//  mega-blurred image, not a uniform gradient), and is set ONCE per screen —
//  paging the hero does NOT recolor it. So `setAmbient` latches the first
//  image and ignores later calls.
//

import UIKit

final class AmbientBackdropView: UIView {

    private let imageView = UIImageView()
    private let vignette = VignetteView()
    private var loadTask: Task<Void, Never>?
    /// Latched after the first successful set — the ambient never changes
    /// for the life of the screen (matches the Apple TV app).
    private(set) var hasAmbient = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFill
        imageView.alpha = 0   // fades in when the artwork lands
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        vignette.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vignette)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            vignette.topAnchor.constraint(equalTo: topAnchor),
            vignette.bottomAnchor.constraint(equalTo: bottomAnchor),
            vignette.leadingAnchor.constraint(equalTo: leadingAnchor),
            vignette.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { loadTask?.cancel() }

    /// Set the ambient artwork once; subsequent calls are no-ops.
    func setAmbient(url: URL?) {
        guard !hasAmbient, let url else { return }
        hasAmbient = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled, let image else { return }
            self.imageView.image = image
            UIView.animate(withDuration: 0.6) {
                self.imageView.alpha = 0.85
            }
        }
    }

    /// Vertical scrim over the wash: brightest up top, dark behind the
    /// shelves — matches both reference shots. Plain gradient-backed UIView
    /// (layerClass) so it lays out via Auto Layout like everything else.
    private final class VignetteView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            let gradient = layer as! CAGradientLayer
            gradient.colors = [
                UIColor.black.withAlphaComponent(0.10).cgColor,
                UIColor.black.withAlphaComponent(0.25).cgColor,
                UIColor.black.withAlphaComponent(0.50).cgColor
            ]
            gradient.locations = [0, 0.55, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    }
}
