//
//  ShelfRowCell.swift
//  Rivulet
//
//  One horizontal shelf row (Continue Watching / Recently Added /
//  Recommendations / Watchlist) hosting its own horizontal collection view.
//
//  Why not an orthogonal compositional section: measured behavior of the
//  embedded orthogonal scroller on tvOS (settle-log verified, 2026-06-10) is
//  that focus-driven landings always pin a tile's leading edge to the RAW
//  screen edge — section contentInsets, scroller contentInset, and
//  isScrollEnabled are all ignored or reverted by the layout. That makes a
//  tile peeking in from the left geometrically impossible and loses the
//  at-rest margin on the first scroll.
//
//  Here the row owns its scroll instead (isScrollEnabled = false, offsets
//  driven from didUpdateFocus — the same pattern as the detail page's
//  FocusScrollControlledCollectionView, applied horizontally). Every resting
//  position is exact:
//
//      contentOffset.x = firstVisibleColumn × (tileWidth + gap)
//
//  which, with the shelf equation in MediaRowMetrics
//  (1920 = 2·rowLeading + N·tile + (N−1)·gap), shows N full tiles with equal
//  slivers peeking in from BOTH screen edges, and tile k+1 landing exactly
//  where tile k was.
//

import UIKit

final class ShelfRowCell: UICollectionViewCell {
    static let reuseID = "ShelfRowCell"

    enum TileKind {
        case continueWatching
        case poster

        var tileWidth: CGFloat { self == .continueWatching ? MediaRowMetrics.cwWidth : MediaRowMetrics.posterWidth }
        var tileHeight: CGFloat { self == .continueWatching ? MediaRowMetrics.cwHeight : MediaRowMetrics.posterHeight }
        var gap: CGFloat { self == .continueWatching ? MediaRowMetrics.cwGap : MediaRowMetrics.posterGap }
        var fullCount: Int { self == .continueWatching ? MediaRowMetrics.cwFullCount : MediaRowMetrics.posterFullCount }
        var pitch: CGFloat { tileWidth + gap }
    }

    // MARK: Callbacks to the owning controller (reset on every configure)

    /// Dequeues + configures the cell for an item index. The skeleton
    /// placeholder (when active) is the LAST index.
    var cellProvider: ((UICollectionView, IndexPath) -> UICollectionViewCell)?
    var onSelect: ((Int) -> Void)?
    var onWillDisplayItem: ((Int) -> Void)?
    var contextMenuProvider: ((Int) -> UIMenu?)?
    /// Reports resting offsets so the owner can restore them across reuse.
    var onOffsetChanged: ((CGFloat) -> Void)?

    // MARK: State

    private(set) var rowCollectionView: UICollectionView!
    private let flow = UICollectionViewFlowLayout()
    private var tileKind: TileKind = .poster
    /// Real item count (excludes the skeleton placeholder).
    private var realCount = 0
    private var hasSkeleton = false
    /// Identity of the configured content; a change forces a full reload.
    private var contentToken: Int = 0
    /// How far this cell extends PAST the visible panel on each side (the
    /// expanded detail's below-fold is translated/widened off-screen by a
    /// constant pull). The shelf margin + equation are panel-relative: the
    /// overshoot is simply added to the inner content insets so tiles, peeks
    /// and landings line up with the panel exactly like the home rows.
    private var panelOvershoot: (left: CGFloat, right: CGFloat) = (0, 0)

    /// When true, the leading inset (row AND header) is computed every layout
    /// pass from the cell's ACTUAL on-screen x, so the first tile lands at
    /// `MediaRowMetrics.rowLeading` in SCREEN space regardless of any container
    /// translation. The expanded detail's below-fold is translated by a
    /// state-dependent amount (different for the in-carousel expand vs the
    /// standalone expand), so a fixed overshoot constant can't be right for
    /// both — self-measuring is. Home rows leave this false (cell already at
    /// screen x = 0, so the static inset already lands at rowLeading).
    var screenAlignsLeading = false {
        didSet { setNeedsLayout() }
    }

    /// Optional in-cell header title (the below-fold Related row draws its
    /// "Related" header here so it self-aligns with the tiles; the home rows
    /// keep using the section's supplementary header and leave this nil).
    var headerTitle: String? {
        didSet {
            headerLabel.text = headerTitle
            let show = !(headerTitle?.isEmpty ?? true)
            headerLabel.isHidden = !show
            headerHeightConstraint.constant = show ? Self.headerHeight : 0
        }
    }

