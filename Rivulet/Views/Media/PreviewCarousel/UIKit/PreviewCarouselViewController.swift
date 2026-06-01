//
//  PreviewCarouselViewController.swift
//  Rivulet
//
//  UIKit replacement for `PreviewOverlayHost` + the surrounding
//  `PreviewContainerViewController` modal. Hosts a UICollectionView
//  with a custom `PreviewCarouselLayout` that gives every cell a
//  parallax-aware frame, then drives `contentOffset` directly via
//  `UIViewPropertyAnimator` for paging with the exact cubic timing
//  curve from the SwiftUI baseline.
//
//  Entry / dismiss morphs use a separate `morphSnapshot` view: a
//  PreviewCardView at the same size as the source poster tile,
//  morphed via spring to the centered carousel frame. The collection
//  view sits behind it and is revealed by a crossfade once the
//  morph completes.
//
//  Visual goals:
//   - Smooth 60fps paging with parallax (artwork lags the card).
//   - No content swap mid-animation — every cell shows its item
//     throughout its visible lifetime.
//   - Entry + dismiss spring morphs match SwiftUI baseline timing.
//

import UIKit
import os.log

private let previewCarouselLog = Logger(
    subsystem: "com.rivulet.app",
    category: "PreviewCarouselUIKit"
)

final class PreviewCarouselViewController: UIViewController {
    // MARK: - Inputs

    private var items: [MediaItem]
    private(set) var selectedIndex: Int
    private let initialSourceFrame: CGRect
    private let onDismiss: (PreviewSourceTarget?) -> Void
    private var dismissSourceTarget: PreviewSourceTarget?

    // MARK: - State

    private(set) var state = PreviewStateMachine()
    private var hasRunEntryMorph = false

    /// CADisplayLink-driven paging state. Replaces UIViewPropertyAnimator
    /// because UIVPA's contentOffset interpolation doesn't trigger
    /// per-frame layout invalidation, which breaks parallax and
    /// off-screen cell pre-allocation.
    private struct PagingAnimation {
        let startOffset: CGFloat
        let endOffset: CGFloat
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        let targetIndex: Int
    }
    private var pagingAnimation: PagingAnimation?
    private var displayLink: CADisplayLink?

    // MARK: - Subviews

    private let backdrop = UIView()
    private let layout = PreviewCarouselLayout()
    private let expandedLayout = PreviewExpandedLayout()
    private var morphController: CarouselMorphController!
    private var collectionView: UICollectionView!

    /// VC-owned backdrop plane — single source of truth for artwork.
    /// Sits behind the collection view; cells are transparent windows.
    private let backdropPlane = BackdropPlaneView()

    /// Invisible, always-focusable anchor. The carousel has no focusable
    /// cells (canFocusItemAt is false everywhere), and on tvOS PRESS EVENTS
    /// ARE DELIVERED TO THE FOCUSED VIEW and climb the responder chain from
    /// there — NOT to the first responder, and never to children of the
    /// focused view (WWDC 2016/210; UIKIT_FOUNDATIONS §2). With nothing
    /// focused inside this modal, Menu presses never enter our responder
    /// chain at all, so neither the .menu gesture recognizer nor presses*
    /// overrides ever fire — the presentation machinery handles Menu as a
    /// default modal-dismiss one layer up. This anchor gives the focus
    /// engine a target so the Menu press reaches our chain; the recognizer
    /// then "begins", emits pressesCancelled up the chain (which suppresses
    /// the system dismiss), and our handler runs collapse-vs-dismiss.
    private let focusAnchor = PreviewFocusAnchorView()

    /// Temporary card view used for the source-frame → centered-frame
    /// entry morph (and the reverse for dismiss). Sits on top of the
    /// collection view until the entry settles, then fades out as
    /// the real collection-view cell becomes visible underneath.
    private let morphSnapshot = PreviewCardView(frame: .zero)

