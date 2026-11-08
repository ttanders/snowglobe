//
//  Theme.swift
//  Snowglobe
//
//  CORE — shared colours & fonts so the shelf, detail and AR screens feel like one app.
//  Mood: a cosy wooden shelf against a snowy winter night.
//

import SwiftUI
import UIKit

enum Theme {
    // Night sky background
    static let nightTop = Color(red: 0.05, green: 0.07, blue: 0.16)
    static let nightBottom = Color(red: 0.13, green: 0.18, blue: 0.33)

    // Wooden shelf
    static let wood = Color(red: 0.55, green: 0.36, blue: 0.22)
    static let woodDark = Color(red: 0.33, green: 0.20, blue: 0.12)
    static let woodHighlight = Color(red: 0.74, green: 0.54, blue: 0.35)

    // Accents
    static let brass = Color(red: 0.89, green: 0.74, blue: 0.46)
    static let snow = Color(red: 0.97, green: 0.98, blue: 1.0)
    static let ice = Color(red: 0.66, green: 0.85, blue: 1.0)

    static var nightGradient: LinearGradient {
        LinearGradient(colors: [nightTop, nightBottom], startPoint: .top, endPoint: .bottom)
    }

    /// Solid colour behind RealityKit views (close to the middle of `nightGradient`).
    static let sceneBackground = UIColor(red: 0.08, green: 0.11, blue: 0.23, alpha: 1)

    static func titleFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }
}
