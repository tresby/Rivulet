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

    /// The 3 visible carousel cards. Each card owns its own rounded
    /// clip + image. The host moves them between left / center /
    /// right slot positions as the user pages.
    ///
    /// We use static `UIView` containers later (iteration 5) to
    /// implement slot recycling — for the skeleton these three are
    /// fixed: leftCard always shows item[selectedIndex-1] etc. This
    /// gives us a visually-real carousel without paging.
    private let leftCard = PreviewCardView()
    private let centerCard = PreviewCardView()
    private let rightCard = PreviewCardView()

    /// Child detail controllers — added in iteration 2b. The skeleton
    /// just renders cards; once detail VCs are in place they become
    /// children of these slot views.
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

        // PreviewCardView owns its own rounded clip, so the
        // controller doesn't add a redundant layer mask here.
        // translatesAutoresizingMaskIntoConstraints stays true — we
        // position cards via .frame in viewDidLayoutSubviews + during
        // paging animation. Layout constraints would force a layout
        // pass on each animation frame, which is the SwiftUI pitfall
        // we explicitly want to avoid.
        view.addSubview(leftCard)
        view.addSubview(rightCard)
        view.addSubview(centerCard)  // Added last → on top.

        populateCards()

        previewCarouselLog.debug("viewDidLoad — \(self.items.count, privacy: .public) items, selected=\(self.selectedIndex, privacy: .public)")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Iteration 5 will animate these; for the skeleton we just
        // place each card at its resting carousel frame so the host
        // is visually inspectable in the sim.
        let bounds = view.bounds
        leftCard.frame = previewCarouselFrame(slot: .left, in: bounds)
        centerCard.frame = previewCarouselFrame(slot: .center, in: bounds)
        rightCard.frame = previewCarouselFrame(slot: .right, in: bounds)
    }

    /// Assigns items to the three visible cards based on
    /// `selectedIndex`. Re-called whenever the index changes.
    private func populateCards() {
        leftCard.item = items.indices.contains(selectedIndex - 1)
            ? items[selectedIndex - 1] : nil
        centerCard.item = items.indices.contains(selectedIndex)
            ? items[selectedIndex] : nil
        rightCard.item = items.indices.contains(selectedIndex + 1)
            ? items[selectedIndex + 1] : nil
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
