//
//  HeroOverlayCell.swift
//  Rivulet
//
//  Thin `UICollectionViewCell` wrapper around the native UIKit
//  `HeroOverlayView`. Previously hosted SwiftUI `HeroOverlayContent` via
//  `UIHostingController`; replaced because the SwiftUI/UIKit focus
//  boundary at the hero's edge caused the focus engine to drop requests
//  trying to move down from the hero buttons to Continue Watching.
//
//  Cell itself never accepts focus (`canBecomeFocused = false`) and
//  forwards `preferredFocusEnvironments` to the overlay so the focus
//  engine sees the Play / Watchlist / Info / Next buttons directly.
//

import UIKit

@MainActor
final class HeroOverlayCell: UICollectionViewCell {
    static let reuseID = "HeroOverlayCell"

    let overlay = HeroOverlayView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        clipsToBounds = false
        contentView.clipsToBounds = false

        overlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [overlay]
    }

    struct Configuration {
        let items: [PlexMetadata]
        let serverURL: String
        let authToken: String
        let initialIndex: Int
        let onIndexChanged: (Int) -> Void
        let onInfo: (PlexMetadata) -> Void
        let onPlay: (PlexMetadata) -> Void
        let onFocusEntered: (() -> Void)?
    }

    func configure(with config: Configuration) {
        overlay.onIndexChanged = config.onIndexChanged
        overlay.onInfo = config.onInfo
        overlay.onPlay = config.onPlay
        overlay.onFocusEntered = config.onFocusEntered
        overlay.configure(
            items: config.items,
            serverURL: config.serverURL,
            authToken: config.authToken,
            initialIndex: config.initialIndex
        )
    }
}