    /// Whether the centered card is currently in expanded layout.
    /// In `.expandingHero`/`.expandedHero`/`.detailsStable` this is
    /// true. Drives the custom layout (see `PreviewCarouselLayout`)
    /// to size the centered cell to fullscreen and hide side peeks.
    /// The cell's existing `chromeView` is the SAME view in both
    /// states — only its constraint constants animate (118→140 inset)
    /// and the contentView's corner radius animates (28→0). No
    /// reparenting, no second view tree, true visual continuity.
    private(set) var isExpanded: Bool = false

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
        // .fullScreen because this overlay is OPAQUE by design: it renders
        // its own full-viewport backdrop image plus a dimmed surround and is
        // not meant to show home content behind it. fullScreen lets tvOS drop
        // the presenter's views (cheaper); overFullScreen would only matter if
        // the overlay were see-through. See perf-spike/UIKIT_FOUNDATIONS.md §3.
        //
        // NOTE: presentation style does NOT control Menu dismissal. Menu flows
        // up the responder chain via pressesEnded reaching UIApplication
        // regardless of style. We own Menu by claiming first responder
        // (canBecomeFirstResponder + becomeFirstResponder in viewDidAppear) and
        // absorbing the press in our handler. See §2.
        self.modalPresentationStyle = .fullScreen
        // No modal transition — the entry morph IS the transition.
        // The caller presents with animated: false so viewDidAppear
        // fires immediately for the spring animator.
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

