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

    /// Active paging animator (nil at rest). Owned strongly so it
    /// isn't deallocated mid-animation if the user pages again.
    /// We replace it on each new page; the previous one is stopped
    /// + invalidated first.
    private var pagingAnimator: UIViewPropertyAnimator?

    /// Whether the entry morph has run. We run it once on viewDidAppear,
    /// not on every layout pass. (viewDidLayoutSubviews could be called
    /// multiple times before the first appear.)
    private var hasRunEntryMorph = false

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
        // No modal transition — the entry morph IS the transition.
        // Caller presents with animated: false so viewDidAppear fires
        // immediately for the spring animator. modalTransitionStyle
        // would be applied if the caller passed animated: true.
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

        // State machine starts in .entryMorph. It advances to
        // .carouselStable in viewDidAppear once the entry animation
        // settles (or immediately if no source frame was supplied).

        previewCarouselLog.debug("viewDidLoad — \(self.items.count, privacy: .public) items, selected=\(self.selectedIndex, privacy: .public)")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        leftCard.frame = previewCarouselFrame(slot: .left, in: bounds)
        rightCard.frame = previewCarouselFrame(slot: .right, in: bounds)

        // If the entry morph hasn't run yet, hold the center card at
        // the source frame instead of the resting carousel frame so
        // viewDidAppear can animate from source → center. Without
        // this, the center card briefly flashes at its full size
        // before the morph begins.
        if hasRunEntryMorph {
            centerCard.frame = previewCarouselFrame(slot: .center, in: bounds)
        } else if initialSourceFrame != .zero {
            centerCard.frame = initialSourceFrame
        } else {
            // Fallback when the home didn't supply a source frame
            // (rare). Skip the morph entirely.
            centerCard.frame = previewCarouselFrame(slot: .center, in: bounds)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasRunEntryMorph else { return }
        hasRunEntryMorph = true

        if initialSourceFrame == .zero {
            // No source frame supplied — nothing to morph from.
            state.completeEntryMorph()
            return
        }

        let targetFrame = previewCarouselFrame(slot: .center, in: view.bounds)

        // Spring matching SwiftUI baseline: response 0.45, damping 0.88.
        // tvOS doesn't expose UISpringTimingParameters(dampingRatio:
        // frequencyResponse:), so we use the physics initializer
        // and derive stiffness/damping from response (2π/ω) +
        // dampingRatio.
        //
        // mass = 1
        // ω = 2π / response = 13.96
        // stiffness = ω² ≈ 195
        // damping = 2 × ζ × √(k×m) = 2 × 0.88 × √195 ≈ 24.58
        let timing = UISpringTimingParameters(
            mass: 1.0,
            stiffness: 195.0,
            damping: 24.58,
            initialVelocity: .zero
        )
        let animator = UIViewPropertyAnimator(duration: 0.45, timingParameters: timing)
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.centerCard.frame = targetFrame
        }
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.state.completeEntryMorph()
        }
        animator.startAnimation()
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

    // MARK: - Input handling

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .menu:
                handleMenuPress()
                return
            case .rightArrow:
                pageForward()
                return
            case .leftArrow:
                pageBackward()
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: - Paging

    /// One full carousel stride in points. Equals the centered card's
    /// width plus the inter-card gap — i.e., how far each card moves
    /// when the user pages once.
    private var slotStride: CGFloat {
        let centeredFrame = previewCarouselFrame(slot: .center, in: view.bounds)
        return centeredFrame.width + PreviewCarouselGeometry.sideCardGap
    }

    private func pageForward() {
        // Refuse new page input while a morph is running, OR if the
        // user is at the end. Per the SwiftUI version the state
        // machine isCarouselInputEnabled gate also blocks during
        // expand / detail phases.
        guard state.isCarouselInputEnabled else { return }
        guard pagingAnimator == nil || pagingAnimator?.isRunning == false else { return }
        guard selectedIndex < items.count - 1 else { return }
        animatePaging(direction: -1)  // cards slide left
    }

    private func pageBackward() {
        guard state.isCarouselInputEnabled else { return }
        guard pagingAnimator == nil || pagingAnimator?.isRunning == false else { return }
        guard selectedIndex > 0 else { return }
        animatePaging(direction: +1)  // cards slide right
    }

    /// Animate one paging step.
    ///
    /// `direction`: -1 means cards translate leftward (user pressed
    /// right — next item). +1 means cards translate rightward (user
    /// pressed left — previous item).
    ///
    /// We use the same cubic curve the SwiftUI version uses
    /// (`(0.40, 0.02, 0.18, 1.0)` over 0.78s) so the motion feels
    /// identical. Internal artwork parallax is driven inside the
    /// same `addAnimations` block — Core Animation interpolates
    /// `parallaxOffsetX` linearly across the curve, which is the
    /// right behavior (parallax should follow the same easing as
    /// the card itself).
    private func animatePaging(direction: CGFloat) {
        state.beginPaging()
        let stride = slotStride
        let dx = direction * stride

        // Begin animator (cubic, matched to SwiftUI baseline).
        let timing = UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.40, y: 0.02),
            controlPoint2: CGPoint(x: 0.18, y: 1.0)
        )
        let animator = UIViewPropertyAnimator(duration: 0.78, timingParameters: timing)
        pagingAnimator = animator

        // All three cards translate together.
        let cards = [leftCard, centerCard, rightCard]
        animator.addAnimations { [weak self] in
            guard let self else { return }
            for card in cards {
                card.transform = CGAffineTransform(translationX: dx, y: 0)
                // Parallax: artwork visually lags the card by 30%
                // (i.e., moves at 70% of the card's translation in
                // world space). In the card's local frame that's a
                // -0.3 × outer-translation counter-translation.
                card.parallaxOffsetX = -dx * 0.3
            }
        }

        animator.addCompletion { [weak self] position in
            guard let self else { return }
            guard position == .end else {
                // Interrupted: reset transforms so the next pageX
                // call computes from a clean baseline.
                for card in cards {
                    card.transform = .identity
                    card.parallaxOffsetX = 0
                }
                self.state.finishPaging()
                self.pagingAnimator = nil
                return
            }

            // Page completed. Update selectedIndex, snap cards back
            // to identity transform + zero parallax, then re-populate
            // so the cards on each side reflect the new neighbors.
            self.selectedIndex -= Int(direction)  // direction=-1 → index+1
            for card in cards {
                card.transform = .identity
                card.parallaxOffsetX = 0
            }
            self.populateCards()
            self.dismissSourceTarget = self.makeSourceTarget(for: self.selectedIndex)
            self.state.finishPaging()
            self.pagingAnimator = nil
        }

        animator.startAnimation()
    }

    /// Builds a `PreviewSourceTarget` for restoring focus to the
    /// home row when the carousel exits. Source row stays the same
    /// (the user came from one specific hub); itemID tracks the
    /// currently-visible center card.
    private func makeSourceTarget(for index: Int) -> PreviewSourceTarget? {
        guard let existing = dismissSourceTarget,
              items.indices.contains(index) else { return dismissSourceTarget }
        let item = items[index]
        return PreviewSourceTarget(rowID: existing.rowID, itemID: "\(item.id)")
    }

    private func handleMenuPress() {
        let action = state.exitAction()
        switch action {
        case .dismissOverlay:
            performDismissMorph()
        case .collapseToCarousel:
            // Iteration 5c (future): animate collapse from expandedHero
            // back to the carousel frame. Skeleton no-op.
            break
        }
    }

    /// Reverse the entry morph: shrink the center card back to the
    /// source frame, then dismiss. If there's no source frame the
    /// dismiss is a plain crossfade.
    private func performDismissMorph() {
        guard initialSourceFrame != .zero else {
            dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.onDismiss(self.dismissSourceTarget)
            }
            return
        }

        // Same spring as entry (see animateEntry for derivation).
        let timing = UISpringTimingParameters(
            mass: 1.0,
            stiffness: 195.0,
            damping: 24.58,
            initialVelocity: .zero
        )
        let animator = UIViewPropertyAnimator(duration: 0.45, timingParameters: timing)
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.centerCard.frame = self.initialSourceFrame
            // Fade the side peeks + backdrop while the center collapses.
            self.leftCard.alpha = 0
            self.rightCard.alpha = 0
            self.backdrop.alpha = 0
        }
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.dismiss(animated: false) {
                self.onDismiss(self.dismissSourceTarget)
            }
        }
        animator.startAnimation()
    }
}
