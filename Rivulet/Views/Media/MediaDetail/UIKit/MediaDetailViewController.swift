//
//  MediaDetailViewController.swift
//  Rivulet
//
//  UIKit replacement for the SwiftUI `MediaDetailView`. Supports two
//  presentation modes:
//
//   - `.previewCarousel`: embedded as a child VC inside a
//     `PreviewCarouselViewController` slot. Renders only the hero
//     content; below-fold sections are deferred until expansion.
//   - `.expandedDetail`: full-screen detail surface. Renders hero +
//     all below-fold sections.
//
//  This file lands the skeleton (compositional-layout collection view
//  with empty cells). Iteration 2 wires the hero cell; later
//  iterations wire seasons / episodes / related / collection / cast
//  and the data-load cascade.
//
//  Authoritative behavior reference:
//  perf-spike/DETAIL_AUDIT.md
//

import UIKit
import os.log

private let mediaDetailLog = Logger(
    subsystem: "com.rivulet.app",
    category: "MediaDetailUIKit"
)

/// `MediaDetailPresentationMode` is shared with the SwiftUI
/// `MediaDetailView` (see `MediaDetailView.swift`) — same two cases,
/// `.previewCarousel` and `.expandedDetail`. We reuse it so call sites
/// can flip between the SwiftUI and UIKit implementations behind a
/// feature flag without changing the model.

/// Identifies a section in the detail collection view. Sections are
/// added / removed dynamically based on what data is available
/// (e.g. `.seasons` only appears for shows; `.collection` only
/// when there's a collection backing the item).
enum MediaDetailSection: Int, Hashable, CaseIterable {
    case hero = 0
    case seasons
    case episodes
    case related
    case collection
    case cast
    case belowFoldTitle
}

final class MediaDetailViewController: UIViewController {
    // MARK: - Inputs

    /// The item being displayed.
    private(set) var item: MediaItem

    /// Carousel vs full-screen behavior.
    private(set) var presentationMode: MediaDetailPresentationMode

    /// Whether this controller is the currently-focused slot (only
    /// meaningful in `.previewCarousel` mode). Drives whether data
    /// loads.
    var isCurrent: Bool = true

    /// Whether the entry / paging cascade has finished. Drives whether
    /// data loads in carousel mode. Always true in `.expandedDetail`.
    var previewAnimationSettled: Bool = false

    // MARK: - Views

    private var collectionView: UICollectionView!

    // MARK: - Lifecycle

    init(item: MediaItem, mode: MediaDetailPresentationMode) {
        self.item = item
        self.presentationMode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MediaDetailViewController is not Storyboard-backed")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let layout = makeLayout()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.dataSource = self
        collectionView.delegate = self
        // Iteration 2+ registers real cells; the skeleton dequeues
        // plain placeholder cells so the layout machinery is exercised.
        collectionView.register(
            UICollectionViewCell.self,
            forCellWithReuseIdentifier: PlaceholderReuseID
        )
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        mediaDetailLog.debug("viewDidLoad — item=\(self.item.title, privacy: .public) mode=\(String(describing: self.presentationMode), privacy: .public)")
    }

    // MARK: - Reconfigure (carousel slot recycling)

    /// Called by the carousel host when this controller's slot becomes
    /// the new neighbor (n-1 / n+1) of a different item. Avoids the
    /// cost of recreating the controller.
    func configure(with item: MediaItem, mode: MediaDetailPresentationMode) {
        self.item = item
        self.presentationMode = mode
        // Iteration 2+: invalidate hero cell, kick off prefetch,
        // reset gates.
        collectionView?.reloadData()
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        // Skeleton layout: a single full-bounds section per
        // MediaDetailSection. Iteration 2+ replaces each branch with
        // the real layout (orthogonal scrolling rows, hero anchored,
        // below-fold reveal with reserved insets etc.).
        return UICollectionViewCompositionalLayout { sectionIndex, environment in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(100)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
            return NSCollectionLayoutSection(group: group)
        }
    }
}

// MARK: - UICollectionViewDataSource

extension MediaDetailViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        // Skeleton: just the hero. Iteration 3 adds the others.
        return 1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return 1
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PlaceholderReuseID,
            for: indexPath
        )
        cell.contentView.backgroundColor = .darkGray.withAlphaComponent(0.2)
        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension MediaDetailViewController: UICollectionViewDelegate {}

// MARK: - Constants

private let PlaceholderReuseID = "MediaDetailPlaceholderCell"
