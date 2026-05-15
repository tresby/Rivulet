//
//  HeroOverlayCell.swift
//  Rivulet
//
//  Collection-view cell that hosts the existing SwiftUI `HeroOverlayContent`
//  via `UIHostingConfiguration`. The cell is full-width and roughly
//  `UIScreen.bounds.height - 200pt` tall — a deliberate Continue Watching
//  peek matches the SwiftUI home.
//
//  The transparent foreground (logo / metadata / Play/Watchlist/Info/Next
//  buttons / paging dots) lives in this scrolling cell so it tracks the
//  rest of the content. The actual backdrop image is a sibling view of
//  the collection view (see `HeroBackdropView`), translated independently
//  via `scrollViewDidScroll` for the receding-parallax effect.
//

import UIKit
import SwiftUI

@MainActor
final class HeroOverlayCell: UICollectionViewCell {
    static let reuseID = "HeroOverlayCell"

    private var hostingController: UIHostingController<AnyView>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    struct Configuration {
        let items: [PlexMetadata]
        let serverURL: String
        let authToken: String
        let initialIndex: Int
        let onIndexChanged: (Int) -> Void
        let onInfo: (PlexMetadata) -> Void
        let onPlay: (PlexMetadata) -> Void
    }

    /// Configure with a fresh `HeroOverlayContent`. Reconfigures the host
    /// controller's root view in place to preserve focus + view state.
    func configure(with config: Configuration, parentVC: UIViewController) {
        let binding = HeroIndexBindingHolder.binding(for: self, initial: config.initialIndex, onChange: config.onIndexChanged)
        let content = HeroOverlayContent(
            items: config.items,
            serverURL: config.serverURL,
            authToken: config.authToken,
            currentIndex: binding,
            onInfo: config.onInfo,
            onPlay: config.onPlay
        )
        let wrapped = AnyView(
            content
                .environment(MediaProviderRegistry.shared)
                .environment(MusicProviderRegistry.shared)
                .environment(MetadataSourceRegistry.shared)
        )

        if let hostingController {
            hostingController.rootView = wrapped
        } else {
            let host = UIHostingController(rootView: wrapped)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            parentVC.addChild(host)
            contentView.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
            ])
            host.didMove(toParent: parentVC)
            hostingController = host
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Don't tear down the hosting controller — it's expensive to rebuild
        // and the controller reuses this cell on every snapshot apply.
    }
}

/// Bridges UIKit's index-tracking with SwiftUI's `Binding<Int>` requirement
/// inside `HeroOverlayContent`. Each cell instance gets its own
/// `IndexHolder` keyed by the cell pointer so multiple hero cells in
/// flight (during diffing) don't clobber each other.
@MainActor
private enum HeroIndexBindingHolder {
    static func binding(
        for cell: HeroOverlayCell,
        initial: Int,
        onChange: @escaping (Int) -> Void
    ) -> Binding<Int> {
        let key = ObjectIdentifier(cell)
        let holder = holders[key] ?? IndexHolder(value: initial)
        holder.onChange = onChange
        if !holders.keys.contains(key) {
            holders[key] = holder
        }
        return Binding(
            get: { holder.value },
            set: { newValue in
                holder.value = newValue
                holder.onChange?(newValue)
            }
        )
    }

    private static var holders: [ObjectIdentifier: IndexHolder] = [:]

    final class IndexHolder {
        var value: Int
        var onChange: ((Int) -> Void)?
        init(value: Int) { self.value = value }
    }
}
