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
    private var pagingAnimator: UIViewPropertyAnimator?
    private var hasRunEntryMorph = false

    // MARK: - Subviews

    private let backdrop = UIView()
    private let layout = PreviewCarouselLayout()
    private var collectionView: UICollectionView!

    /// Temporary card view used for the source-frame → centered-frame
    /// entry morph (and the reverse for dismiss). Sits on top of the
    /// collection view until the entry settles, then fades out as
    /// the real collection-view cell becomes visible underneath.
    private let morphSnapshot = PreviewCardView(frame: .zero)

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

        // Morph snapshot sits on top until entry settles.
        morphSnapshot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(morphSnapshot)

        previewCarouselLog.debug("viewDidLoad — \(self.items.count, privacy: .public) items, selected=\(self.selectedIndex, privacy: .public)")
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        }
        morpher.startAnimation()
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

    private func pageForward() {
        guard state.isCarouselInputEnabled else { return }
        guard pagingAnimator == nil || pagingAnimator?.isRunning == false else { return }
        guard selectedIndex < items.count - 1 else { return }
        animatePage(toIndex: selectedIndex + 1)
    }

    private func pageBackward() {
        guard state.isCarouselInputEnabled else { return }
        guard pagingAnimator == nil || pagingAnimator?.isRunning == false else { return }
        guard selectedIndex > 0 else { return }
        animatePage(toIndex: selectedIndex - 1)
    }

    /// Drive `contentOffset` to center the new index using our exact
    /// cubic curve. The layout handles parallax + alpha falloff for
    /// every cell that intersects the viewport, so no per-frame
    /// hand-coded animation is needed here.
    private func animatePage(toIndex newIndex: Int) {
        state.beginPaging()
        let targetOffset = layout.contentOffsetCentered(index: newIndex)

        let timing = UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.40, y: 0.02),
            controlPoint2: CGPoint(x: 0.18, y: 1.0)
        )
        let animator = UIViewPropertyAnimator(duration: 0.78, timingParameters: timing)
        pagingAnimator = animator

        animator.addAnimations { [weak self] in
            self?.collectionView.contentOffset = targetOffset
        }
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.selectedIndex = newIndex
            self.dismissSourceTarget = self.makeSourceTarget(for: newIndex)
            self.state.finishPaging()
            self.pagingAnimator = nil
        }
        animator.startAnimation()
    }

    // MARK: - Menu + dismiss

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

    /// Reverse the entry morph: shrink the current center cell back
    /// to the source frame using a snapshot, fade the collection
    /// view + backdrop. If there's no source frame the dismiss is a
    /// plain crossfade.
    private func performDismissMorph() {
        guard initialSourceFrame != .zero else {
            dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.onDismiss(self.dismissSourceTarget)
            }
            return
        }

        // Snapshot the current center cell into morphSnapshot.
        morphSnapshot.item = items.indices.contains(selectedIndex)
            ? items[selectedIndex]
            : nil
        morphSnapshot.frame = centeredFrameInWindow()
        morphSnapshot.isHidden = false
        view.bringSubviewToFront(morphSnapshot)

        let timing = UISpringTimingParameters(
            mass: 1.0,
            stiffness: 195.0,
            damping: 24.58,
            initialVelocity: .zero
        )
        let animator = UIViewPropertyAnimator(duration: 0.45, timingParameters: timing)
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.morphSnapshot.frame = self.initialSourceFrame
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
        return cell
    }

    // Block the focus engine from auto-scrolling the collection view
    // — we drive scroll ourselves via animatePage so we can use the
    // exact cubic timing curve.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        return false
    }
}