        // Backdrop plane sits behind the collection view (z-order:
        // backdrop-color -> plane -> collection view) so cells layer on top.
        backdropPlane.translatesAutoresizingMaskIntoConstraints = false
        backdropPlane.configure(items: items)
        view.addSubview(backdropPlane)
        NSLayoutConstraint.activate([
            backdropPlane.topAnchor.constraint(equalTo: view.topAnchor),
            backdropPlane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropPlane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropPlane.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        layout.itemCount = items.count
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.bounces = false
        collectionView.isScrollEnabled = false  // We drive offset manually.
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.register(
            PreviewCardView.self,
            forCellWithReuseIdentifier: PreviewCardView.reuseIdentifier
        )
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        expandedLayout.itemCount = items.count
        morphController = CarouselMorphController(
            collectionView: collectionView,
            backdropPlane: backdropPlane,
            carouselLayout: layout,
            expandedLayout: expandedLayout
        )

        // Morph snapshot sits on top until entry settles.
        morphSnapshot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(morphSnapshot)

        // Own the Menu button via a press gesture recognizer on our own
        // view. This is the reliable mechanism (see UIKIT_FOUNDATIONS §2):
        // a Menu press on a present()-ed modal otherwise reaches the
        // presentation controller's dismiss path IN PARALLEL to the press
        // responder chain — so absorbing it in pressesBegan/Ended/Cancelled
        // is not enough (the press arrives as pressesCancelled when our
        // collapse triggers a focus update mid-press, and the modal
        // dismisses anyway). A .menu tap recognizer on this view intercepts
        // the press first, letting handleMenuPress() decide collapse vs
        // dismiss.
        let menuRecognizer = UITapGestureRecognizer(target: self, action: #selector(menuGestureFired))
        menuRecognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuRecognizer)

        // Focus anchor: invisible, always-focusable, so the focus engine has
        // a target inside the modal and Menu presses enter our responder
        // chain (see the focusAnchor doc comment). Zero-size, behind
        // everything; it never shows and never steals visible focus.
        focusAnchor.frame = .zero
        view.addSubview(focusAnchor)

        previewCarouselLog.info("[PCV] viewDidLoad items=\(self.items.count, privacy: .public) selected=\(self.selectedIndex, privacy: .public)")
        // Force a layout pass so cellForItemAt is invoked synchronously
        // for the cells in the initial viewport.
        collectionView.layoutIfNeeded()
        previewCarouselLog.info("[PCV] after layoutIfNeeded contentSize=\(self.collectionView.contentSize.width, privacy: .public)")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Center the carousel on `selectedIndex` so the first frame
        // shows the chosen item under the morph snapshot. We do this
        // every layout pass because `collectionViewContentSize`
        // depends on bounds and `bounds` can change (orientation,
        // focus shifts).
        let offset = layout.contentOffsetCentered(index: selectedIndex)
        collectionView.contentOffset = offset

        if !isExpanded {
            backdropPlane.sync(to: layout, offset: collectionView.contentOffset)
        }

        // Position the morph snapshot. Pre-entry: at the source
        // frame. Post-entry: hidden anyway.
        if !hasRunEntryMorph {
            morphSnapshot.translatesAutoresizingMaskIntoConstraints = true
            morphSnapshot.frame = initialSourceFrame == .zero
                ? centeredFrameInWindow()
                : initialSourceFrame
            // Show item[selectedIndex] in the snapshot so the morph
            // is visually meaningful.
            morphSnapshot.item = items.indices.contains(selectedIndex)
                ? items[selectedIndex]
                : nil
            // Hide the underlying cell artwork so we don't double-
            // render the same image (snapshot on top + cell below).
            collectionView.alpha = 0
        }

    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Focus the invisible anchor so Menu presses are delivered into our
        // responder chain (tvOS routes presses to the FOCUSED view). Without
        // this the modal has no focus target and Menu dismisses by default.
        [focusAnchor]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Drive focus to the anchor so the focus engine has a target inside
        // the modal. becomeFirstResponder is kept as belt-and-suspenders but
        // focus (not first-responder) is what makes presses reach us on tvOS.
        becomeFirstResponder()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        guard !hasRunEntryMorph else { return }
        hasRunEntryMorph = true

        if initialSourceFrame == .zero {
            // No source to morph from. Reveal the collection view
            // immediately and skip the spring.
            morphSnapshot.isHidden = true
            collectionView.alpha = 1
            state.completeEntryMorph()
            return
        }

        let targetFrame = centeredFrameInWindow()

        // Spring: SwiftUI baseline (response 0.45, dampingRatio 0.88).
        // Translated to UISpringTimingParameters physics initializer
        // because tvOS lacks the dampingRatio:frequencyResponse:
        // convenience initializer (iOS 17+).
        //   mass = 1, ω = 2π/0.45 ≈ 13.96
        //   stiffness = ω² ≈ 195
        //   damping = 2 × 0.88 × √195 ≈ 24.58
        let timing = UISpringTimingParameters(
            mass: 1.0,
            stiffness: 195.0,
            damping: 24.58,
            initialVelocity: .zero
        )
        let morpher = UIViewPropertyAnimator(duration: 0.45, timingParameters: timing)
        morpher.addAnimations { [weak self] in
            guard let self else { return }
            self.morphSnapshot.frame = targetFrame
            self.collectionView.alpha = 1
        }
        morpher.addCompletion { [weak self] _ in
            guard let self else { return }
            self.morphSnapshot.isHidden = true
            self.state.completeEntryMorph()
            // Cascade in the chrome on the centered cell.
            self.updateCurrentCellChrome(animated: true)
        }
        morpher.startAnimation()
    }

    /// Refresh the `isCurrent` flag on every visible cell so the
    /// center one (at `selectedIndex`) gets its chrome cascade and
    /// the peeks stay bare.
    ///
    /// `animated: true` runs the page-cascade timing (140ms delay +
    /// 260ms easeOut for vignette, 210ms delay + 480ms easeOut for
    /// chrome). `animated: false` snaps the cell to invisible
    /// chrome — used on paging start to clear the outgoing center.
    private func updateCurrentCellChrome(animated: Bool) {
        for cell in collectionView.visibleCells {
            guard let card = cell as? PreviewCardView else { continue }
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            let shouldBeCurrent = indexPath.item == selectedIndex
            card.setIsCurrent(shouldBeCurrent, animated: animated && shouldBeCurrent)
        }
    }

    // MARK: - Geometry helpers

    /// Frame the centered cell occupies in the view's coordinate
    /// space. Used by the morph snapshot for its target frame.
    private func centeredFrameInWindow() -> CGRect {
        let geom = PreviewCarouselGeometry.self
        let centeredWidth = view.bounds.width - 2 * geom.centeredHorizontalInset
        let centeredHeight = view.bounds.height - geom.topInset
        return CGRect(
            x: geom.centeredHorizontalInset,
            y: geom.topInset,
            width: centeredWidth,
            height: centeredHeight
        )
    }

    // MARK: - Input handling

    // Must return true so this VC can become first responder and receive
    // pressesBegan. Without this, the collection view has no focusable
    // items (canFocusItemAt returns false) so UIKit never installs this VC
    // in the responder chain — Menu presses route to the presenter instead.
    override var canBecomeFirstResponder: Bool { return true }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        previewCarouselLog.info("[Lifecycle] viewWillDisappear isExpanded=\(self.isExpanded) presentingVC=\(self.presentingViewController != nil)")
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            // .menu is owned by the menu gesture recognizer (see viewDidLoad).
            case .rightArrow:
                pageForward()
                return
            case .leftArrow:
                pageBackward()
                return
            case .select, .playPause:
                // Select OR Play/Pause on the centered card expands to
                // the fullscreen detail. Matches SwiftUI's
                // PreviewOverlayHost.swift:183-192 — both Tap and
                // Play/Pause call expandCurrentCard().
                if state.isCarouselInputEnabled {
                    expandCurrentCard()
                    return
                }
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // NOTE: Menu is owned SOLELY by the .menu UITapGestureRecognizer
    // installed in viewDidLoad (see UIKIT_FOUNDATIONS §2 + Apple Forums
    // thread 42630 / openradar 25428691). We deliberately do NOT also
    // intercept .menu in pressesEnded/pressesCancelled: doing both makes the
    // responder-chain absorb race the recognizer, the recognizer never
    // recognizes, the press arrives cancelled, and the presentation
    // controller dismisses the modal anyway. With the recognizer as the
    // single owner, it claims the press (preventing the system dismiss) and
    // its action drives collapse-vs-dismiss. No pressesEnded/Cancelled
    // overrides needed.

    // MARK: - Paging

    private func pageForward() {
        guard state.isCarouselInputEnabled else { return }
        guard pagingAnimation == nil else { return }
        guard selectedIndex < items.count - 1 else { return }
        animatePage(toIndex: selectedIndex + 1)
    }

    private func pageBackward() {
        guard state.isCarouselInputEnabled else { return }
        guard pagingAnimation == nil else { return }
        guard selectedIndex > 0 else { return }
        animatePage(toIndex: selectedIndex - 1)
    }

    /// Drive `contentOffset` toward the new index across the SwiftUI
    /// baseline cubic curve over 0.78s. Uses CADisplayLink + manual
    /// cubic-Bezier evaluation so layout invalidation happens every
    /// frame — required for parallax tracking and off-screen cell
    /// pre-allocation. `UIViewPropertyAnimator` interpolating
    /// contentOffset does not trigger per-frame layout passes.
    private func animatePage(toIndex newIndex: Int) {
        state.beginPaging()

        // Snap the outgoing center cell's chrome to invisible — no
        // fade-out. Matches SwiftUI behavior (vignette + metadata
        // snap to alpha 0 the moment paging begins).
        if let oldCenterCell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0))
            as? PreviewCardView {
            oldCenterCell.setIsCurrent(false, animated: false)
        }

