//
//  PreviewContainerViewController.swift
//  Rivulet
//
//  UIViewController wrapper for the preview carousel overlay.
//  Intercepts Menu button to support custom back navigation
//  (expanded → carousel → dismiss) and blocks sidebar access
//  via .overFullScreen modal presentation.
//

import SwiftUI
import UIKit

class PreviewContainerViewController: UIViewController {

    private var hostingController: UIHostingController<AnyView>?
    private var menuHandler: (() -> Void)?
    private var isHandlingMenuPress = false

    /// Callback when the preview is fully dismissed
    var onDismiss: (() -> Void)?

    init<Content: View>(content: Content, menuHandler: @escaping () -> Void) {
        self.menuHandler = menuHandler
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .overFullScreen

        let hosting = UIHostingController(rootView: AnyView(content))
        hosting.view.backgroundColor = .clear
        self.hostingController = hosting
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        if let hosting = hostingController {
            addChild(hosting)
            view.addSubview(hosting.view)
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            hosting.didMove(toParent: self)
        }
    }

    // MARK: - Menu Button Interception

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu {
                isHandlingMenuPress = true
                menuHandler?()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu && isHandlingMenuPress {
                isHandlingMenuPress = false
                return
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu && isHandlingMenuPress {
                isHandlingMenuPress = false
                return
            }
        }
        super.pressesCancelled(presses, with: event)
    }

    /// Block system-initiated dismissals (Menu button propagation).
    /// Only dismissPreview() should actually dismiss — unless a child VC
    /// (e.g. the player) is presented on top and needs to dismiss itself.
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        if presentedViewController != nil {
            // A child VC (player) is presented on top — let it dismiss normally
            super.dismiss(animated: flag, completion: completion)
        }
        // Otherwise block — we handle our own dismissal via dismissPreview()
    }

    /// Explicitly dismiss the preview overlay. Optional `completion` runs
    /// AFTER the existing `onDismiss` callback (used by hosts to set
    /// navigation bindings on a clean VC stack).
    func dismissPreview(completion: (() -> Void)? = nil) {
        super.dismiss(animated: false) { [weak self] in
            self?.onDismiss?()
            completion?()
        }
    }

    /// Walk the active scene's presented-VC chain, find the topmost
    /// `PreviewContainerViewController`, dismiss it, and run `then` when
    /// the dismiss animation completes. Hosts use this to drive both
    /// `onDismiss` (no-op `then`) and `onSubItemNavigation`, where `then`
    /// sets the navigation binding the host's NavigationStack picks up.
    /// Calling order matters: setting the binding before dismiss can
    /// race with SwiftUI's presentation attempt; running it in the
    /// completion guarantees the cover/destination presents on a clean
    /// VC stack.
    static func dismissTopmost(then: (() -> Void)? = nil) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.windows.first?.rootViewController else {
            then?()
            return
        }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        if let previewVC = topVC as? PreviewContainerViewController {
            previewVC.dismissPreview(completion: then)
        } else {
            then?()
        }
    }
}
