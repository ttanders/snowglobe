//
//  SnowGlobe.swift
//  Snowglobe
//
//  CORE CONTRACT — shared model types used by every module.
//  Keep these small, Codable and free of UI / RealityKit dependencies.
//

import Foundation
import CoreLocation

/// A latitude / longitude pair that is Codable, Hashable and Sendable
/// (CLLocationCoordinate2D is none of those).
struct GeoCoordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// False for out-of-range values and for the (0, 0) "null island" placeholder many photos carry.
    var isValid: Bool {
        CLLocationCoordinate2DIsValid(clCoordinate) && !(latitude == 0 && longitude == 0)
    }

    /// Human readable, e.g. "34.0205° N, 118.2856° W".
    var formatted: String {
        let lat = String(format: "%.4f° %@", abs(latitude), latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.4f° %@", abs(longitude), longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }
}

/// How the ground of the miniature is painted.
enum GlobeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Apple Maps satellite imagery.
    case satellite
    /// Muted Apple Maps cartography (clean, toy-like).
    case map
    /// Satellite imagery "winterized": desaturated, cooled and dusted with snow.
    case winter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .satellite: "Satellite"
        case .map: "Map"
        case .winter: "Winter"
        }
    }

    var systemImage: String {
        switch self {
        case .satellite: "globe.americas.fill"
        case .map: "map.fill"
        case .winter: "snowflake"
        }
    }
}

/// Real-world radius presets (meters) for the circle of the world captured inside a globe.
enum RadiusPreset: Double, CaseIterable, Identifiable, Sendable {
    case block = 150
    case neighborhood = 300
    case district = 600
    case landscape = 1500

    var id: Double { rawValue }

    var displayName: String {
        switch self {
        case .block: "Block"
        case .neighborhood: "Neighborhood"
        case .district: "District"
        case .landscape: "Landscape"
        }
    }

    /// e.g. "150 m" or "1.5 km".
    var detail: String {
        rawValue >= 1000 ? String(format: "%.1f km", rawValue / 1000) : "\(Int(rawValue)) m"
    }

    static func nearest(to meters: Double) -> RadiusPreset {
        allCases.min(by: { abs($0.rawValue - meters) < abs($1.rawValue - meters) }) ?? .neighborhood
    }
}

/// Lifecycle of a globe's 3D content.
enum GlobeBuildState: Codable, Hashable, Sendable {
    /// Saved but not started (e.g. queued behind another build).
    case pending
    /// Downloading data / generating meshes. `progress` is 0...1.
    case building(progress: Double, message: String)
    /// 3D content + thumbnail are on disk.
    case ready
    /// Something went wrong; the globe can be rebuilt.
    case failed(message: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// True for `.pending` and `.building`.
    var isInProgress: Bool {
        switch self {
        case .pending, .building: true
        case .ready, .failed: false
        }
    }
}

/// One snowglobe on the shelf.
struct SnowGlobe: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Main label, usually the place name ("Piazza San Marco").
    var title: String
    /// Secondary label ("Venice, Italy").
    var subtitle: String?
    /// Center of the captured circle.
    var coordinate: GeoCoordinate
    /// Real-world radius of the captured circle, meters.
    var radiusMeters: Double
    var style: GlobeStyle
    /// When the source photo was taken (if known).
    var photoDate: Date?
    var createdAt: Date
    var buildState: GlobeBuildState
    /// Incremented whenever the thumbnail image on disk changes so views can refresh caches.
    var thumbnailVersion: Int
    /// True for the demo globes seeded on first launch.
    var isSample: Bool
    /// Shown on the Favorites tab; toggled by double-tapping the globe.
    var isFavorite: Bool

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String? = nil,
        coordinate: GeoCoordinate,
        radiusMeters: Double = RadiusPreset.neighborhood.rawValue,
        style: GlobeStyle = .satellite,
        photoDate: Date? = nil,
        createdAt: Date = Date(),
        buildState: GlobeBuildState = .pending,
        thumbnailVersion: Int = 0,
        isSample: Bool = false,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.radiusMeters = radiusMeters
        self.style = style
        self.photoDate = photoDate
        self.createdAt = createdAt
        self.buildState = buildState
        self.thumbnailVersion = thumbnailVersion
        self.isSample = isSample
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, coordinate, radiusMeters, style, photoDate, createdAt
        case buildState, thumbnailVersion, isSample, isFavorite
    }

    /// Custom decoding so globes saved before `isFavorite` existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        coordinate = try container.decode(GeoCoordinate.self, forKey: .coordinate)
        radiusMeters = try container.decode(Double.self, forKey: .radiusMeters)
        style = try container.decode(GlobeStyle.self, forKey: .style)
        photoDate = try container.decodeIfPresent(Date.self, forKey: .photoDate)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        buildState = try container.decode(GlobeBuildState.self, forKey: .buildState)
        thumbnailVersion = try container.decode(Int.self, forKey: .thumbnailVersion)
        isSample = try container.decode(Bool.self, forKey: .isSample)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}
