//
//  PosterSkeletonCell.swift
//  Rivulet
//
//  Loading-placeholder cell for the end of a paginating hub row. Mirrors
//  SwiftUI `InfiniteContentRow.skeletonPosterCard` (`PlexHomeView.swift:1403-1430`)
//  for both poster (260x390 portrait + title placeholder rows) and
//  Continue Watching (392x280 landscape) variants.
//
//  Two sizing modes are supported via `configure(isContinueWatching:)`:
//   - false: portrait poster + two title placeholder rows
//   - true:  wide landscape card, no title rows
//

import UIKit

@MainActor
final class PosterSkeletonCell: UICollectionViewCell {
    static let reuseID = "PosterSkeletonCell"

    enum Layout {
        case poster
        case continueWatching
    }

    private let posterPlaceholder = UIView()
    private let titleRow1 = UIView()
    private let titleRow2 = UIView()
    private let stack = UIStackView()

    private var posterWidthConstraint: NSLayoutConstraint!
    private var posterHeightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        let cornerRadius: CGFloat = 16
        posterPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        posterPlaceholder.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        posterPlaceholder.layer.cornerRadius = cornerRadius
        posterPlaceholder.layer.cornerCurve = .continuous

        titleRow1.translatesAutoresizingMaskIntoConstraints = false
        titleRow1.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        titleRow1.layer.cornerRadius = 4
        titleRow1.layer.cornerCurve = .continuous

        titleRow2.translatesAutoresizingMaskIntoConstraints = false
        titleRow2.backgroundColor = UIColor.white.withAlphaComponent(0.04)
        titleRow2.layer.cornerRadius = 4
        titleRow2.layer.cornerCurve = .continuous

        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(posterPlaceholder)
        let titleStack = UIStackView(arrangedSubviews: [titleRow1, titleRow2])
        titleStack.axis = .vertical
        titleStack.spacing = 6
        titleStack.alignment = .leading
        stack.addArrangedSubview(titleStack)

        contentView.addSubview(stack)

        posterWidthConstraint = posterPlaceholder.widthAnchor.constraint(equalToConstant: 260)
        posterHeightConstraint = posterPlaceholder.heightAnchor.constraint(equalToConstant: 390)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),

            posterWidthConstraint,
            posterHeightConstraint,

            titleRow1.widthAnchor.constraint(equalToConstant: 160),
            titleRow1.heightAnchor.constraint(equalToConstant: 14),
            titleRow2.widthAnchor.constraint(equalToConstant: 100),
            titleRow2.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    func configure(layout: Layout) {
        switch layout {
        case .poster:
            posterWidthConstraint.constant = 220
            posterHeightConstraint.constant = 330
            titleRow1.isHidden = false
            titleRow2.isHidden = false
        case .continueWatching:
            posterWidthConstraint.constant = 392
            posterHeightConstraint.constant = 280
            titleRow1.isHidden = true
            titleRow2.isHidden = true
        }
    }
}
