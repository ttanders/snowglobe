//
//  GlobeShareLink.swift
//  Snowglobe
//
//  Web links for sharing a globe. The link only describes the place (name, coordinates, size);
//  the web viewer (docs/globe.html, hosted on GitHub Pages) loads the 3D place itself in the browser,
//  so nothing is uploaded.
//

import Foundation

enum GlobeShareLink {
    /// Where the web viewer lives. Change this one value if the page moves to another host.
    static let viewerURL = URL(string: "https://ttanders.github.io/snowglobe/globe.html")!

    /// e.g. https://ttanders.github.io/snowglobe/globe.html?t=Times%20Square&s=New%20York&lat=40.758000&lon=-73.985500&r=300
    static func url(for globe: SnowGlobe) -> URL {
        var components = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "t", value: globe.title)]
        if let subtitle = globe.subtitle, !subtitle.isEmpty {
            items.append(URLQueryItem(name: "s", value: subtitle))
        }
        items += [
            URLQueryItem(name: "lat", value: String(format: "%.6f", globe.coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.6f", globe.coordinate.longitude)),
            URLQueryItem(name: "r", value: String(Int(globe.radiusMeters.rounded()))),
        ]
        components.queryItems = items
        return components.url ?? viewerURL
    }
}
