//
//  MediaDetailChromeView.swift
//  Rivulet
//
//  The shared chrome surface — logo / genre row / description / quality
//  row / action+cast row — used by both the carousel cell
//  (`PreviewCardView`) and the fullscreen detail (`MediaDetailViewController`).
//
//  Layout structure (mirrors SwiftUI `MediaDetailView.heroMetadataOverlay`):
//
//      ┌─────────────────────────────────────────┐  ← self
//      │ ┌──────────────────┐                    │
//      │ │ metadataBlock    │  (760pt max)       │
//      │ │   logoSlot       │                    │
//      │ │   genreRow       │                    │
//      │ │   descLabel      │                    │
//      │ │   qualityRow     │                    │
//      │ └──────────────────┘                    │
//      │  ↕ 32pt                                 │
//      │ ┌───────────────────────────────────────┤
//      │ │ actionAndCastRow (full width)         │
//      │ │   [Play][Watched][+][i]    Starring … │
//      │ └───────────────────────────────────────┤
//      └─────────────────────────────────────────┘
//
//  The carousel cell anchors this view bottom-leading inside the card,
//  with the card's horizontal insets (118pt) applied to self's leading
//  and trailing anchors. The expanded detail VC anchors it bottom-leading
//  to the screen with the expanded insets (140pt). The chrome view itself
//  is layout-agnostic — it just lays out its own internal stack from the
//  width its host gives it.
//
//  Animation:
//   - The host owns the cascade timer. This view exposes `chromeAlpha`
//     which forwards directly to `self.alpha`.
//   - The vignette is OUTSIDE this view (owned by the host: carousel
//     cell or expanded-detail VC) because the vignette is part of the
//     surrounding hero, not the chrome content.
//
//  Mode:
//   - `.carouselStable` — action row is interaction-disabled (carousel
//     paging owns input). This is the only mode wired up in Iter A.
//   - `.expandedDetail` — action row becomes focus-enabled and tap-wired
//     (Iter B+). Mode is a property so the host can flip it; this view
//     reads it during `applyItem`.
//

import UIKit
import os.log

private let chromeLog = Logger(
    subsystem: "com.rivulet.app",
    category: "MediaDetailChromeView"
)

final class MediaDetailChromeView: UIView {

    // MARK: - Public surface

    /// Layout mode — narrows insets, swaps action-row interactivity.
    /// In Iter A only `.carouselStable` is exercised; the structure is in
    /// place for Iter B to flip to `.expandedDetail`.
    enum Mode {
        case carouselStable
        case expandedDetail
    }

    var mode: Mode = .carouselStable {
        didSet {
            guard mode != oldValue else { return }
            applyMode()
        }
    }

    /// Current item this chrome is showing. Setting kicks off the
    /// metadata rebuild + async detail fetch.
    var item: MediaItem? {
        didSet {
            guard item != oldValue else { return }
            applyItem()
        }
    }

    /// Cascade alpha — forwarded directly to `self.alpha`. The host owns
    /// the timing; this view just exposes a typed knob.
    var chromeAlpha: CGFloat {
        get { alpha }
        set { alpha = newValue }
    }

    /// Action callbacks. In `.carouselStable` mode these are not invoked
    /// (action row is interaction-disabled). Wired in `.expandedDetail`
    /// during Iter B/D.
    var onPlay: (() -> Void)?
    var onToggleWatched: (() -> Void)?
    var onToggleWatchlist: (() -> Void)?
    var onShowFullDescription: (() -> Void)?

    // MARK: - State

    /// Monotonic load token. Bumped on every `applyItem()`; async detail
    /// fetch checks against this on completion and discards stale results.
    /// Prevents wrong metadata from snapping in when item changes quickly.
    private var loadToken: UInt64 = 0

    /// Cached detail, populated by `loadDetail()` when it lands. Used to
    /// repopulate genre + quality rows + cast label with richer fields.
    private var detail: MediaItemDetail?

