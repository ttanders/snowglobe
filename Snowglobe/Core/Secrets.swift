//
//  Secrets.swift
//  Snowglobe
//
//  Reads API keys from Snowglobe/Secrets.plist, which is git-ignored so keys never reach GitHub.
//  To set it up: copy Secrets.example.plist (repo root) to Snowglobe/Secrets.plist and paste your key.
//

import Foundation

enum Secrets {
    /// Google Maps Platform key for Photorealistic 3D Tiles (Map Tiles API), or nil if it hasn't been added yet.
    static let googleMapsAPIKey: String? = value(for: "GoogleMapsAPIKey")

    private static func value(for key: String) -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let values = NSDictionary(contentsOf: url) as? [String: Any],
              let value = (values[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value != "PASTE_YOUR_KEY_HERE"
        else { return nil }
        return value
    }
}