    private static let headerHeight: CGFloat = 44

    private let headerLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 32, weight: .semibold)
        l.textColor = .white
        l.isHidden = true
        return l
    }()
    private var headerLeadingConstraint: NSLayoutConstraint!
    private var headerHeightConstraint: NSLayoutConstraint!
    private var rowWidthConstraint: NSLayoutConstraint!

    /// Item index to route focus to on the next focus update (preview-dismiss
    /// restoration). One-shot.
    private var pendingFocusIndex: Int?

    // Driven offset settle (CADisplayLink), sharing FocusScrollMotion's
    // duration + curve with the vertical focus-scroll so horizontal and
    // vertical row motion feel identical. (The focus coordinator's default
    // animation is much faster and reads as a jump cut.)
    private var offsetLink: CADisplayLink?
    private var animStartX: CGFloat = 0
    private var animTargetX: CGFloat = 0
    private var animStartTime: CFTimeInterval = 0

    private var displayCount: Int { realCount + (hasSkeleton ? 1 : 0) }

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)

        flow.scrollDirection = .horizontal
        applyMetrics(for: .poster)  // matches the default tileKind
        rowCollectionView = UICollectionView(frame: bounds, collectionViewLayout: flow)
        rowCollectionView.translatesAutoresizingMaskIntoConstraints = false
        rowCollectionView.backgroundColor = .clear
        rowCollectionView.dataSource = self
        rowCollectionView.delegate = self
        // We own the scroll: the engine's focus-scroll is disabled so it can't
        // land at arbitrary offsets, and didUpdateFocus drives pitch-aligned
        // offsets instead. Programmatic offsets still work when disabled.
        rowCollectionView.isScrollEnabled = false
        // No per-row focus memory: entering a row should land on the tile in
        // the same SCREEN column you came from (the engine's geometric pick),
        // like ATV+ — not on whatever tile this row last had focused.
        rowCollectionView.remembersLastFocusedIndexPath = false
        // The focused tile's scale + the peeking slivers must not clip.
        rowCollectionView.clipsToBounds = false
        clipsToBounds = false
        contentView.clipsToBounds = false

        rowCollectionView.register(PosterCell.self, forCellWithReuseIdentifier: PosterCell.reuseID)
        rowCollectionView.register(ContinueWatchingCell.self, forCellWithReuseIdentifier: ContinueWatchingCell.reuseID)
        rowCollectionView.register(WatchlistPosterCell.self, forCellWithReuseIdentifier: WatchlistPosterCell.reuseID)
        rowCollectionView.register(PosterSkeletonCell.self, forCellWithReuseIdentifier: PosterSkeletonCell.reuseID)

        contentView.addSubview(headerLabel)
        contentView.addSubview(rowCollectionView)
        headerLeadingConstraint = headerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MediaRowMetrics.rowLeading)
        headerHeightConstraint = headerLabel.heightAnchor.constraint(equalToConstant: 0)
        // Width is constraint-driven (not a trailing pin): when screen-aligned
        // the inner collection must reach the screen's RIGHT edge even if the
        // host cell is narrower than the screen, otherwise the peeking tile's
        // frame falls outside the collection's bounds and its cell is never
        // realized ("pops into place" instead of sliding in). Defaults to the
        // cell width (home behavior); updated in layoutSubviews.
        rowWidthConstraint = rowCollectionView.widthAnchor.constraint(equalToConstant: MediaRowMetrics.posterWidth)
        rowWidthConstraint.priority = .required
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerLeadingConstraint,
            headerHeightConstraint,
            // Row fills below the header (header height is 0 when no title, so
            // the row reclaims the full cell — home behavior unchanged).
            rowCollectionView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor),
            rowCollectionView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rowCollectionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowWidthConstraint,
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Default: inner collection spans the cell (home behavior).
        var targetWidth = bounds.width
        if screenAlignsLeading, let window {
            // Cell origin in screen space — negative when the container is
            // translated left past the screen edge.
            let screenMinX = convert(CGPoint.zero, to: window).x
            let targetInset = MediaRowMetrics.rowLeading - screenMinX
            if abs(flow.sectionInset.left - targetInset) > 0.5 {
                flow.sectionInset.left = targetInset
                flow.invalidateLayout()
            }
            if abs(headerLeadingConstraint.constant - targetInset) > 0.5 {
                headerLeadingConstraint.constant = targetInset
            }
            // Reach the screen's right edge + one pitch of buffer so the
            // right-peek tile always has a realized cell.
            let screenWidth = window.bounds.width
            targetWidth = (screenWidth - screenMinX) + tileKind.pitch
        }
        if abs(rowWidthConstraint.constant - targetWidth) > 0.5 {
            rowWidthConstraint.constant = targetWidth
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The row container itself never takes focus — its tiles do.
    override var canBecomeFocused: Bool { false }

    override func prepareForReuse() {
        super.prepareForReuse()
        pendingFocusIndex = nil
        offsetLink?.invalidate()
        offsetLink = nil
    }

    // MARK: Configure

    /// Full (re)bind. `contentToken` identifies the content (hash of item
    /// IDs); reload only happens when it changes, so reconfiguring with the
    /// same data is cheap and focus-safe.
    func configure(kind: TileKind,
                   realCount: Int,
                   hasSkeleton: Bool,
                   contentToken: Int,
                   initialOffset: CGFloat,
                   panelOvershoot: (left: CGFloat, right: CGFloat) = (0, 0)) {
        let kindChanged = kind != tileKind || panelOvershoot != self.panelOvershoot
        tileKind = kind
        self.panelOvershoot = panelOvershoot
        if kindChanged {
            applyMetrics(for: kind)
        }

        if kindChanged || contentToken != self.contentToken {
            self.contentToken = contentToken
            self.realCount = realCount
            self.hasSkeleton = hasSkeleton
            rowCollectionView.reloadData()
            rowCollectionView.layoutIfNeeded()
            setOffset(clampedTo: initialOffset)
        } else {
            updateCounts(realCount: realCount, hasSkeleton: hasSkeleton)
        }
    }

    /// Append-only growth (pagination) without nuking focus: inserts the new
    /// trailing items; the skeleton placeholder (an unchanged trailing item)
    /// shifts to the new end automatically.
    func updateCounts(realCount newReal: Int, hasSkeleton newSkeleton: Bool) {
        guard newReal != realCount || newSkeleton != hasSkeleton else { return }
        let oldReal = realCount
        let oldSkeleton = hasSkeleton
        guard newReal >= oldReal,
              rowCollectionView.numberOfItems(inSection: 0) == oldReal + (oldSkeleton ? 1 : 0)
        else {
            // Shrunk or out of sync — full reload, clamp the offset back into
            // the new range.
            realCount = newReal
            hasSkeleton = newSkeleton
            rowCollectionView.reloadData()
            rowCollectionView.layoutIfNeeded()
            setOffset(clampedTo: rowCollectionView.contentOffset.x)
            return
        }

        realCount = newReal
        hasSkeleton = newSkeleton
        rowCollectionView.performBatchUpdates {
            if newReal > oldReal {
                rowCollectionView.insertItems(at: (oldReal..<newReal).map { IndexPath(item: $0, section: 0) })
            }
            if oldSkeleton, !newSkeleton {
                rowCollectionView.deleteItems(at: [IndexPath(item: oldReal, section: 0)])
            } else if !oldSkeleton, newSkeleton {
                rowCollectionView.insertItems(at: [IndexPath(item: newReal, section: 0)])
            }
        }
    }

    /// Route the next focus update to a specific item (preview-dismiss
    /// restoration): jump the window so the item is visible, then prefer its
    /// cell.
    func prepareFocusRestore(on itemIndex: Int) {
        pendingFocusIndex = itemIndex
        setOffset(clampedTo: snappedOffset(toShow: itemIndex), animated: false)
        rowCollectionView.layoutIfNeeded()
        setNeedsFocusUpdate()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let index = pendingFocusIndex,
           let cell = rowCollectionView.cellForItem(at: IndexPath(item: index, section: 0)) {
            pendingFocusIndex = nil
            return [cell]
        }
        return [rowCollectionView]
    }

    /// Window-frame of an item's tile, for preview entry-morphs.
    func frameInWindow(forItem index: Int) -> CGRect? {
        guard let attrs = rowCollectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)),
              let window = window else { return nil }
        return rowCollectionView.convert(attrs.frame, to: window)
    }

    private func applyMetrics(for kind: TileKind) {
        flow.itemSize = CGSize(width: kind.tileWidth, height: kind.tileHeight)
        flow.minimumLineSpacing = kind.gap
        flow.minimumInteritemSpacing = kind.gap
        flow.sectionInset = UIEdgeInsets(
            top: 0,
            left: MediaRowMetrics.rowLeading + panelOvershoot.left,
            bottom: 0,
            right: MediaRowMetrics.rowTrailing + panelOvershoot.right
        )
    }

    // MARK: Offset math

    /// First fully-visible column implied by an offset (offsets only ever
    /// hold pitch multiples; rounding guards float fuzz).
    private func column(for offset: CGFloat) -> Int {
        Int((offset / tileKind.pitch).rounded())
    }

    private func maxColumn() -> Int {
        max(0, displayCount - tileKind.fullCount)
    }

    /// Smallest window shift that brings `itemIndex` fully into view. While a
    /// settle is in flight the logical position is its TARGET (the visual
    /// offset is mid-glide and would round to a stale column under held
    /// presses).
    private func snappedOffset(toShow itemIndex: Int) -> CGFloat {
        let logicalX = offsetLink != nil ? animTargetX : rowCollectionView.contentOffset.x
        let fCur = column(for: logicalX)
        var f = min(max(fCur, itemIndex - (tileKind.fullCount - 1)), itemIndex)
        f = min(max(0, f), maxColumn())
        return CGFloat(f) * tileKind.pitch
    }

    private func setOffset(clampedTo x: CGFloat, animated: Bool = false) {
        offsetLink?.invalidate()
        offsetLink = nil
        let maxOffset = CGFloat(maxColumn()) * tileKind.pitch
        let clamped = min(max(0, x), maxOffset)
        rowCollectionView.setContentOffset(CGPoint(x: clamped, y: 0), animated: animated)
        onOffsetChanged?(clamped)
    }

    /// Driven settle to a pitch-aligned offset: per-frame CADisplayLink with
    /// the shared FocusScrollMotion duration + cubic ease-out. Retargets
    /// continue from the current (mid-flight) position so held presses glide.
    private func animateOffset(to x: CGFloat) {
        offsetLink?.invalidate()
        animStartX = rowCollectionView.contentOffset.x
        animTargetX = x
        animStartTime = CACurrentMediaTime()
        // Weak proxy: CADisplayLink retains its target; a cell deallocated
        // mid-flight would otherwise leak with a live link.
        let link = CADisplayLink(target: LinkProxy(self), selector: #selector(LinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        offsetLink = link
    }

    fileprivate func stepOffset(_ link: CADisplayLink) {
        let t = min(1, (CACurrentMediaTime() - animStartTime) / FocusScrollMotion.settleDuration)
        let e = CGFloat(FocusScrollMotion.ease(t))
        rowCollectionView.contentOffset.x = animStartX + (animTargetX - animStartX) * e
        if t >= 1 {
            link.invalidate()
            if offsetLink === link { offsetLink = nil }
        }
    }

    private final class LinkProxy: NSObject {
        private weak var owner: ShelfRowCell?
        init(_ owner: ShelfRowCell) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.stepOffset(link)
        }
    }
}