    /// Per-item aspect-ratio constraint on the logo image view. Plex
    /// logo assets are typically wide PNGs with the visible glyphs at
    /// natural aspect (no transparent padding) — but `.scaleAspectFit`
    /// in a UIImageView CENTERS the content inside the view bounds,
    /// which would offset the visible glyphs right of the metadata's
    /// leading edge. Installing a width = height * imageAspect
    /// constraint when the image lands sizes the view exactly to the
    /// visible pixels, so leading-aligned constraint to the metadata
    /// edge lines up the glyphs flush left.
    private var logoAspectConstraint: NSLayoutConstraint?

    // MARK: - Subviews

    /// Outer vertical stack — bottom-leading aligned by the host. Contains
    /// the metadata block + the action+cast row.
    private let chromeStack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        s.alignment = .fill
        s.spacing = 14
        return s
    }()

    /// Inner metadata block — vertical stack, max 760pt wide.
    /// Natural-content height: takes as much vertical space as the logo
    /// slot (138pt) + genre row + description + quality row + spacing.
    /// The outer `chromeStack` settles this block above the action row;
    /// the chrome view itself is anchored from below by the card.
    /// Matches the carousel-stable layout at commit `bc127a9` (the
    /// agreed visual baseline at the start of Iter A).
    private let metadataBlock: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        s.alignment = .leading
        s.spacing = 14
        return s
    }()

    /// Logo slot — fixed 138pt tall, 620pt max wide, bottom-leading
    /// aligned. Either the logo image or the fallback label occupies it
    /// depending on whether `artwork.logo` loaded.
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

    /// "Movie · Adventure · Sci-Fi  [TV-14]"
    private let genreRow: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.spacing = 8
        s.alignment = .center
        return s
    }()

    /// Italic tagline OR plain overview, up to 3 lines / 560pt wide.
    private let descriptionLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 19, weight: .regular)
        l.textColor = UIColor.white.withAlphaComponent(0.85)
        l.numberOfLines = 3
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    /// "2023 · 49 min   ⭐ 7.8   [4K] [DV] [5.1]" — caption.bold(), white.
    private let qualityRow: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.spacing = 8
        s.alignment = .center
        return s
    }()

    /// Bottom action+cast row. NOT a stack view — using a UIStackView
    /// here was causing the action buttons to flash stretched-wide on
    /// the first layout pass before constraints settled. A plain
    /// UIView with explicit leading/trailing constraints on the two
    /// children gives byte-stable widths from frame zero: action
    /// buttons hug their content on the left, cast label hugs its
    /// content on the right, the gap between is the leftover.
    private let actionAndCastRow: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        return v
    }()

    /// Left cluster — Play pill + Watched / Watchlist / Info circles.
    private let actionButtonsStack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.alignment = .center
        s.spacing = 18
        return s
    }()

    /// "Starring …" text, right-aligned, capped at 460pt.
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
        fatalError("MediaDetailChromeView is not Storyboard-backed")
    }

    private func commonInit() {
        backgroundColor = .clear
        isUserInteractionEnabled = false  // host flips this on for .expandedDetail

        logoSlotView.addSubview(titleLogoImageView)
        logoSlotView.addSubview(titleFallbackLabel)

        addSubview(chromeStack)

        metadataBlock.addArrangedSubview(logoSlotView)
        metadataBlock.addArrangedSubview(genreRow)
        metadataBlock.addArrangedSubview(descriptionLabel)
        metadataBlock.addArrangedSubview(qualityRow)
        chromeStack.addArrangedSubview(metadataBlock)

        // 32pt extra gap between metadata block and action+cast row —
        // matches SwiftUI `heroActionRowTopPadding` (carousel mode).
        chromeStack.setCustomSpacing(32, after: metadataBlock)
        chromeStack.addArrangedSubview(actionAndCastRow)

        // actionAndCastRow is a plain UIView (not a stack). Children
        // are pinned explicitly: actionButtonsStack to leading +
        // centerY, castLabel to trailing + centerY, with a min-gap
        // between. The two compete only over the gap, so neither
        // can stretch beyond its content width.
        actionAndCastRow.addSubview(actionButtonsStack)
        actionAndCastRow.addSubview(castLabel)

        // The inner actionButtonsStack uses default `distribution = .fill`
        // which, given the play pill's `widthAnchor >= 220` (an
        // inequality), will stretch the pill to fill any extra width
        // the stack has. We don't want that — the stack should hug
        // its children at their intrinsic widths. Setting hugging to
        // .required tells the layout engine: "do not grow this stack
        // wider than the sum of its children." Combined with the
        // stack's `leadingAnchor` pin (no trailing pin) on the parent
        // UIView, the stack width settles at exactly content-width.
        actionButtonsStack.setContentHuggingPriority(.required, for: .horizontal)
        actionButtonsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        castLabel.setContentHuggingPriority(.required, for: .horizontal)

        let descMaxWidth = descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        descMaxWidth.priority = .required

        NSLayoutConstraint.activate([
            // Chrome stack fills self.
            chromeStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeStack.topAnchor.constraint(equalTo: topAnchor),
            chromeStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Logo slot: 138pt tall, 620pt max wide.
            logoSlotView.heightAnchor.constraint(equalToConstant: 138),
            logoSlotView.widthAnchor.constraint(lessThanOrEqualToConstant: 620),

            // Logo image: aspectFit, bottom-leading inside the slot.
            // No fixed height — a 500×120 logo renders at 500×120.
            titleLogoImageView.leadingAnchor.constraint(equalTo: logoSlotView.leadingAnchor),
            titleLogoImageView.trailingAnchor.constraint(lessThanOrEqualTo: logoSlotView.trailingAnchor),
            titleLogoImageView.bottomAnchor.constraint(equalTo: logoSlotView.bottomAnchor),
            titleLogoImageView.topAnchor.constraint(greaterThanOrEqualTo: logoSlotView.topAnchor),
            // Cap height at slot height; prefer to fill it. The
            // priority-999 equality lets the inequality + aspect
            // constraints drive height down when an extra-wide asset
            // would push width past the 620pt slot.
            titleLogoImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 138),
            {
                let c = titleLogoImageView.heightAnchor.constraint(equalToConstant: 138)
                c.priority = .init(999)
                return c
            }(),

            // Fallback label: bottom-leading inside the slot.
            titleFallbackLabel.leadingAnchor.constraint(equalTo: logoSlotView.leadingAnchor),
            titleFallbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: logoSlotView.trailingAnchor),
            titleFallbackLabel.bottomAnchor.constraint(equalTo: logoSlotView.bottomAnchor),

            descMaxWidth,

            // Metadata block capped at 760pt wide. Block height is
            // natural (content-driven); chromeStack pins it above the
            // action row from below.
            metadataBlock.widthAnchor.constraint(lessThanOrEqualToConstant: 760),

            // Action buttons pin to leading + centerY of the row.
            actionButtonsStack.leadingAnchor.constraint(equalTo: actionAndCastRow.leadingAnchor),
            actionButtonsStack.centerYAnchor.constraint(equalTo: actionAndCastRow.centerYAnchor),
            actionButtonsStack.topAnchor.constraint(greaterThanOrEqualTo: actionAndCastRow.topAnchor),
            actionButtonsStack.bottomAnchor.constraint(lessThanOrEqualTo: actionAndCastRow.bottomAnchor),

            // Row height derives from the action buttons stack
            // (54pt circle/pill height).
            actionAndCastRow.heightAnchor.constraint(greaterThanOrEqualTo: actionButtonsStack.heightAnchor),

            // Cast label pins to trailing + centerY, capped at 460pt.
            castLabel.trailingAnchor.constraint(equalTo: actionAndCastRow.trailingAnchor),
            castLabel.centerYAnchor.constraint(equalTo: actionAndCastRow.centerYAnchor),
            castLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),

            // Min 40pt gap between buttons and cast label. The cast
            // can compress its width down to 0 (lessThanOrEqual width
            // cap) when needed, but the action buttons keep their
            // intrinsic widths.
            castLabel.leadingAnchor.constraint(greaterThanOrEqualTo: actionButtonsStack.trailingAnchor, constant: 40)
        ])

        applyMode()
    }

    // MARK: - Mode

    private func applyMode() {
        switch mode {
        case .carouselStable:
            actionAndCastRow.isUserInteractionEnabled = false
            isUserInteractionEnabled = false
        case .expandedDetail:
            actionAndCastRow.isUserInteractionEnabled = true
            isUserInteractionEnabled = true
        }
    }

    // MARK: - Reset (host calls during cell reuse)

    /// Clears all displayed content and bumps the load token so any
    /// in-flight async work is discarded. Called by `PreviewCardView`'s
    /// `prepareForReuse`.
    func reset() {
        loadToken &+= 1
        item = nil
        detail = nil
        if let prev = logoAspectConstraint {
            prev.isActive = false
            logoAspectConstraint = nil
        }
        titleLogoImageView.image = nil
        titleFallbackLabel.text = nil
        titleLogoImageView.isHidden = false
        titleFallbackLabel.isHidden = false
        descriptionLabel.text = nil
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionButtonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        castLabel.text = nil
    }

    /// Install a width = height × imageAspect constraint on
    /// `titleLogoImageView` so the view bounds tightly wrap the
    /// visible image pixels. Without this, `.scaleAspectFit` would
    /// center the scaled image inside an artificially-wide view and
    /// the glyphs would float right of the metadata's leading edge.
    private func installLogoAspectConstraint(for image: UIImage) {
        guard image.size.height > 0 else { return }
        let aspect = image.size.width / image.size.height
        let c = titleLogoImageView.widthAnchor.constraint(
            equalTo: titleLogoImageView.heightAnchor,
            multiplier: aspect
        )
        c.priority = .required
        c.isActive = true
        logoAspectConstraint = c
    }

    // MARK: - Apply / load

    private func applyItem() {
        loadToken &+= 1
        let token = loadToken

        titleLogoImageView.image = nil
        titleFallbackLabel.text = nil
        descriptionLabel.text = nil
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let item = item else { return }

        rebuildGenreRow(item: item, detail: nil)
        rebuildQualityRow(item: item, detail: nil)
        rebuildActionButtons(item: item)

        // Clear any aspect constraint from the previous item — a stale
        // ratio would size the new image wrong while it's loading.
        if let prev = logoAspectConstraint {
            prev.isActive = false
            logoAspectConstraint = nil
        }

        // Logo: probe the memory cache synchronously first. If the
        // logo is already cached (which it nearly always is when the
        // chrome is being shown in the expanded detail — the carousel
        // cell underneath has already loaded it), render the image on
        // frame 0 with no fallback-text flash. Otherwise show the
        // fallback label and start the async load.
        let cachedLogo = item.artwork.logo.flatMap { ImageCacheManager.shared.cachedImage(for: $0) }
        if let cachedLogo {
            titleLogoImageView.image = cachedLogo
            titleLogoImageView.isHidden = false
            titleFallbackLabel.isHidden = true
            titleFallbackLabel.text = nil
            installLogoAspectConstraint(for: cachedLogo)
        } else {
            titleFallbackLabel.text = item.title
            titleFallbackLabel.isHidden = false
            titleLogoImageView.isHidden = true
            titleLogoImageView.image = nil
            if let logoURL = item.artwork.logo {
                Task { [weak self] in
                    let image = await ImageCacheManager.shared.image(for: logoURL)
                    await MainActor.run {
                        guard let self else { return }
                        guard self.loadToken == token else { return }
                        guard let image else { return }
                        self.titleLogoImageView.image = image
                        self.titleLogoImageView.isHidden = false
                        self.titleFallbackLabel.isHidden = true
                        self.installLogoAspectConstraint(for: image)
                    }
                }
            }
        }

        // Detail fetch — populates richer genre / rating / quality / cast.
        loadDetail(for: item, token: token)
    }

    /// Async fetch of `MediaItemDetail` through the agnostic provider
    /// registry. Tries `MediaProvider` first (Plex), falls back to
    /// `MetadataSource` (TMDB) for catalog-only items.
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

    /// Re-render the chrome rows + description + cast with newly-loaded
    /// detail fields. Called only when the fetch lands and the load
    /// token still matches.
    private func applyDetail(item: MediaItem, detail: MediaItemDetail) {
        rebuildGenreRow(item: item, detail: detail)
        rebuildQualityRow(item: item, detail: detail)
        if let tagline = detail.tagline, !tagline.isEmpty {
            descriptionLabel.text = tagline
            descriptionLabel.font = UIFont.italicSystemFont(ofSize: 19)
        } else if let overview = detail.item.overview, !overview.isEmpty {
            descriptionLabel.text = overview
            descriptionLabel.font = .systemFont(ofSize: 19, weight: .regular)
        }
        let topCast = detail.cast.prefix(3).map { $0.name }
        if !topCast.isEmpty {
            castLabel.text = "Starring \(topCast.joined(separator: ", "))"
        } else {
            castLabel.text = nil
        }
    }

    // MARK: - Row builders

    private func rebuildActionButtons(item: MediaItem) {
        actionButtonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Carousel-stable button set (agreed in perf-spike commits up to
        // bc127a9): Play pill + Watched + Watchlist + Info. The SwiftUI
        // source has a wider set (Trailer, Audio, Subs) that's gated by
        // detail content — we don't surface those in the carousel.
        actionButtonsStack.addArrangedSubview(makePlayPill(item: item))
        actionButtonsStack.addArrangedSubview(makeCircleButton(systemImage: "checkmark"))
        actionButtonsStack.addArrangedSubview(makeCircleButton(systemImage: "plus"))
        actionButtonsStack.addArrangedSubview(makeCircleButton(systemImage: "text.page"))
    }

    private func rebuildGenreRow(item: MediaItem, detail: MediaItemDetail?) {
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

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

        if let contentRating = detail?.contentRating, !contentRating.isEmpty {
            genreRow.addArrangedSubview(Self.makeContentRatingBadge(contentRating))
        }
    }

    private func rebuildQualityRow(item: MediaItem, detail: MediaItemDetail?) {
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let runtime = item.runtime, runtime > 0 { parts.append(Self.formatRuntime(runtime)) }

        for (i, part) in parts.enumerated() {
            if i > 0 {
                qualityRow.addArrangedSubview(Self.makeCaptionLabel("·", alpha: 0.7, bold: true))
            }
            qualityRow.addArrangedSubview(Self.makeCaptionLabel(part, alpha: 1, bold: true))
        }

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

        if let badges = detail?.mediaSources.first?.qualityBadges(), !badges.isEmpty {
            for badge in badges {
                qualityRow.addArrangedSubview(Self.makeQualityBadge(badge))
            }
        }
    }

    // MARK: - Factories

    private func makePlayPill(item: MediaItem) -> UIView {
        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        pill.layer.cornerRadius = 27
        pill.layer.cornerCurve = .continuous
        // Hug content — refuse to stretch when the parent stack has
        // extra width. Combined with the deterministic internal
        // layout (fixed leading inset / icon width / progress width /
        // trailing inset), the pill resolves to ~220pt wide regardless
        // of container size.
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

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

        let progressTrack = UIView()
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        progressTrack.layer.cornerRadius = 1.5

        pill.addSubview(playIcon)
        pill.addSubview(progressTrack)
        pill.addSubview(timeLabel)

        // Pin progressTrack to a fixed 90pt width. Pill width is
        // deterministic: 18 leading + 18 icon + 12 gap + 90 progress
        // + 12 gap + label intrinsic + 18 trailing ≈ 220pt total.
        // Without a fixed progress width the pill becomes stretchy
        // and absorbs any extra width its container offers.
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 54),

            playIcon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 18),
            playIcon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            playIcon.widthAnchor.constraint(equalToConstant: 18),
            playIcon.heightAnchor.constraint(equalToConstant: 18),

            progressTrack.leadingAnchor.constraint(equalTo: playIcon.trailingAnchor, constant: 12),
            progressTrack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 3),
            progressTrack.widthAnchor.constraint(equalToConstant: 90),

            timeLabel.leadingAnchor.constraint(equalTo: progressTrack.trailingAnchor, constant: 12),
            timeLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -18),
            timeLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
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

        // Pill height stays 54 to match the play pill row; circles
        // are 54×54 with an 18pt icon. setContentHugging .required
        // keeps the stack from stretching them sideways when extra
        // width is available.
        circle.setContentHuggingPriority(.required, for: .horizontal)
        circle.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 54),
            circle.heightAnchor.constraint(equalToConstant: 54),
            icon.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18)
        ])

        return circle
    }

    // MARK: - Statics

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