        // Pre-warm the image for the new far-edge cell so the display
        // link's per-frame layout pass doesn't have to wait on an
        // async fetch when the cell scrolls into view. Without this,
        // the animation pauses ~halfway through while the dequeued
        // cell loads its artwork.
        let direction = newIndex > selectedIndex ? 1 : -1
        let prefetchIndex = newIndex + direction * 2
        if items.indices.contains(prefetchIndex) {
            let item = items[prefetchIndex]
            if let url = item.artwork.backdrop ?? item.artwork.poster {
                Task { _ = await ImageCacheManager.shared.image(for: url) }
            }
        }

        let start = collectionView.contentOffset.x
        let end = layout.contentOffsetCentered(index: newIndex).x
        pagingAnimation = PagingAnimation(
            startOffset: start,
            endOffset: end,
            startTime: CACurrentMediaTime(),
            duration: 0.78,
            targetIndex: newIndex
        )

        let link = CADisplayLink(target: self, selector: #selector(tickPagingAnimation))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tickPagingAnimation(_ link: CADisplayLink) {
        guard let anim = pagingAnimation else {
            link.invalidate()
            displayLink = nil
            return
        }

        let elapsed = CACurrentMediaTime() - anim.startTime
        let t = min(1.0, max(0.0, elapsed / anim.duration))
        // SwiftUI baseline cubic curve: control points (0.40, 0.02)
        // and (0.18, 1.0).
        let eased = cubicBezier(t: CGFloat(t), p1x: 0.40, p1y: 0.02, p2x: 0.18, p2y: 1.0)
        let x = anim.startOffset + (anim.endOffset - anim.startOffset) * eased
        // setContentOffset with animated: false issues a non-animated
        // scroll. UICollectionView responds by invalidating layout
        // (because shouldInvalidateLayout(forBoundsChange:) returns
        // true), which recomputes parallax + alpha for every visible
        // cell and queries layoutAttributesForElements with the new
        // viewport.
        collectionView.setContentOffset(CGPoint(x: x, y: 0), animated: false)
        backdropPlane.sync(to: layout, offset: collectionView.contentOffset)

        if t >= 1.0 {
            link.invalidate()
            displayLink = nil
            selectedIndex = anim.targetIndex
            dismissSourceTarget = makeSourceTarget(for: selectedIndex)
            pagingAnimation = nil
            state.finishPaging()
            // Cascade chrome on the new center cell.
            updateCurrentCellChrome(animated: true)
        }
    }

