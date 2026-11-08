//
//  Theme.swift
//  Snowglobe
//
//  CORE — shared colours & fonts so the shelf, detail and AR screens feel like one app.
//  Mood: a snowy winter night — dark blue sky, spruce shelves, white snow and light blue ice.
//

import SwiftUI
import UIKit
import CoreText

enum Theme {
    // Night sky page background
    static let nightTop = Color(red: 0.05, green: 0.07, blue: 0.16)
    static let nightBottom = Color(red: 0.13, green: 0.18, blue: 0.33)

    // Frosted shelf & pedestals
    static let frost = Color(red: 0.93, green: 0.97, blue: 1.0)
    static let frostDark = Color(red: 0.72, green: 0.85, blue: 0.98)

    // Spruce wood shelves (palette taken from Minecraft spruce planks)
    static let spruceLight = Color(red: 0.55, green: 0.42, blue: 0.25)
    static let spruce = Color(red: 0.45, green: 0.33, blue: 0.19)
    static let spruceDark = Color(red: 0.33, green: 0.23, blue: 0.13)
    static let spruceGrain = Color(red: 0.24, green: 0.16, blue: 0.08)
    /// Cream lettering burned into the plank edge.
    static let shelfLabel = Color(red: 0.97, green: 0.91, blue: 0.80)

    // Accents
    static let accent = Color(red: 0.33, green: 0.62, blue: 0.93)
    /// Dark navy for text on the light backgrounds.
    static let ink = Color(red: 0.10, green: 0.22, blue: 0.40)
    static let snow = Color.white
    static let ice = Color(red: 0.66, green: 0.85, blue: 1.0)
    static let heart = Color(red: 1.0, green: 0.36, blue: 0.48)

    static var nightGradient: LinearGradient {
        LinearGradient(colors: [nightTop, nightBottom], startPoint: .top, endPoint: .bottom)
    }

    /// Solid colour behind RealityKit views (close to the middle of `nightGradient`).
    static let sceneBackground = UIColor(red: 0.08, green: 0.11, blue: 0.23, alpha: 1)

    // MARK: - Fonts (Inter, bundled in Resources/Fonts)

    private static let fontFamily = "Inter"

    /// Large display titles at a custom size; still scales with Dynamic Type.
    static func titleFont(_ size: CGFloat) -> Font {
        .custom(fontFamily, size: size, relativeTo: .largeTitle).weight(.bold)
    }

    /// Inter at the default size of a system text style, scaling with Dynamic Type.
    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom(fontFamily, size: defaultSize(for: style), relativeTo: style).weight(weight)
    }

    private static func defaultSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17 // headline, body
        }
    }

    /// Registers the bundled Inter font files so `Font.custom("Inter", …)` resolves.
    /// Call once at launch.
    static func registerFonts() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls where url.lastPathComponent.hasPrefix(fontFamily) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
