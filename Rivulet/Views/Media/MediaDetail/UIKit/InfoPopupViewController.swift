//
//  InfoPopupViewController.swift
//  Rivulet
//
//  A single, reusable detail popup: a centered frosted card that sizes itself to
//  whatever content view it's given (fixed width, height hugs the content). Used
//  for the About description, the Common Sense advisory, and (future) episode
//  info — build the content with `InfoPopupContent`, hand it here.
//
//  tvOS focus: a presented modal with no focusable content never receives the
//  Menu press (the system dismisses one layer up). The card is focusable and we
//  own Menu + Select with press-type tap recognizers.
//

import UIKit

final class InfoPopupViewController: UIViewController {

    /// Focusable card so the modal owns the remote.
    private final class FocusableCard: UIView {
        override var canBecomeFocused: Bool { true }
    }

    private let content: UIView
    private let cardWidth: CGFloat
    private let scrollable: Bool
    private let card = FocusableCard()
    private let scroll = UIScrollView()
    /// Card height (scrollable mode): set in viewDidLayoutSubviews to the content's
    /// intrinsic height capped at ~85% screen, so tall content overflows + scrolls.
    private var cardHeight: NSLayoutConstraint!

    /// `content` supplies its own subviews; this VC frames + sizes the card to it.
    /// `scrollable`: cap the card height to ~85% of the screen and scroll tall
    /// content with Up/Down (for long structured popups like the full Info popup).
    init(content: UIView, width: CGFloat = 760, scrollable: Bool = false) {
        self.content = content
        self.cardWidth = width
        self.scrollable = scrollable
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        // Prominent Liquid Glass (tvOS 26), falling back to a regular blur.
        let effect: UIVisualEffect
        if #available(tvOS 26.0, *) { effect = UIGlassEffect() }
        else { effect = UIBlurEffect(style: .regular) }
        let blur = UIVisualEffectView(effect: effect)
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 38
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true

        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        card.addSubview(blur)

        content.translatesAutoresizingMaskIntoConstraints = false

        // Match the carousel detail's left margin so the popup padding feels native.
        let pad: CGFloat = PreviewCarouselGeometry.expandedChromeInset
        var constraints: [NSLayoutConstraint] = [
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: cardWidth),

            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ]
        if scrollable {
            // Cap the card at ~85% of the screen; content scrolls (driven by
            // Up/Down). The card hugs short content and caps tall content.
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.showsVerticalScrollIndicator = false
            scroll.isScrollEnabled = false   // driven manually in pressesBegan
            scroll.clipsToBounds = true
            // Breathing room so content scrolling in/out fades within the card,
            // not flush against its edges.
            scroll.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 72, right: 0)
            blur.contentView.addSubview(scroll)
            scroll.addSubview(content)
            // Card height is set in viewDidLayoutSubviews to the content's
            // INTRINSIC height (capped). Crucially we do NOT tie the card to the
            // content's height here — doing so squished the content down to the
            // capped card height, so it never overflowed and never scrolled.
            cardHeight = card.heightAnchor.constraint(equalToConstant: 320)
            constraints += [
                cardHeight,
                scroll.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: pad),
                scroll.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: pad),
                scroll.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -pad),
                scroll.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -pad),
                content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            ]
        } else {
            blur.contentView.addSubview(content)
            constraints += [
                content.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: pad),
                content.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: pad),
                content.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -pad),
                content.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -pad),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        for pressType in [UIPress.PressType.menu, .select] {
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissSelf))
            tap.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
            view.addGestureRecognizer(tap)
        }
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    // Up/Down scroll the tall content (scrollable popups only; Menu/Select still
    // dismiss via the gesture recognizers).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard scrollable else { super.pressesBegan(presses, with: event); return }
        for press in presses {
            switch press.type {
            case .upArrow: scrollContent(by: -440); return
            case .downArrow: scrollContent(by: 440); return
            default: break
            }
        }
        super.pressesBegan(presses, with: event)
    }
    private func scrollContent(by dy: CGFloat) {
        view.layoutIfNeeded()
        let inset = scroll.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
        let y = min(max(minY, scroll.contentOffset.y + dy), maxY)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            self.scroll.contentOffset = CGPoint(x: 0, y: y)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scrollable else { return }
        // 1. Multiline labels in a scroll view compute their intrinsic height
        // before the final width is known, clipping the last line. Pin each
        // multiline label's preferredMaxLayoutWidth to its laid-out width so the
        // height recomputes. Gated on a real change → converges (no loop).
        var changed = false
        func fix(_ v: UIView) {
            if let l = v as? UILabel, l.numberOfLines != 1, l.bounds.width > 1,
               abs(l.preferredMaxLayoutWidth - l.bounds.width) > 0.5 {
                l.preferredMaxLayoutWidth = l.bounds.width
                changed = true
            }
            v.subviews.forEach(fix)
        }
        fix(content)
        if changed { view.setNeedsLayout(); return }
        // 2. Card height: clamp the content height between a generous MINIMUM (so the
        // popup is never tiny — the content measurement is unreliable in a scroll
        // view) and an 85% cap (tall content overflows + scrolls).
        let contentH = scroll.contentSize.height
        guard contentH > 1 else { return }
        let pad = PreviewCarouselGeometry.expandedChromeInset
        let screen = view.bounds.height
        let desired = min(contentH + 2 * pad, screen * 0.85)
        // Bottom scroll-inset (breathing room) only when content overflows the card.
        let scrolls = (contentH + 2 * pad) > desired + 0.5
        scroll.contentInset.bottom = scrolls ? 72 : 0
        if abs(cardHeight.constant - desired) > 0.5 {
            cardHeight.constant = desired
            view.setNeedsLayout()
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [card] }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

// MARK: - Reusable content builders

enum InfoPopupContent {

    /// Title + genre line + full body (the About "description" popup).
    static func description(title: String, subtitle: String?, body: String?) -> UIView {
        let stack = verticalStack(spacing: 10)
        stack.addArrangedSubview(label(title, size: 30, weight: .semibold, color: .white, lines: 2))
        if let subtitle, !subtitle.isEmpty {
            let s = label(subtitle, size: 20, weight: .medium, color: .white.withAlphaComponent(0.6), lines: 1)
            stack.addArrangedSubview(s)
            stack.setCustomSpacing(20, after: s)
        }
        if let body, !body.isEmpty {
            stack.addArrangedSubview(label(body, size: 24, weight: .regular, color: .white.withAlphaComponent(0.9), lines: 0))
        }
        return stack
    }

    /// Common Sense advisory: green-check + age, one-liner, per-topic dot meters.
    static func advisory(_ advisory: ContentAdvisory) -> UIView {
        let stack = verticalStack(spacing: 18)

        let sealRow = UIStackView()
        sealRow.axis = .horizontal
        sealRow.alignment = .center
        sealRow.spacing = 8
        let seal = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        seal.tintColor = .systemGreen
        seal.contentMode = .scaleAspectFit
        seal.translatesAutoresizingMaskIntoConstraints = false
        seal.widthAnchor.constraint(equalToConstant: 30).isActive = true
        seal.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let ageText = advisory.ageRating.map { "age " + $0.replacingOccurrences(of: "+", with: "") } ?? "Common Sense"
        sealRow.addArrangedSubview(seal)
        sealRow.addArrangedSubview(label(ageText, size: 30, weight: .bold, color: .white, lines: 1))
        stack.addArrangedSubview(sealRow)

        if let one = advisory.oneLiner, !one.isEmpty {
            let o = label(one, size: 24, weight: .regular, color: .white.withAlphaComponent(0.9), lines: 0)
            stack.addArrangedSubview(o)
            stack.setCustomSpacing(24, after: o)
        }

        let topics = advisory.topics.sorted { a, b in
            if a.isPositive != b.isPositive { return !a.isPositive }
            return (a.rating ?? 0) > (b.rating ?? 0)
        }
        for topic in topics { stack.addArrangedSubview(topicRow(topic)) }
        return stack
    }

    /// The full structured Info popup (movies/shows): title / genre / synopsis,
    /// a meta + capability-badge row, then Information / Languages / Accessibility
    /// sections stacked vertically. Present with `scrollable: true`.
    static func fullInfo(detail: MediaItemDetail) -> UIView {
        let stack = verticalStack(spacing: 16)
        // Title matches the section headers (InfoColumnView header = 40pt bold).
        stack.addArrangedSubview(label(detail.item.title, size: 40, weight: .bold, color: .white, lines: 2))
        if let genre = detail.genres.first, !genre.isEmpty {
            stack.addArrangedSubview(label(genre, size: 21, weight: .semibold, color: .white.withAlphaComponent(0.6), lines: 1))
        }
        if let overview = detail.item.overview, !overview.isEmpty {
            let syn = label(overview, size: 24, weight: .regular, color: .white.withAlphaComponent(0.9), lines: 0)
            stack.addArrangedSubview(syn)
            stack.setCustomSpacing(22, after: syn)
        }
        stack.addArrangedSubview(metaRow(detail))

        let source = detail.mediaSources.first

        // Information
        var info: [(String, String)] = []
        if let y = detail.item.year { info.append(("Released", "\(y)")) }
        if let rt = detail.item.runtime, rt > 0 { info.append(("Run Time", runtimeString(rt))) }
        if let r = detail.contentRating, !r.isEmpty { info.append(("Rated", r)) }
        if let region = detail.regionOfOrigin, !region.isEmpty { info.append(("Region of Origin", region)) }
        addSection(title: "Information", rows: info, to: stack)

        // Languages
        var langs: [(String, String)] = []
        if let first = source?.audioTracks.first, let n = InfoColumnsView.languageName(first.language) {
            langs.append(("Original Audio", n))
        }
        if let audio = source?.audioTracks, !audio.isEmpty {
            let summary = audioSummary(audio)
            if !summary.isEmpty { langs.append(("Audio", summary)) }
        }
        if let subs = source?.subtitleTracks, !subs.isEmpty {
            let names = uniqueOrdered(subs.compactMap { t -> String? in
                guard let n = InfoColumnsView.languageName(t.language) else { return nil }
                return t.isHearingImpaired ? "\(n) (SDH)" : n
            })
            if !names.isEmpty { langs.append(("Subtitles", names.joined(separator: ", "))) }
        }
        addSection(title: "Languages", rows: langs, to: stack)

        // Accessibility
        var access: [(String, String)] = []
        if source?.subtitleTracks.contains(where: { $0.isHearingImpaired }) ?? false {
            access.append(("SDH", "Subtitles for the deaf and hard of hearing (SDH) refer to subtitles in the original language with the addition of relevant non-dialogue information."))
        }
        if source?.audioTracks.contains(where: { ($0.title ?? $0.extendedTitle ?? "").localizedCaseInsensitiveContains("descri") }) ?? false {
            access.append(("AD", "Audio descriptions (AD) refer to a narration track describing what is happening on screen, to provide context for those who are blind or have low vision."))
        }
        if !access.isEmpty { addSection(title: "Accessibility", rows: access, to: stack) }
        return stack
    }

    private static func addSection(title: String, rows: [(String, String)], to stack: UIStackView) {
        guard !rows.isEmpty else { return }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(30, after: last) }
        let col = InfoColumnView()
        col.configure(title: title, rows: rows)
        stack.addArrangedSubview(col)
    }

    private static func metaRow(_ detail: MediaItemDetail) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        var parts: [String] = []
        if let y = detail.item.year { parts.append("\(y)") }
        if let rt = detail.item.runtime, rt > 0 { parts.append(runtimeString(rt)) }
        if let r = detail.contentRating, !r.isEmpty { parts.append(r) }
        if !parts.isEmpty {
            row.addArrangedSubview(label(parts.joined(separator: "  ·  "), size: 20, weight: .semibold, color: .white.withAlphaComponent(0.7), lines: 1))
        }
        let source = detail.mediaSources.first
        var badges = source?.qualityBadges() ?? []
        if source?.subtitleTracks.contains(where: { $0.isHearingImpaired }) ?? false { badges.append("SDH") }
        if source?.audioTracks.contains(where: { ($0.title ?? $0.extendedTitle ?? "").localizedCaseInsensitiveContains("descri") }) ?? false { badges.append("AD") }
        for raw in badges {
            let text = raw.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { row.addArrangedSubview(badgeLabel(text)) }
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    private static func badgeLabel(_ text: String) -> UIView {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 16, weight: .semibold)
        l.textColor = .white.withAlphaComponent(0.9)
        l.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        container.layer.cornerRadius = 4
        container.addSubview(l)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            l.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
            l.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            l.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
        ])
        return container
    }

    /// "English (Dolby Atmos, Dolby 5.1, AAC, AD), French (Canada) (…)" — group
    /// audio tracks by language and list each language's distinct formats.
    private static func audioSummary(_ tracks: [AudioTrack]) -> String {
        var byLang: [String: [String]] = [:]
        var order: [String] = []
        for t in tracks {
            guard let name = InfoColumnsView.languageName(t.language) else { continue }
            if byLang[name] == nil { byLang[name] = []; order.append(name) }
            let fmt = audioFormat(t)
            if !fmt.isEmpty, !(byLang[name]?.contains(fmt) ?? false) { byLang[name]?.append(fmt) }
            if (t.title ?? t.extendedTitle ?? "").localizedCaseInsensitiveContains("descri"),
               !(byLang[name]?.contains("AD") ?? false) { byLang[name]?.append("AD") }
        }
        return order.map { name in
            let fmts = byLang[name] ?? []
            return fmts.isEmpty ? name : "\(name) (\(fmts.joined(separator: ", ")))"
        }.joined(separator: ", ")
    }

    private static func audioFormat(_ t: AudioTrack) -> String {
        let codec = t.codec.lowercased()
        let title = (t.extendedTitle ?? t.title ?? "").lowercased()
        if title.contains("atmos") || (t.channelLayout ?? "").lowercased().contains("atmos") {
            return "Dolby Atmos"
        }
        let layout = t.channelLayout ?? t.channels.map { $0 >= 6 ? "\($0 - 1).1" : ($0 >= 2 ? "Stereo" : "Mono") } ?? ""
        let isDolby = (codec == "eac3" || codec == "ac3" || codec == "truehd")
        if isDolby, !layout.isEmpty, layout != "Stereo", layout != "Mono" { return "Dolby \(layout)" }
        switch codec {
        case "aac": return "AAC"
        case "dts", "dca": return "DTS"
        case "truehd": return "Dolby TrueHD"
        case "flac": return "FLAC"
        case "ac3", "eac3": return layout.isEmpty ? "Dolby Digital" : "Dolby \(layout)"
        default: return layout.isEmpty ? codec.uppercased() : layout
        }
    }

    private static func runtimeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded()); let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) hr \(m) min" : "\(h) hr" }
        return "\(m) min"
    }

    private static func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for v in values where !seen.contains(v) { seen.insert(v); out.append(v) }
        return out
    }

    // MARK: helpers

    private static func verticalStack(spacing: CGFloat) -> UIStackView {
        let s = UIStackView()
        s.axis = .vertical
        s.alignment = .fill
        s.spacing = spacing
        return s
    }

    private static func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor, lines: Int) -> UILabel {
        let l = UILabel()
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.numberOfLines = lines
        l.text = text
        return l
    }

    private static func topicRow(_ topic: ContentAdvisory.Topic) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 16

        let name = label(topic.label, size: 22, weight: .regular, color: .white.withAlphaComponent(0.92), lines: 1)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let dots = UIStackView()
        dots.axis = .horizontal
        dots.spacing = 8
        dots.alignment = .center
        dots.setContentHuggingPriority(.required, for: .horizontal)
        let filled = max(0, min(5, topic.rating ?? 0))
        for i in 0..<5 {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
            dot.layer.cornerRadius = 6
            dot.backgroundColor = i < filled ? UIColor.white.withAlphaComponent(0.95) : UIColor.white.withAlphaComponent(0.22)
            dots.addArrangedSubview(dot)
        }
        row.addArrangedSubview(name)
        row.addArrangedSubview(dots)
        return row
    }
}
