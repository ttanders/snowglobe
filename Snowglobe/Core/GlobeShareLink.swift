//
//  GlobeShareLink.swift
//  Snowglobe
//
//  Web links for sharing a globe. The link only describes the place (name, coordinates, size);
//  the web viewer (docs/globe.html, hosted on GitHub Pages) loads the 3D place itself in the browser,
//  so nothing is uploaded.
//
//  The coordinates are rounded before they go in the link, so a globe made from a personal photo
//  doesn't give away the exact spot it was taken: they snap to a grid sized to the globe (see
//  `privacyGridMeters`), close enough that the shared globe shows nearly the same view.
//

import Foundation

enum GlobeShareLink {
    /// Where the web viewer lives. Change this one value if the page moves to another host.
    static let viewerURL = URL(string: "https://ttanders.github.io/snowglobe/globe.html")!

    /// Grid the shared location snaps to, as a share of the globe's radius (with a floor), e.g. a
    /// 300 m globe is shared to the nearest 120 m: the right neighbourhood, not the exact spot.
    static let privacyGridShare = 0.4
    static let minimumPrivacyGridMeters = 50.0

    /// e.g. https://ttanders.github.io/snowglobe/globe.html?t=Times%20Square&s=New%20York&lat=40.75816&lon=-73.98533&r=300
    static func url(for globe: SnowGlobe) -> URL {
        var components = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "t", value: globe.title)]
        if let subtitle = globe.subtitle, !subtitle.isEmpty {
            items.append(URLQueryItem(name: "s", value: subtitle))
        }
        let shared = roundedCoordinate(globe.coordinate, radiusMeters: globe.radiusMeters)
        items += [
            URLQueryItem(name: "lat", value: String(format: "%.5f", shared.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.5f", shared.longitude)),
            URLQueryItem(name: "r", value: String(Int(globe.radiusMeters.rounded()))),
        ]
        components.queryItems = items
        return components.url ?? viewerURL
    }

    static func privacyGridMeters(radiusMeters: Double) -> Double {
        max(minimumPrivacyGridMeters, radiusMeters * privacyGridShare)
    }

    /// `coordinate` snapped to the centre of its grid cell (cells are about `privacyGridMeters` across).
    static func roundedCoordinate(_ coordinate: GeoCoordinate, radiusMeters: Double) -> GeoCoordinate {
        let grid = privacyGridMeters(radiusMeters: radiusMeters)
        let metersPerDegreeLatitude = 111_320.0
        // A degree of longitude shrinks toward the poles; keep it sensible right at them.
        let metersPerDegreeLongitude = max(metersPerDegreeLatitude * cos(coordinate.latitude * .pi / 180), 1_000)
        func snap(_ value: Double, step: Double) -> Double {
            (value / step).rounded(.down) * step + step / 2
        }
        let latitude = min(max(snap(coordinate.latitude, step: grid / metersPerDegreeLatitude), -89.9), 89.9)
        var longitude = snap(coordinate.longitude, step: grid / metersPerDegreeLongitude)
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }
}