// MARK: - Inner collection plumbing

extension ShelfRowCell: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        displayCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        cellProvider?(collectionView, indexPath) ?? collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < realCount else { return }  // skeleton: ignore
        onSelect?(indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        onWillDisplayItem?(indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, indexPath.item < realCount else { return nil }
        guard let provider = contextMenuProvider else { return nil }
        let index = indexPath.item
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            provider(index)
        }
    }

    /// The one driver of horizontal scroll: shift the window only as far as
    /// needed to keep the focused tile inside the N fully-visible columns
    /// (ATV+ feel — no scroll while moving within view, a one-pitch shift
    /// when crossing the window edge). Driven with the shared
    /// FocusScrollMotion settle so it matches the vertical row scroll.
    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard let next = context.nextFocusedIndexPath else { return }
        let target = snappedOffset(toShow: next.item)
        guard abs(target - collectionView.contentOffset.x) > 0.5 else { return }
        animateOffset(to: target)
        onOffsetChanged?(target)
    }

    /// Keep a Left press at the window edge from escaping to the sidebar
    /// while older items exist offscreen-left (they're virtualized out of the
    /// focus chain). Mirror of the home's orthogonal-row interceptor: block
    /// the escape, shift the window one pitch, and let the engine re-poll.
    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        guard context.focusHeading == .left,
              let prev = context.previouslyFocusedIndexPath,
              prev.item > 0
        else { return true }
        let nextIsInside = context.nextFocusedView?.isDescendant(of: collectionView) ?? false
        guard !nextIsInside else { return true }

        setOffset(clampedTo: snappedOffset(toShow: prev.item - 1), animated: false)
        collectionView.layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
        return false
    }
}
