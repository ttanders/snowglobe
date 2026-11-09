//
//  ShelfSort.swift
//  Snowglobe
//
//  How a shelf page orders its globes. Picked from the sort menu at the top of the page and
//  remembered separately for Home and Favorites. Sorting only changes what's shown: the order
//  you arranged by dragging (Custom) is kept in the store until you drag a globe again.
//

import Foundation

enum ShelfSort: String, CaseIterable, Identifiable {
    /// The order you arranged by dragging globes in edit mode.
    case custom
    case name
    /// When the source photo was taken.
    case dateTaken
    /// When the globe was made.
    case dateAdded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: "Custom"
        case .name: "Name"
        case .dateTaken: "Date Taken"
        case .dateAdded: "Date Added"
        }
    }

    var systemImage: String {
        switch self {
        case .custom: "hand.draw"
        case .name: "textformat"
        case .dateTaken: "camera"
        case .dateAdded: "calendar"
        }
    }

    /// Custom has no direction to pick.
    var hasDirection: Bool { self != .custom }

    /// The direction a sort starts in when you pick it: names A to Z, dates newest first.
    var startsAscending: Bool { self == .name }

    /// Menu labels for the two directions.
    var ascendingTitle: String { self == .name ? "A to Z" : "Oldest First" }
    var descendingTitle: String { self == .name ? "Z to A" : "Newest First" }

    /// `globes` (in custom order) put in this sort's order.
    func apply(to globes: [SnowGlobe], ascending: Bool) -> [SnowGlobe] {
        guard self != .custom else { return globes }
        // Ties keep their custom order, so equal globes never swap places between redraws.
        return globes.enumerated().sorted { a, b in
            switch compare(a.element, b.element, ascending: ascending) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.offset < b.offset
            }
        }.map(\.element)
    }

    private func compare(_ a: SnowGlobe, _ b: SnowGlobe, ascending: Bool) -> ComparisonResult {
        let result: ComparisonResult
        switch self {
        case .custom:
            return .orderedSame
        case .name:
            result = a.title.localizedStandardCompare(b.title)
        case .dateAdded:
            result = a.createdAt.compare(b.createdAt)
        case .dateTaken:
            // Globes with no photo date (like the samples) go last, whichever direction you pick.
            switch (a.photoDate, b.photoDate) {
            case let (aDate?, bDate?): result = aDate.compare(bDate)
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            case (nil, nil): return .orderedSame
            }
        }
        if ascending || result == .orderedSame { return result }
        return result == .orderedAscending ? .orderedDescending : .orderedAscending
    }
}
