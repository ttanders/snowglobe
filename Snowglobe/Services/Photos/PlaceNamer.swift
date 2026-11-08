//
//  PlaceNamer.swift
//  Snowglobe
//
//  Turns a coordinate into a plaque-friendly name ("Piazza San Marco" / "Venice, Italy")
//  with Apple Maps reverse geocoding. Needs the network; returns nil when it can't help.
//

import Foundation
import MapKit

struct PlaceName: Equatable, Sendable {
    var title: String
    var subtitle: String?
}

@MainActor
enum PlaceNamer {
    static func name(for coordinate: GeoCoordinate) async -> PlaceName? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first
        else { return nil }

        let address = item.addressRepresentations
        let city = address?.cityName
        let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Piazza San Marco" makes a nice plaque; "1560 Broadway" doesn't, so use the city instead.
        let nameIsStreetAddress = name?.first?.isNumber ?? true
        guard let title = (nameIsStreetAddress ? city : name) ?? name ?? city, !title.isEmpty else { return nil }

        // "San Francisco, CA" at home, "Venice, Italy" abroad; just the country when the title is the city.
        let subtitle = title == city ? address?.regionName : address?.cityWithContext
        return PlaceName(title: title, subtitle: subtitle)
    }
}