    /// Evaluate a 1-D cubic Bezier ease for x → y given control
    /// points (p1x, p1y) and (p2x, p2y) (with endpoints fixed at
    /// (0,0) and (1,1)).
    ///
    /// We solve for parameter `u` such that the x-coordinate of the
    /// cubic equals `t`, then return the y-coordinate at that u.
    /// Newton-Raphson + bisection fallback (10 iterations is plenty
    /// for animation precision).
    private func cubicBezier(t: CGFloat, p1x: CGFloat, p1y: CGFloat, p2x: CGFloat, p2y: CGFloat) -> CGFloat {
        // Coefficients for x(u) = ((1-u)^3 * 0) + 3 * (1-u)^2 * u * p1x + 3 * (1-u) * u^2 * p2x + u^3 * 1
        //        = (3 p1x - 3 p2x + 1) u^3 + (-6 p1x + 3 p2x) u^2 + (3 p1x) u
        let cx = 3 * p1x
        let bx = 3 * (p2x - p1x) - cx
        let ax = 1 - cx - bx

        let cy = 3 * p1y
        let by = 3 * (p2y - p1y) - cy
        let ay = 1 - cy - by

        // Find u such that x(u) == t. Newton-Raphson.
        var u = t
        for _ in 0..<10 {
            let x = ((ax * u + bx) * u + cx) * u
            let dx = (3 * ax * u + 2 * bx) * u + cx
            if abs(dx) < 1e-6 { break }
            let nextU = u - (x - t) / dx
            u = max(0, min(1, nextU))
        }

        return ((ay * u + by) * u + cy) * u
    }

    // MARK: - Menu + dismiss

    @objc private func menuGestureFired() {
        handleMenuPress()
    }

    private func handleMenuPress() {
        previewCarouselLog.info("[Menu] phase=\(String(describing: self.state.phase), privacy: .public) isExpanded=\(self.isExpanded)")
        let action = state.exitAction()
        previewCarouselLog.info("[Menu] action=\(String(describing: action), privacy: .public)")
        switch action {
        case .dismissOverlay:
            performDismissMorph()
        case .collapseToCarousel:
            // Phase already transitioned to `.carouselStable` inside
            // `state.exitAction()`. Tear down the child VC. Iter C
            // adds the animated collapse cascade (frame shrink +
            // chrome cross-fade); Iter B is an instant teardown.
            collapseExpandedCard()
        }
    }

    // MARK: - Expand / Collapse

    /// Expand the centered card to fullscreen. State machine
    /// transitions through `.expandingHero` → `.expandedHero`. The
    /// custom layout reshapes the centered cell's frame to the
    /// collection view's full bounds; the cell's chromeView mutates
    /// its constraint constants (inset 118 → 140); the cell's
    /// `contentView.layer.cornerRadius` snaps 28 → 0. All happen
    /// inside one `UIView.animate(duration: 0.35, .curveEaseInOut)`.
    ///
    /// Critical: the cell view and the chrome view are the SAME
    /// instances throughout — no second view tree, no reparenting,
    /// no re-render. The animation is a constraint+frame tween on
    /// existing views. This is what gives true visual continuity
    /// matching SwiftUI's persistent-view-tree model.
    ///
    /// Iter B (this commit): instant (duration: 0). Iter C will add
    /// the 0.35s ease-in-out curve + 4-step cascade.
    private func expandCurrentCard() {
        guard !isExpanded else { return }
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]

