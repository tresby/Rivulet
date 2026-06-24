//
//  SettingsLeftPanelView.swift
//  Rivulet
//
//  Left description panel for the UIKit Settings split, matching the SwiftUI
//  `SettingsLeftPanel`: a per-PAGE icon (320×320, cornerRadius 60 continuous,
//  color@0.18, 120pt symbol) that is fixed for the page, plus a per-ROW
//  description (28pt, white@0.55) that crossfades (0.25) as focus moves
//  between rows. Reuses `SettingsDescriptorStore` (pageInfo + descriptor).
//

import UIKit
import SwiftUI

final class SettingsLeftPanelView: UIView {

    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let descriptionLabel = UILabel()
    private let subtextLabel = UILabel()
    /// Page-level instruction shown under the icon (e.g. the reorder hint on the
    /// libraries page). Collapses to zero height when the page has no hint.
    private let hintLabel = UILabel()
    private var hintHeightZero: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        iconContainer.layer.cornerRadius = 60
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconContainer)

        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 120, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        descriptionLabel.font = .systemFont(ofSize: 28, weight: .regular)
        descriptionLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        descriptionLabel.numberOfLines = 4
        descriptionLabel.textAlignment = .center
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(descriptionLabel)

        hintLabel.numberOfLines = 2
        hintLabel.textAlignment = .center
        hintLabel.isHidden = true
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)

        subtextLabel.font = .monospacedSystemFont(ofSize: 24, weight: .medium)
        subtextLabel.textColor = UIColor.white.withAlphaComponent(0.35)
        subtextLabel.numberOfLines = 2
        subtextLabel.textAlignment = .center
        subtextLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtextLabel)

        // Hint collapses to zero height (active by default) so pages with no
        // hint keep the original 28pt icon→description gap (16 + 0 + 12).
        hintHeightZero = hintLabel.heightAnchor.constraint(equalToConstant: 0)
        hintHeightZero.isActive = true

        NSLayoutConstraint.activate([
            // Icon vertically centered in the panel, like the SwiftUI Spacer/Spacer.
            iconContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -80),
            iconContainer.widthAnchor.constraint(equalToConstant: 320),
            iconContainer.heightAnchor.constraint(equalToConstant: 320),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

            hintLabel.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 16),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            descriptionLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 12),
            descriptionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
            descriptionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            subtextLabel.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 12),
            subtextLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtextLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 700)
        ])
    }

    /// Pages that show a page-level instruction under the icon.
    private func hint(for page: SettingsPage) -> String? {
        switch page {
        case .libraries: return "Long press to re-arrange items"
        default:         return nil
        }
    }

    /// Reorder-style hint: an up/down glyph + text, dim like the description.
    private func hintAttributed(_ text: String) -> NSAttributedString {
        let color = UIColor.white.withAlphaComponent(0.5)
        let result = NSMutableAttributedString()
        let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        if let img = UIImage(systemName: "arrow.up.arrow.down", withConfiguration: cfg)?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment()
            attachment.image = img
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  "))
        }
        result.append(NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 24, weight: .medium),
            .foregroundColor: color
        ]))
        return result
    }

    /// Set the page icon (matching `pageInfo(for:)`). Crossfades when animated
    /// (on a page change), like the SwiftUI panel's symbol-replace transition.
    func configure(page: SettingsPage, animated: Bool = false) {
        let info = SettingsDescriptorStore.pageInfo(for: page)
        let color = UIColor(info.color)
        let apply = {
            self.iconContainer.backgroundColor = color.withAlphaComponent(0.18)
            self.iconView.image = UIImage(systemName: info.icon)
            self.iconView.tintColor = color
        }
        if animated {
            UIView.transition(with: iconContainer, duration: 0.3, options: .transitionCrossDissolve, animations: apply)
        } else {
            apply()
        }

        // Page-level instruction under the icon (collapses when none).
        if let text = hint(for: page) {
            hintLabel.attributedText = hintAttributed(text)
            hintLabel.isHidden = false
            hintHeightZero.isActive = false
        } else {
            hintLabel.attributedText = nil
            hintLabel.isHidden = true
            hintHeightZero.isActive = true
        }
    }

    /// Update the per-row description (crossfade), keyed by `focusedSettingId`.
    func show(id: String?, subtext: String? = nil) {
        let descriptor = id.flatMap { SettingsDescriptorStore.descriptor(for: $0) }
        UIView.transition(with: self, duration: 0.25, options: .transitionCrossDissolve) {
            self.descriptionLabel.text = descriptor?.description ?? " "
            self.descriptionLabel.alpha = descriptor != nil ? 1 : 0
            self.subtextLabel.text = subtext
            self.subtextLabel.isHidden = (subtext == nil)
        }
    }
}
