//
//  PreviewCardView.swift
//  Rivulet
//
//  One hero card in the preview carousel. A UICollectionViewCell so
//  the collection view handles cell recycling + positioning; we
//  override `apply(_:)` to read parallax + alpha from custom layout
//  attributes computed by `PreviewCarouselLayout` based on the
//  cell's distance from the centered viewport position.
//
//  Chrome cascade (selected center cell only):
//   - Vignette gradients (left scrim + bottom scrim) fade in 140ms
//     after paging settles, over 260ms easeOut.
//   - Title logo + metadata stack fade in 210ms after paging settles
//     (70ms after vignette), over 480ms easeOut.
//   - On paging start, both snap to alpha 0 (no fade-out).
//   Timings match perf-spike research from the SwiftUI source
//   (page-cascade branch — see perf-spike/CAROUSEL_COMPARISON.md
//   research notes).
//
//  Designed to keep offscreen passes near zero outside the entry
//  storm: single rounded clip on contentView, opaque backdrop, no
//  Material, no shadows. CAGradientLayer sublayers for the vignette
//  (one offscreen pass each, rasterized by Core Animation once).
//

import UIKit
import os.log

private let previewCardLog = Logger(
    subsystem: "com.rivulet.app",
    category: "PreviewCardView"
)

final class PreviewCardView: UICollectionViewCell {
    static let reuseIdentifier = "PreviewCardCell"

    // MARK: - State

    /// Current item this card is showing. `nil` means the card is
    /// idle (cleared for reuse). Setting the property kicks off
    /// artwork loading.
    var item: MediaItem? {
        didSet {
            guard item != oldValue else { return }
            applyItem()
        }
    }

    /// Whether this cell is the currently-focused / centered card in
    /// the carousel. Drives the chrome cascade — only the current
    /// cell shows vignette + metadata. Side peeks render bare
    /// backdrop only.
    ///
    /// Use `setIsCurrent(_:animated:)` rather than assigning directly
    /// so the cascade fires with the right animation behavior.
    private(set) var isCurrent: Bool = false

    /// Monotonic load token. Bumped on every `applyItem()`; the async
    /// image fetch + detail fetch check against this on completion
    /// and discard stale results. Prevents the wrong artwork or wrong
    /// metadata from snapping in when the user pages quickly.
    private var loadToken: UInt64 = 0

    /// Cached detail, populated by loadDetail() when it lands. Used
    /// to repopulate the genre + quality rows with richer fields.
    private var detail: MediaItemDetail?

    /// Monotonic cascade token. Bumped on every cascade kickoff so
    /// any in-flight delayed animations from a prior cascade are
    /// discarded if the cell is paged away before they fire.
    private var cascadeToken: UInt64 = 0

    // MARK: - Subviews (inside contentView)

