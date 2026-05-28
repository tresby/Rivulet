//
//  HubHeaderView.swift
//  Rivulet
//
//  Section headers above each home row. Two distinct styles in SwiftUI
//  that must both be supported here:
//
//   - InfiniteContentRow / ContentRow (Continue Watching, Recently Added,
//     Personalized Recommendations): 30pt semibold, foreground white-0.6,
//     with an inline 17pt medium white-0.3 count indicator. Spacing
//     between title + count is 12pt. The count reads either
//     "<loaded> of <total>" (when total > loaded) or "All <count>"
//     (when paginated through and total exceeds page size).
//
//   - WatchlistHubRow: ScaledDimensions.sectionTitleSize (30pt) bold,
//     full white. No count.
//
//  Style is set per-configure via `Style.swiftUIInfiniteRow` or
//  `.swiftUIWatchlist` — the dataSource picks the right one per section.
//

import UIKit

@MainActor
final class HubHeaderView: UICollectionReusableView {
    static let reuseID = "HubHeaderView"

    enum Style {
        case swiftUIInfiniteRow
        case swiftUIWatchlist
    }

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.isHidden = true

        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .lastBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(countLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            // Pinned bottom-leading with 48pt leading inset and 0pt bottom
            // inset so the title sits flush with the row's first item
            // (SwiftUI VStack(spacing: 0) between header and scroll).
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -48),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// Configure with `title`, optional `loadedCount` / `totalCount` (only
    /// honoured for `.swiftUIInfiniteRow` style — Watchlist headers never
    /// show a count).
    func configure(title: String,
                   style: Style,
                   loadedCount: Int? = nil,
                   totalCount: Int? = nil,
                   pageSize: Int = 24) {
        switch style {
        case .swiftUIInfiniteRow:
            titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
            titleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        case .swiftUIWatchlist:
            titleLabel.font = .systemFont(ofSize: ScaledDimensions.sectionTitleSize, weight: .bold)
            titleLabel.textColor = .white
        }
        titleLabel.text = title

        if style == .swiftUIInfiniteRow,
           let loaded = loadedCount,
           let total = totalCount,
           total > loaded {
            // SwiftUI: "X of Y" only when total > items.count.
            countLabel.font = .systemFont(ofSize: 17, weight: .medium)
            countLabel.textColor = UIColor.white.withAlphaComponent(0.3)
            countLabel.text = "\(loaded) of \(total)"
            countLabel.isHidden = false
        } else if style == .swiftUIInfiniteRow,
                  let loaded = loadedCount,
                  loaded > pageSize {
            // SwiftUI: "All <count>" once paginated through (hasReachedEnd
            // && items.count > pageSize). We approximate "hasReachedEnd"
            // by absence of a totalCount or totalCount == loadedCount.
            if totalCount == nil || totalCount == loaded {
                countLabel.font = .systemFont(ofSize: 17, weight: .medium)
                countLabel.textColor = UIColor.white.withAlphaComponent(0.3)
                countLabel.text = "All \(loaded)"
                countLabel.isHidden = false
            } else {
                countLabel.text = nil
                countLabel.isHidden = true
            }
        } else {
            countLabel.text = nil
            countLabel.isHidden = true
        }
    }
}
