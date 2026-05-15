//
//  HubHeaderView.swift
//  Rivulet
//
//  Section header above each hub row in the UIKit home. Plain UILabel
//  styled to match the SwiftUI version's hub titles.
//

import UIKit

@MainActor
final class HubHeaderView: UICollectionReusableView {
    static let reuseID = "HubHeaderView"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 30, weight: .bold)
        label.textColor = .white
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -48),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func configure(title: String) {
        label.text = title
    }
}