    /// Backdrop is rendered at the FULL SCREEN size, not the card
    /// size. The card's contentView clips to its card-sized bounds
    /// (the visible window), but the image extends past the clip on
    /// all sides. Manual frame management — see layoutSubviews.
    private let backdropImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = true
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = false
        v.isOpaque = true
        v.backgroundColor = .black
        return v
    }()

    /// Stage size — full screen size, set by the layout's
    /// PreviewCardLayoutAttributes. Used to size the backdrop image
    /// view so it extends past the cell's clip on all sides.
    private var stageSize: CGSize = .zero

    /// Parallax offset from the latest layout attributes. Applied as
    /// a delta to backdropImageView.center.x in layoutSubviews so we
    /// never have to juggle frame + transform on the same view (which
    /// UIKit explicitly warns is undefined).
    private var parallaxOffsetX: CGFloat = 0

    /// Vignette container — holds left + bottom gradient sublayers.
    /// Alpha 0 by default; cascade fades to 1.
    private let vignetteContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        v.alpha = 0
        return v
    }()

    /// Left-side darkening gradient. Subtle — peaks at 0.7 black at
    /// the leading edge, drops to 0.12 at 42% across, clears at 55%.
    /// Matches MediaDetailView.swift:1657-1666 stops exactly.
    private let leftGradientLayer: CAGradientLayer = {
        let g = CAGradientLayer()
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        g.colors = [
            UIColor.black.withAlphaComponent(0.70).cgColor,
            UIColor.black.withAlphaComponent(0.40).cgColor,
            UIColor.black.withAlphaComponent(0.12).cgColor,
            UIColor.clear.cgColor
        ]
        g.locations = [0.0, 0.25, 0.42, 0.55]
        return g
    }()

    /// Bottom-fading gradient. Five-stop ramp from clear (top) to
    /// 0.95 black (bottom). Covers 55% of the card height.
    /// Matches MediaDetailView.swift:1673-1683 stops exactly.
    private let bottomGradientLayer: CAGradientLayer = {
        let g = CAGradientLayer()
        g.startPoint = CGPoint(x: 0.5, y: 0)
        g.endPoint = CGPoint(x: 0.5, y: 1)
        g.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.25).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.withAlphaComponent(0.80).cgColor,
            UIColor.black.withAlphaComponent(0.95).cgColor
        ]
        g.locations = [0.0, 0.2, 0.4, 0.65, 1.0]
        return g
    }()

    /// Chrome container — holds the whole metadata stack (logo, genre
    /// row, description, quality row). Positioned to mirror SwiftUI's
    /// `heroMetadataOverlay`: pinned to the bottom-leading corner of
    /// the card with `heroOverlayHorizontalInset` (118pt) inset, and
    /// occupying a 420pt-tall slot. The inner VStack is bottom-leading
    /// aligned so the chrome grows upward as more data loads. Alpha 0
    /// by default; cascade fades to 1.
    private let chromeContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        v.alpha = 0
        return v
    }()

    /// Vertical stack of chrome rows, bottom-leading aligned inside
    /// the chromeContainer. Spacing matches SwiftUI's hero metadata
    /// overlay (14pt between rows).
    ///
    /// The stack contains TWO blocks:
    /// 1. `metadataBlock` — logo / genre / description / quality.
    ///    Capped at 760pt wide. Mirrors the inner VStack at SwiftUI
    ///    MediaDetailView lines 722-846.
    /// 2. `actionAndCastRow` — full container width so cast text can
    ///    right-align against the chrome container's far edge.
    ///    Mirrors the outer HStack at lines 852-876.
    private let chromeStack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        s.alignment = .fill   // children get full stack width; we
                              // constrain narrower content separately.
        s.spacing = 14
        return s
    }()

    /// Inner metadata block — capped at 760pt wide per SwiftUI.
    private let metadataBlock: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        s.alignment = .leading
        s.spacing = 14
        return s
    }()

    /// Logo slot — fixed 138pt tall, 620pt max wide, bottom-leading
    /// aligned. Either the logoImageView or the titleFallbackLabel
    /// occupies the slot depending on whether artwork.logo loaded.
    private let logoSlotView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let titleLogoImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let titleFallbackLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 52, weight: .bold)
        l.textColor = .white
        l.numberOfLines = 2
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    /// Genre row — "Movie · Adventure · Sci-Fi  [TV-14]" — caption
    /// font, white 0.85 opacity. Content rating badge is appended
    /// when detail data populates it.
    private let genreRow: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.spacing = 8
        s.alignment = .center
        return s
    }()

    /// Description text. Up to 3 lines, 560pt max width. Populated
    /// from MediaItemDetail.tagline / item.overview.
    private let descriptionLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 19, weight: .regular)
        l.textColor = UIColor.white.withAlphaComponent(0.85)
        l.numberOfLines = 3
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    /// Quality row — "2023 · 49 min   ⭐ 7.8   [4K] [DV] [5.1]" —
    /// caption.bold(), pure white.
    private let qualityRow: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.spacing = 8
        s.alignment = .center
        return s
    }()

    /// Width constraint for the description label so it can wrap.
    /// Lazy because contentView bounds aren't known at init time.
    private var descriptionMaxWidth: NSLayoutConstraint?

    /// Bottom action row — Play pill on the left, cast "Starring..."
    /// text on the right. In carousel-stable mode this is visible
    /// but interaction-disabled (the buttons are styled placeholders;
    /// real focus + action wiring lands when we build expand-to-detail).
    private let actionAndCastRow: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.alignment = .center
        s.distribution = .fill
        s.spacing = 40
        s.isUserInteractionEnabled = false
        return s
    }()

    /// Left-hand cluster: Play pill + Watched / Info circles.
    private let actionButtonsStack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.alignment = .center
        s.spacing = 18
        return s
    }()

    /// Right-hand cluster: "Starring [cast]" text, right-aligned.
    private let castLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 19, weight: .regular)
        l.textColor = UIColor.white.withAlphaComponent(0.85)
        l.numberOfLines = 3
        l.textAlignment = .right
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewCardView is not Storyboard-backed")
    }

    private func commonInit() {
        backgroundColor = .clear
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
        contentView.layer.cornerCurve = .continuous

        contentView.addSubview(backdropImageView)
        vignetteContainer.layer.addSublayer(leftGradientLayer)
        vignetteContainer.layer.addSublayer(bottomGradientLayer)
        contentView.addSubview(vignetteContainer)
        contentView.addSubview(chromeContainer)

        // Logo slot: 620pt max width, 138pt fixed height. The image +
        // fallback label both pin to bottom-leading inside, so a
        // short-aspect logo sits at the bottom of the slot.
        logoSlotView.addSubview(titleLogoImageView)
        logoSlotView.addSubview(titleFallbackLabel)

        // Chrome stack order matches MediaDetailView.heroMetadataOverlay
        // (lines 715-848). Bottom-leading aligned via the stack's
        // alignment + the chromeContainer's bottom anchor below.
        chromeContainer.addSubview(chromeStack)

        // Metadata block (logo / genre / description / quality) lives
        // inside its own 760pt-capped stack so it's narrower than the
        // outer chrome row. SwiftUI: lines 722-846.
        metadataBlock.addArrangedSubview(logoSlotView)
        metadataBlock.addArrangedSubview(genreRow)
        metadataBlock.addArrangedSubview(descriptionLabel)
        metadataBlock.addArrangedSubview(qualityRow)
        chromeStack.addArrangedSubview(metadataBlock)

        // 32pt extra space between metadata block and the action+cast
        // row — matches SwiftUI heroActionRowTopPadding (32pt in
        // carousel mode).
        chromeStack.setCustomSpacing(32, after: metadataBlock)
        chromeStack.addArrangedSubview(actionAndCastRow)

        actionAndCastRow.addArrangedSubview(actionButtonsStack)
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionAndCastRow.addArrangedSubview(spacer)
        actionAndCastRow.addArrangedSubview(castLabel)

        let descMaxWidth = descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        descMaxWidth.priority = .required
        descriptionMaxWidth = descMaxWidth

        NSLayoutConstraint.activate([
            // Vignette covers the full card; the gradient layers do
            // the actual fading.
            vignetteContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            vignetteContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            vignetteContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            vignetteContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Chrome container: 118pt horizontal inset (matches
            // SwiftUI heroOverlayHorizontalInset for carousel mode),
            // bottom-leading anchored. The stack inside is allowed to
            // grow up to 760pt wide (heroMetadataOverlay maxWidth).
            chromeContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 118),
            // Chrome container spans card width minus 118pt insets on
            // both sides — gives the action+cast row a wide span so
            // cast text can right-align against the chrome's far edge.
            // The metadata block inside is separately capped at 760pt.
            chromeContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -118),
            // Chrome sits 220pt up from the card's bottom — matches the
            // SwiftUI hero's `shelfPeek` reserve which keeps the below-
            // fold "Related" row peeking from beneath the hero.
            chromeContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -220),

            // Stack anchored to chromeContainer bounds (which is the
            // bottom-leading slot).
            chromeStack.leadingAnchor.constraint(equalTo: chromeContainer.leadingAnchor),
            chromeStack.trailingAnchor.constraint(equalTo: chromeContainer.trailingAnchor),
            chromeStack.topAnchor.constraint(equalTo: chromeContainer.topAnchor),
            chromeStack.bottomAnchor.constraint(equalTo: chromeContainer.bottomAnchor),

            // Logo slot: 138pt tall, 620pt max wide. Acts as a
            // bounding box; the image inside renders at its natural
            // aspect ratio capped to these dimensions.
            logoSlotView.heightAnchor.constraint(equalToConstant: 138),
            logoSlotView.widthAnchor.constraint(lessThanOrEqualToConstant: 620),

            // Logo image: bottom-leading inside the slot. NO height
            // constraint — aspectFit + intrinsic size means a
            // 500×120 logo renders at 500×120, anchored bottom-left.
            // A logo that's exactly 138 tall caps at 138; one that's
            // 100 tall stays 100.
            titleLogoImageView.leadingAnchor.constraint(equalTo: logoSlotView.leadingAnchor),
            titleLogoImageView.trailingAnchor.constraint(lessThanOrEqualTo: logoSlotView.trailingAnchor),
            titleLogoImageView.bottomAnchor.constraint(equalTo: logoSlotView.bottomAnchor),
            titleLogoImageView.topAnchor.constraint(greaterThanOrEqualTo: logoSlotView.topAnchor),
            // Cap the image's height to the slot — without this the
            // intrinsic content size could push it above the slot
            // when the source PNG is taller than 138pt.
            titleLogoImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 138),

            // Fallback label: occupies the slot (one of the two is
            // hidden via isHidden based on logo URL availability).
            titleFallbackLabel.leadingAnchor.constraint(equalTo: logoSlotView.leadingAnchor),
            titleFallbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: logoSlotView.trailingAnchor),
            titleFallbackLabel.bottomAnchor.constraint(equalTo: logoSlotView.bottomAnchor),

            descMaxWidth,

            // action+cast row fills the chrome container width so the
            // play button anchors left and the cast text anchors right.
            actionAndCastRow.leadingAnchor.constraint(equalTo: chromeStack.leadingAnchor),
            actionAndCastRow.trailingAnchor.constraint(equalTo: chromeStack.trailingAnchor),

            // Cast label capped at 460pt (matches SwiftUI line 873).
            castLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Backdrop at full stage size, centered + parallaxed.
        if stageSize.width > 0 {
            backdropImageView.bounds = CGRect(origin: .zero, size: stageSize)
        } else {
            backdropImageView.bounds = CGRect(origin: .zero, size: contentView.bounds.size)
        }
        backdropImageView.center = CGPoint(
            x: contentView.bounds.midX + parallaxOffsetX,
            y: contentView.bounds.midY
        )

        // Vignette gradient frames match the container bounds. Left
        // gradient covers full height + first 55% width (clipped by
        // the gradient stops themselves); bottom covers full width +
        // bottom 55% height.
        let bounds = contentView.bounds
        leftGradientLayer.frame = bounds
        let bottomHeight = bounds.height * 0.55
        bottomGradientLayer.frame = CGRect(
            x: 0,
            y: bounds.height - bottomHeight,
            width: bounds.width,
            height: bottomHeight
        )

        CATransaction.commit()
    }

    // MARK: - Custom layout attribute application

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        guard let attrs = layoutAttributes as? PreviewCardLayoutAttributes else { return }

        if attrs.stageSize != stageSize {
            stageSize = attrs.stageSize
        }

        parallaxOffsetX = attrs.parallaxOffsetX
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropImageView.center = CGPoint(
            x: contentView.bounds.midX + parallaxOffsetX,
            y: contentView.bounds.midY
        )
        CATransaction.commit()
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken &+= 1
        cascadeToken &+= 1
        backdropImageView.image = nil
        parallaxOffsetX = 0
        isCurrent = false
        vignetteContainer.alpha = 0
        chromeContainer.alpha = 0
        titleLogoImageView.image = nil
        titleFallbackLabel.text = nil
        titleLogoImageView.isHidden = false
        titleFallbackLabel.isHidden = false
        descriptionLabel.text = nil
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionButtonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        castLabel.text = nil
        detail = nil
        item = nil
    }

    // MARK: - Chrome cascade

    /// Update whether this cell is the currently-focused center card,
    /// optionally with the timed fade-in cascade.
    ///
    /// Passing `animated: true` runs the SwiftUI page-cascade timing:
    /// vignette fades in 140ms after call, chrome fades in 210ms after
    /// call (70ms stagger). Passing `animated: false` snaps to the
    /// final alpha values — used when the user pages away.
    func setIsCurrent(_ current: Bool, animated: Bool) {
        guard isCurrent != current || !animated else { return }
        isCurrent = current
        cascadeToken &+= 1
        let token = cascadeToken

        // Cancel any in-flight animations by reading the current
        // presentation alpha and committing it as the model value,
        // then issuing the new animation from there.
        let currentVignetteAlpha = vignetteContainer.layer.presentation()?.opacity ?? Float(vignetteContainer.alpha)
        let currentChromeAlpha = chromeContainer.layer.presentation()?.opacity ?? Float(chromeContainer.alpha)
        vignetteContainer.layer.removeAllAnimations()
        chromeContainer.layer.removeAllAnimations()
        vignetteContainer.alpha = CGFloat(currentVignetteAlpha)
        chromeContainer.alpha = CGFloat(currentChromeAlpha)

        if !current {
            // Snap to invisible. No fade-out — matches SwiftUI behavior.
            vignetteContainer.alpha = 0
            chromeContainer.alpha = 0
            return
        }

        if !animated {
            vignetteContainer.alpha = 1
            chromeContainer.alpha = 1
            return
        }

        // Cascade: vignette at 140ms / 260ms duration, chrome at
        // 210ms / 480ms duration. Both easeOut.
        UIView.animate(
            withDuration: 0.26,
            delay: 0.14,
            options: [.curveEaseOut, .allowUserInteraction]
        ) { [weak self] in
            guard let self, self.cascadeToken == token else { return }
            self.vignetteContainer.alpha = 1
        }
        UIView.animate(
            withDuration: 0.48,
            delay: 0.21,
            options: [.curveEaseOut, .allowUserInteraction]
        ) { [weak self] in
            guard let self, self.cascadeToken == token else { return }
            self.chromeContainer.alpha = 1
        }
    }

    // MARK: - Apply / load

    private func applyItem() {
        loadToken &+= 1
        let token = loadToken

        // Clear chrome content while item changes. Cascade alpha is
        // managed separately by setIsCurrent — we just rebuild
        // contents here.
        titleLogoImageView.image = nil
        titleFallbackLabel.text = nil
        descriptionLabel.text = nil
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let item = item else {
            backdropImageView.image = nil
            return
        }

        // Title: show fallback text immediately; if a logo URL exists,
        // try to load it and swap to the image when it lands.
        titleFallbackLabel.text = item.title
        titleFallbackLabel.isHidden = false
        titleLogoImageView.isHidden = true

        // Populate initial genre + quality rows + action buttons
        // using just the MediaItem fields we already have. When
        // loadDetail() lands, we re-populate the genre/quality rows
        // and the cast label with the richer set.
        rebuildGenreRow(item: item, detail: nil)
        rebuildQualityRow(item: item, detail: nil)
        rebuildActionButtons(item: item)

        // Backdrop load.
        if let url = item.artwork.backdrop ?? item.artwork.poster {
            Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                await MainActor.run {
                    guard let self else { return }
                    guard self.loadToken == token else { return }
                    self.backdropImageView.image = image
                }
            }
        } else {
            backdropImageView.image = nil
        }

        // Logo load — only if present. Falls back to text otherwise.
        if let logoURL = item.artwork.logo {
            Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: logoURL)
                await MainActor.run {
                    guard let self else { return }
                    guard self.loadToken == token else { return }
                    guard let image else { return }  // keep fallback text if logo failed
                    self.titleLogoImageView.image = image
                    self.titleLogoImageView.isHidden = false
                    self.titleFallbackLabel.isHidden = true
                }
            }
        }

        // Detail fetch — populates genres / content rating / star
        // rating / quality badges / description. When it lands we
        // repopulate the chrome rows + description label.
        loadDetail(for: item, token: token)
    }

    /// Async fetch of MediaItemDetail through the agnostic provider
    /// registry. Mirrors PreviewOverlayHost's load pattern: try the
    /// MediaProvider first (Plex), fall back to MetadataSource (TMDB)
    /// for catalog-only items.
    private func loadDetail(for item: MediaItem, token: UInt64) {
        let ref = item.ref
        Task { [weak self] in
            let fetched: MediaItemDetail? = await {
                if let provider = await MainActor.run(body: {
                    MediaProviderRegistry.shared.provider(for: ref.providerID)
                }) {
                    return try? await provider.fullDetail(for: ref)
                }
                if let source = await MainActor.run(body: {
                    MetadataSourceRegistry.shared.source(for: ref.providerID)
                }) {
                    return try? await source.itemDetail(ref)
                }
                return nil
            }()

            guard let fetched else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.loadToken == token else { return }
                self.detail = fetched
                self.applyDetail(item: item, detail: fetched)
            }
        }
    }

    /// Re-render the chrome rows + description label + cast with the
    /// newly-loaded detail fields. Called only when the detail fetch
    /// completes successfully and the cell hasn't been reused.
    private func applyDetail(item: MediaItem, detail: MediaItemDetail) {
        rebuildGenreRow(item: item, detail: detail)
        rebuildQualityRow(item: item, detail: detail)
        // Description preference order: tagline → overview from detail.
        if let tagline = detail.tagline, !tagline.isEmpty {
            descriptionLabel.text = tagline
            descriptionLabel.font = UIFont.italicSystemFont(ofSize: 19)
        } else if let overview = detail.item.overview, !overview.isEmpty {
            descriptionLabel.text = overview
            descriptionLabel.font = .systemFont(ofSize: 19, weight: .regular)
        }
        // Starring text from top 3 cast members.
        let topCast = detail.cast.prefix(3).map { $0.name }
        if !topCast.isEmpty {
            castLabel.text = "Starring \(topCast.joined(separator: ", "))"
        } else {
            castLabel.text = nil
        }
    }

    /// Build the disabled-placeholder action row: Play pill on the
    /// left, Watched + Info circles after it. Real focus + tap
    /// wiring comes when we build expand-to-detail; for carousel
    /// mode the buttons are visible but interaction-disabled.
    private func rebuildActionButtons(item: MediaItem) {
        actionButtonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Play pill — text + inline progress bar (empty for now) +
        // time-remaining label. Uses item.runtime as the right-side
        // duration.
        let playPill = makePlayPill(item: item)
        actionButtonsStack.addArrangedSubview(playPill)

        // Watched circle
        actionButtonsStack.addArrangedSubview(makeCircleButton(systemImage: "checkmark"))
        // Watchlist add — plus icon.
        actionButtonsStack.addArrangedSubview(makeCircleButton(systemImage: "plus"))
        // Info / full description — text.page (SF Symbol).
        actionButtonsStack.addArrangedSubview(makeCircleButton(systemImage: "text.page"))
    }

    private func makePlayPill(item: MediaItem) -> UIView {
        // Pill container.
        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        pill.layer.cornerRadius = 27
        pill.layer.cornerCurve = .continuous

        let playIcon = UIImageView(image: UIImage(systemName: "play.fill"))
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playIcon.tintColor = .white
        playIcon.contentMode = .scaleAspectFit

        let timeLabel = UILabel()
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        timeLabel.textColor = .white
        if let runtime = item.runtime, runtime > 0 {
            timeLabel.text = Self.formatRuntime(runtime)
        } else {
            timeLabel.text = "Play"
        }

        // Inline progress bar — placeholder thin track. Real progress
        // value comes from item.userState.viewOffset when we wire up
        // playback state in a later iteration.
        let progressTrack = UIView()
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        progressTrack.layer.cornerRadius = 1.5

        pill.addSubview(playIcon)
        pill.addSubview(progressTrack)
        pill.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 54),
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

            playIcon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 24),
            playIcon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            playIcon.widthAnchor.constraint(equalToConstant: 22),
            playIcon.heightAnchor.constraint(equalToConstant: 22),

            timeLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -24),
            timeLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            progressTrack.leadingAnchor.constraint(equalTo: playIcon.trailingAnchor, constant: 16),
            progressTrack.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -16),
            progressTrack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 3)
        ])

        return pill
    }

    private func makeCircleButton(systemImage: String) -> UIView {
        let circle = UIView()
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        circle.layer.cornerRadius = 27

        let icon = UIImageView(image: UIImage(systemName: systemImage))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        circle.addSubview(icon)

        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 54),
            circle.heightAnchor.constraint(equalToConstant: 54),
            icon.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22)
        ])

        return circle
    }

    private func rebuildGenreRow(item: MediaItem, detail: MediaItemDetail?) {
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Build "Movie · Adventure · Sci-Fi"
        var parts: [String] = []
        parts.append(Self.kindLabel(item.kind))
        if let genres = detail?.genres {
            for genre in genres.prefix(2) {
                parts.append(genre)
            }
        }
        parts.removeAll(where: { $0.isEmpty })

        for (i, part) in parts.enumerated() {
            if i > 0 {
                genreRow.addArrangedSubview(Self.makeCaptionLabel("·", alpha: 0.5))
            }
            genreRow.addArrangedSubview(Self.makeCaptionLabel(part, alpha: 0.85))
        }

        // Content rating badge appended at the end when available.
        if let contentRating = detail?.contentRating, !contentRating.isEmpty {
            genreRow.addArrangedSubview(Self.makeContentRatingBadge(contentRating))
        }
    }

    private func rebuildQualityRow(item: MediaItem, detail: MediaItemDetail?) {
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // "2023 · 49 min   ⭐ 7.8   [4K] [DV]"
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let runtime = item.runtime, runtime > 0 { parts.append(Self.formatRuntime(runtime)) }

        for (i, part) in parts.enumerated() {
            if i > 0 {
                qualityRow.addArrangedSubview(Self.makeCaptionLabel("·", alpha: 0.7, bold: true))
            }
            qualityRow.addArrangedSubview(Self.makeCaptionLabel(part, alpha: 1, bold: true))
        }

        // Star rating — plain yellow star + number, NO border (the
        // bordered look is for quality badges only).
        if let rating = detail?.rating {
            let star = UIImageView(image: UIImage(systemName: "star.fill"))
            star.tintColor = .systemYellow
            star.contentMode = .scaleAspectFit
            star.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                star.widthAnchor.constraint(equalToConstant: 16),
                star.heightAnchor.constraint(equalToConstant: 16)
            ])
            let ratingLabel = Self.makeCaptionLabel(String(format: "%.1f", rating), alpha: 1, bold: true)
            let starStack = UIStackView(arrangedSubviews: [star, ratingLabel])
            starStack.axis = .horizontal
            starStack.spacing = 4
            starStack.alignment = .center
            qualityRow.addArrangedSubview(starStack)
        }

        // Quality badges (4K, DV, Atmos, 5.1, etc.)
        if let badges = detail?.mediaSources.first?.qualityBadges(), !badges.isEmpty {
            for badge in badges {
                qualityRow.addArrangedSubview(Self.makeQualityBadge(badge))
            }
        }
    }

    private static func formatRuntime(_ runtime: TimeInterval) -> String {
        let minutes = Int(runtime / 60)
        let hours = minutes / 60
        let remaining = minutes % 60
        if hours > 0 {
            return remaining > 0 ? "\(hours)h \(remaining)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    private static func kindLabel(_ kind: MediaKind) -> String {
        switch kind {
        case .movie: return "Movie"
        case .show, .season, .episode: return "TV Show"
        case .collection: return "Collection"
        case .person: return "Person"
        case .unknown: return ""
        }
    }

    private static func makeCaptionLabel(_ text: String, alpha: CGFloat, bold: Bool = false) -> UILabel {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = text
        l.font = bold ? .systemFont(ofSize: 19, weight: .bold) : .systemFont(ofSize: 19, weight: .regular)
        l.textColor = UIColor.white.withAlphaComponent(alpha)
        return l
    }

    private static func makeContentRatingBadge(_ text: String) -> UIView {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: 19, weight: .regular)
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        container.layer.cornerRadius = 4
        container.layer.cornerCurve = .continuous
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2)
        ])
        return container
    }

    private static func makeQualityBadge(_ text: String) -> UIView {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: 17, weight: .bold)
        label.textColor = .white
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        container.layer.cornerRadius = 4
        container.layer.cornerCurve = .continuous
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2)
        ])
        return container
    }
}
