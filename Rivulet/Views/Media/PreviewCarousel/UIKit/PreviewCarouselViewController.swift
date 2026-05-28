//
//  PreviewCarouselViewController.swift
//  Rivulet
//
//  UIKit replacement for `PreviewOverlayHost` + the surrounding
//  `PreviewContainerViewController` modal. Hosts 3 visible card slots
//  (n-1, n, n+1) and the `PreviewStateMachine` driving paging /
//  expand / collapse / exit.
//
//  This file lands the skeleton. Visual hookups (backdrop, slot
//  positioning animations, morphs) ship in later iterations per
//  perf-spike/DETAIL_DESIGN.md.
//

import UIKit
import os.log

private let previewCarouselLog = Logger(
    subsystem: "com.rivulet.app",
    category: "PreviewCarouselUIKit"
)

final class PreviewCarouselViewController: UIViewController {
    // MARK: - Inputs

    /// The set of items to be paged through (matches
    /// `PreviewRequest.items`).
    private var items: [MediaItem]

    /// Index of the centered slot inside `items`.
    private(set) var selectedIndex: Int

    /// Source-tile frame in window coords for the initial entry
    /// morph. Used by Iteration 5 (entry animation) — captured now so
    /// the host has it before the morph starts.
    private let initialSourceFrame: CGRect

    /// Called when the host should dismiss itself (Menu from carousel,
    /// or carousel-stable exit). Provides the source target the home
    /// view should restore focus to.
    private let onDismiss: (PreviewSourceTarget?) -> Void

    /// Source target for restoration. Updated by carousel paging so
    /// the home view scrolls to the last-viewed item on dismiss.
    private var dismissSourceTarget: PreviewSourceTarget?

    // MARK: - State

    private(set) var state = PreviewStateMachine()
    private var loadGate = PreviewLoadGate()

    // MARK: - Subviews

    /// Black underlay. Matches SwiftUI's "no scrim, solid black"
    /// backdrop.
    private let backdrop = UIView()

    /// The 3 slot containers. Each will host a child
    /// `MediaDetailViewController` once the detail controller lands
    /// in Iteration 2.
    private let leftSlot = UIView()
    private let centerSlot = UIView()
    private let rightSlot = UIView()

    /// Child controllers keyed by slot. Created on first
    /// `viewDidLoad`. Slots get reconfigured (not torn down) as the
    /// user pages.
    private var leftDetailVC: MediaDetailViewController?
    private var centerDetailVC: MediaDetailViewController?
    private var rightDetailVC: MediaDetailViewController?

    // MARK: - Lifecycle

    init(
        items: [MediaItem],
        selectedIndex: Int,
        sourceFrame: CGRect,
        sourceTarget: PreviewSourceTarget?,
        onDismiss: @escaping (PreviewSourceTarget?) -> Void
    ) {
        precondition(!items.isEmpty, "PreviewCarouselViewController requires at least one item")
        precondition(selectedIndex >= 0 && selectedIndex < items.count, "selectedIndex out of range")
        self.items = items
        self.selectedIndex = selectedIndex
        self.initialSourceFrame = sourceFrame
        self.dismissSourceTarget = sourceTarget
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewCarouselViewController is not Storyboard-backed")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.backgroundColor = .black
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        for slot in [leftSlot, centerSlot, rightSlot] {
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.backgroundColor = .clear
            slot.clipsToBounds = true
            slot.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
            slot.layer.cornerCurve = .continuous
            view.addSubview(slot)
        }
        // Center is on top. (Z-order matches audit section 2.1.)
        view.bringSubviewToFront(centerSlot)

        previewCarouselLog.debug("viewDidLoad — \(self.items.count, privacy: .public) items, selected=\(self.selectedIndex, privacy: .public)")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Iteration 5 will animate these; for the skeleton we just
        // place the slots at their resting carousel frames so the host
        // is visually inspectable in the sim.
        let bounds = view.bounds
        leftSlot.frame = previewCarouselFrame(slot: .left, in: bounds)
        centerSlot.frame = previewCarouselFrame(slot: .center, in: bounds)
        rightSlot.frame = previewCarouselFrame(slot: .right, in: bounds)
    }

    // MARK: - Skeleton convenience

    /// Returns the item at the current center slot, or nil if items is
    /// empty (which would have tripped the init precondition anyway).
    var currentItem: MediaItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    // MARK: - Menu intercept (skeleton)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let consumed = presses.contains { $0.type == .menu }
        if consumed {
            handleMenuPress()
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    private func handleMenuPress() {
        // Iteration 6 wires the full intercept chain (child consumes
        // first, then state.exitAction()). For the skeleton, dismiss.
        previewCarouselLog.debug("menu press — dismissing (skeleton)")
        let action = state.exitAction()
        switch action {
        case .dismissOverlay:
            dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.onDismiss(self.dismissSourceTarget)
            }
        case .collapseToCarousel:
            // Iteration 5: animate collapse from expandedHero back to
            // the carousel frame. Skeleton no-op.
            break
        }
    }
}