        previewCarouselLog.info("[Expand] BEGIN idx=\(self.selectedIndex) ref=\(item.ref.itemID, privacy: .public)")

        state.beginExpand()
        isExpanded = true

        // Single-animator morph (CarouselMorphController): the cell window
        // (layout swap to PreviewExpandedLayout), the backdrop panel
        // container grow to fullscreen, the chrome insets 118->140, and the
        // corner-radius lerp 28->0 ALL run on one UIViewPropertyAnimator
        // curve. Nothing can drift. See
        // docs/superpowers/specs/2026-05-31-two-layout-carousel-morph-design.md.
        let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        morphController.expand(centeredIndex: selectedIndex, in: view.bounds, cell: cell) { [weak self] in
            self?.state.finishExpand()
            self?.setNeedsFocusUpdate()
        }
    }

    /// Reverse of `expandCurrentCard`. Returns the centered cell to
    /// its carousel slot, restores chrome insets, restores corner
    /// radius — all on the same 0.35s ease-in-out curve.
    private func collapseExpandedCard() {
        guard isExpanded else { return }
        previewCarouselLog.info("[Collapse] BEGIN idx=\(self.selectedIndex)")

        isExpanded = false

        let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        morphController.collapse(centeredIndex: selectedIndex, cell: cell) { [weak self] in
            guard let self else { return }
            // Restore carousel-mode backdrop panels after collapse.
            self.backdropPlane.sync(to: self.layout, offset: self.collectionView.contentOffset)
            // Focus update AFTER the morph so a focus-driven animation never
            // runs concurrently with the morph curve.
            self.setNeedsFocusUpdate()
        }
    }

    /// Dismiss the overlay. The artwork now lives in the VC-owned
    /// `backdropPlane` (not in the cell), so the old "fly a chrome-only
    /// PreviewCardView snapshot back to the source tile" reverse-entry morph
    /// desynced: the chrome snapshot flew off while the artwork plane sat
    /// orphaned ("metadata dismisses first, then the carousel"). Instead we
    /// fade ALL overlay layers together — backdrop plane (artwork), the
    /// collection view (chrome), and the black backdrop — on ONE animator, so
    /// everything leaves in lockstep.
    private func performDismissMorph() {
        let animator = UIViewPropertyAnimator(
            duration: PreviewCarouselGeometry.expandAnimationDuration,
            curve: .easeInOut
        )
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.backdropPlane.alpha = 0
            self.collectionView.alpha = 0
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

    private func makeSourceTarget(for index: Int) -> PreviewSourceTarget? {
        guard let existing = dismissSourceTarget,
              items.indices.contains(index) else { return dismissSourceTarget }
        let item = items[index]
        return PreviewSourceTarget(rowID: existing.rowID, itemID: "\(item.id)")
    }
}

// MARK: - UICollectionViewDataSource / Delegate

extension PreviewCarouselViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PreviewCardView.reuseIdentifier,
            for: indexPath
        ) as! PreviewCardView
        if items.indices.contains(indexPath.item) {
            cell.item = items[indexPath.item]
        }
        // Default to non-current; if this dequeued cell happens to be
        // at selectedIndex (e.g. on first viewport population), the
        // entry-morph completion or paging completion will flip it via
        // updateCurrentCellChrome.
        cell.setIsCurrent(indexPath.item == selectedIndex && hasRunEntryMorph,
                          animated: false)
        return cell
    }

    // Block the focus engine from auto-scrolling the collection view
    // — we drive scroll ourselves via animatePage so we can use the
    // exact cubic timing curve.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        return false
    }
}

/// Invisible, always-focusable anchor. Exists solely to give the tvOS focus
/// engine a target inside the focusless preview modal so Menu presses are
/// delivered into the VC's responder chain (presses go to the FOCUSED view
/// on tvOS, then climb the chain). It has zero size and draws nothing, so it
/// never shows and never competes with visible content for focus.
final class PreviewFocusAnchorView: UIView {
    override var canBecomeFocused: Bool { true }
}
