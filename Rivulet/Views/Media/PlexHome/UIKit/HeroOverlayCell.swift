//
//  HeroOverlayCell.swift
//  Rivulet
//
//  Collection-view cell that hosts the existing SwiftUI `HeroOverlayContent`
//  via `UIHostingController`. The cell is full-width and roughly
//  `UIScreen.bounds.height - 200pt` tall — a deliberate Continue Watching
//  peek matches the SwiftUI home.
//
//  The transparent foreground (logo / metadata / Play/Watchlist/Info/Next
//  buttons / paging dots) lives in this scrolling cell so it tracks the
//  rest of the content. The actual backdrop image is a sibling view of
//  the collection view (see `HeroBackdropView`), translated independently
//  via `scrollViewDidScroll` for the receding-parallax effect.
//
//  Focus forwarding: `UICollectionViewCell` is focusable by default, which
//  would let it eat focus and never delegate to the SwiftUI buttons inside.
//  We disable cell focus (`canBecomeFocused = false`) and let the hosting
//  controller's view participate in the focus chain directly — SwiftUI's
//  `@FocusState` + `Button` then work as if they were a top-level view.
//

import UIKit
import SwiftUI

@MainActor
final class HeroOverlayCell: UICollectionViewCell {
    static let reuseID = "HeroOverlayCell"

    private var hostingController: UIHostingController<AnyView>?

    /// Cell-scoped binding storage for `HeroOverlayContent`'s `currentIndex`.
    /// Lives with the cell so when the cell deallocates the holder dies with
    /// it — no global static dictionary keyed by ObjectIdentifier required.
    private final class IndexHolder {
        var value: Int = 0
        var onChange: ((Int) -> Void)?
    }
    private let indexHolder = IndexHolder()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Focus forwarding
    //
    // Cell itself never becomes focused. The focus engine sees the hosting
    // controller's view (the SwiftUI tree containing Play/Watchlist/Info/Next
    // buttons) as the next focus environment.

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let host = hostingController?.view {
            return [host]
        }
        return super.preferredFocusEnvironments
    }

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
        indexHolder.value = config.initialIndex
        indexHolder.onChange = config.onIndexChanged
        let holder = indexHolder
        let binding = Binding<Int>(
            get: { holder.value },
            set: { newValue in
                holder.value = newValue
                holder.onChange?(newValue)
            }
        )

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
