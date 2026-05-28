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

    /// Fixed-position card views. Each card lives at one of the five
    /// `PreviewCarouselSlot` positions for the duration of its life
    /// in the carousel. We never reparent or transform them during
    /// paging — instead we shift the *content mapping* (which item
    /// each slot's card displays) and slide all five cards by one
    /// stride.
    ///
    /// Keyed by slot. The mapping `slotOffsetFromSelected → card`
    /// is invariant: the card at `.center` is always the focused
    /// card, the card at `.leftPeek` is always the left visible peek,
    /// etc.
    private var slotCards: [PreviewCarouselSlot: PreviewCardView] = [:]

    /// Item index displayed by each slot. Reset on every settled
    /// paging completion. `slotItemIndex[.center]` == `selectedIndex`
    /// by definition.
    private var slotItemIndex: [PreviewCarouselSlot: Int] = [:]

    /// Center-slot proxy — convenience accessor for entry morph and
    /// dismiss morph, which both target the focused card.
    private var centerCard: PreviewCardView {
        guard let card = slotCards[.center] else {
            fatalError("centerCard accessed before viewDidLoad set up slots")
        }
        return card
    }

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

        // PreviewCardView owns its own rounded clip; the controller
        // adds no extra layer masks. Card positions are set via
        // `.frame` (not Auto Layout) so paging animation can update
        // them without re-running layout passes.
        for slot in PreviewCarouselSlot.allCases {
            let card = PreviewCardView()
            slotCards[slot] = card
            view.addSubview(card)
        }
        // Center is on top of side peeks; off-screen slots are below
        // peeks (they only matter once they enter visibility).
        if let center = slotCards[.center] {
            view.bringSubviewToFront(center)
        }

        populateAllSlots()

        // State machine starts in .entryMorph. It advances to
        // .carouselStable in viewDidAppear once the entry animation
        // settles (or immediately if no source frame was supplied).

        previewCarouselLog.debug("viewDidLoad — \(self.items.count, privacy: .public) items, selected=\(self.selectedIndex, privacy: .public)")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        // Lay out every slot at its resting frame. Paging is animated
        // via transform on the parent view (see animatePaging), so
        // the underlying frames stay fixed and `viewDidLayoutSubviews`
        // can run any time (e.g. orientation, focus) without
        // interfering with the animation.
        for slot in PreviewCarouselSlot.allCases {
            guard let card = slotCards[slot] else { continue }
            // Skip the center card during pre-entry — viewDidAppear
            // animates it from initialSourceFrame to the center.
            if slot == .center, !hasRunEntryMorph, initialSourceFrame != .zero {
                card.frame = initialSourceFrame
                continue
            }
            card.frame = previewCarouselFrame(slot: slot, in: bounds)
        }
    }

    /// Assigns each slot the item it should display given the current
    /// `selectedIndex`. Out-of-range slots (e.g. left-peek when
    /// selectedIndex is 0) get `nil` — `PreviewCardView` handles the
    /// nil case by clearing its image + title.
    private func populateAllSlots() {
        for slot in PreviewCarouselSlot.allCases {
            let idx = selectedIndex + slot.rawValue
            slotItemIndex[slot] = idx
            slotCards[slot]?.item = items.indices.contains(idx) ? items[idx] : nil
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
    /// Slot rotation model: every card keeps showing the same item
    /// throughout the animation (no mid-animation content swap, no
    /// flicker). All five cards translate by one full stride; at
    /// completion we rotate the slot mapping and the now-invisible
    /// far-edge card gets reassigned the new far-edge item, ready
    /// for the *next* page in either direction.
    ///
    /// Curve: cubic (0.40, 0.02, 0.18, 1.0) over 0.78s, matched to
    /// the SwiftUI baseline.
    private func animatePaging(direction: CGFloat) {
        state.beginPaging()
        let stride = slotStride
        let dx = direction * stride

        let timing = UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.40, y: 0.02),
            controlPoint2: CGPoint(x: 0.18, y: 1.0)
        )
        let animator = UIViewPropertyAnimator(duration: 0.78, timingParameters: timing)
        pagingAnimator = animator

        let cards = Array(slotCards.values)

        animator.addAnimations {
            for card in cards {
                card.transform = CGAffineTransform(translationX: dx, y: 0)
            }
        }

        animator.addCompletion { [weak self] position in
            guard let self else { return }
            for card in cards {
                card.transform = .identity
            }
            if position == .end {
                self.commitPagingStep(direction: direction)
            }
            self.state.finishPaging()
            self.pagingAnimator = nil
        }

        animator.startAnimation()
    }

    /// Commit a paging step after a successful animation.
    ///
    /// Concretely, when the user pages RIGHT (`direction = -1`):
    ///   - Visually, every card has translated one stride LEFT.
    ///   - The card that was at `.offscreenLeft` is now even further
    ///     off-screen (invisible). It will be recycled to
    ///     `.offscreenRight` as the new "ready" card on that side.
    ///   - Every other card stays where it visually landed: the card
    ///     that was at `.leftPeek` is now at `.offscreenLeft`'s
    ///     position, etc.
    ///   - `selectedIndex` advances by +1.
    ///
    /// To make this work after we reset card transforms to identity,
    /// we explicitly reassign each card's frame and the slot mapping.
    /// No card's item changes — except the recycled card, which now
    /// shows the *new* far-edge item (selectedIndex+2 after the step).
    /// That assignment can trigger an async image load, but it's
    /// invisible (off-screen) so any load delay can't flicker.
    private func commitPagingStep(direction: CGFloat) {
        // shift = how each card's slot index changes.
        // Page right (direction=-1) → cards moved left → slot index decreases.
        let shift = Int(-direction)
        // After paging right, the old `.offscreenLeft` card is the
        // one that visually fell off; we'll repurpose it as the new
        // `.offscreenRight`. (And vice versa for left.)
        let recyclingDonorSlot: PreviewCarouselSlot = shift < 0
            ? .offscreenLeft  // paged right → donor is the leftmost
            : .offscreenRight // paged left → donor is the rightmost
        let recyclingTargetSlot: PreviewCarouselSlot = shift < 0
            ? .offscreenRight
            : .offscreenLeft

        var newSlotCards: [PreviewCarouselSlot: PreviewCardView] = [:]
        var newSlotItemIndex: [PreviewCarouselSlot: Int] = [:]

        for sourceSlot in PreviewCarouselSlot.allCases {
            guard let card = slotCards[sourceSlot] else { continue }
            if sourceSlot == recyclingDonorSlot {
                // Recycle this card to the opposite far-edge.
                card.frame = previewCarouselFrame(slot: recyclingTargetSlot, in: view.bounds)
                newSlotCards[recyclingTargetSlot] = card
                let newIdx = (selectedIndex - Int(direction)) + recyclingTargetSlot.rawValue
                newSlotItemIndex[recyclingTargetSlot] = newIdx
                card.item = items.indices.contains(newIdx) ? items[newIdx] : nil
            } else {
                let newRaw = sourceSlot.rawValue + shift
                guard let newSlot = PreviewCarouselSlot(rawValue: newRaw) else {
                    // Shouldn't happen — the only out-of-range case
                    // is the donor slot we already handled.
                    continue
                }
                card.frame = previewCarouselFrame(slot: newSlot, in: view.bounds)
                newSlotCards[newSlot] = card
                newSlotItemIndex[newSlot] = slotItemIndex[sourceSlot]
            }
        }

        slotCards = newSlotCards
        slotItemIndex = newSlotItemIndex
        selectedIndex -= Int(direction)
        dismissSourceTarget = makeSourceTarget(for: selectedIndex)

        // Z-order: bring the new center to the front.
        if let center = slotCards[.center] {
            view.bringSubviewToFront(center)
        }
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
            // Fade everything except the center card. Side peeks and
            // off-screen cards become invisible together with the
            // backdrop while the center collapses.
            self.backdrop.alpha = 0
            for slot in PreviewCarouselSlot.allCases where slot != .center {
                self.slotCards[slot]?.alpha = 0
            }
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
