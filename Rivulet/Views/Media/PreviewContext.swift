//
//  PreviewContext.swift
//  Rivulet
//
//  Shared state and preferences for the Apple TV-style row preview flow.
//

import SwiftUI

struct PreviewRequest: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let selectedIndex: Int
    let sourceRowID: String
    let sourceItemID: String

    var sourceTarget: PreviewSourceTarget {
        PreviewSourceTarget(rowID: sourceRowID, itemID: sourceItemID)
    }
}

enum PreviewPhase: Equatable {
    case entryMorph
    case carouselStable
    case expandingHero
    case expandedHero
    case detailsStable
    case exiting
}

enum PreviewFocusArea: Hashable {
    case carousel
    case heroPrimary
    case detailHeader
    case detailBody
}

struct PreviewSourceTarget: Hashable {
    let rowID: String
    let itemID: String
}

struct PreviewSourceFramePreferenceKey: PreferenceKey {
    static var defaultValue: [PreviewSourceTarget: Anchor<CGRect>] = [:]

    static func reduce(value: inout [PreviewSourceTarget: Anchor<CGRect>], nextValue: () -> [PreviewSourceTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PreviewSourceAnchorModifier: ViewModifier {
    let rowID: String
    let itemID: String

    func body(content: Content) -> some View {
        content.anchorPreference(key: PreviewSourceFramePreferenceKey.self, value: .bounds) { anchor in
            [PreviewSourceTarget(rowID: rowID, itemID: itemID): anchor]
        }
    }
}

extension View {
    func previewSourceAnchor(rowID: String, itemID: String) -> some View {
        modifier(PreviewSourceAnchorModifier(rowID: rowID, itemID: itemID))
    }
}

enum PreviewBackAction: Equatable {
    case collapseToCarousel
    case dismissOverlay
}

struct PreviewStateMachine {
    private(set) var phase: PreviewPhase = .entryMorph
    private(set) var motionLocked = true

    var isCarouselInputEnabled: Bool {
        phase == .entryMorph || phase == .carouselStable
    }

    var isExpanded: Bool {
        // Includes the in-progress `.expandingHero` animation phase
        // because the user has already committed to expanding by the
        // time we reach it (`beginExpand()` transitioned out of
        // carousel-stable); the view is no longer carousel-interactive,
        // so semantically the preview is "expanded" from the user's
        // perspective for the duration of the animation.
        phase == .expandingHero || phase == .expandedHero || phase == .detailsStable
    }

    mutating func completeEntryMorph() {
        guard phase == .entryMorph else { return }
        phase = .carouselStable
    }

    mutating func beginPaging() {
        guard phase == .carouselStable else { return }
        motionLocked = true
    }

    mutating func finishPaging() {
        guard phase == .carouselStable else { return }
        motionLocked = false
    }

    mutating func beginExpand() {
        guard phase == .carouselStable || phase == .entryMorph else { return }
        phase = .expandingHero
        motionLocked = true
    }

    mutating func finishExpand() {
        guard phase == .expandingHero else { return }
        phase = .expandedHero
        motionLocked = false
    }

    mutating func markDetailsStable() {
        guard phase == .expandedHero || phase == .detailsStable else { return }
        phase = .detailsStable
    }

    mutating func collapseToCarousel() {
        phase = .carouselStable
        motionLocked = false
    }

    mutating func setMotionLocked(_ locked: Bool) {
        motionLocked = locked
    }

    mutating func beginExit() {
        phase = .exiting
        motionLocked = true
    }

    mutating func exitAction() -> PreviewBackAction {
        switch phase {
        case .entryMorph, .carouselStable, .exiting:
            return .dismissOverlay
        case .expandingHero, .expandedHero, .detailsStable:
            phase = .carouselStable
            motionLocked = false
            return .collapseToCarousel
        }
    }
}

struct PreviewLoadGate {
    private(set) var generation: Int = 0

    @discardableResult
    mutating func begin() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}
