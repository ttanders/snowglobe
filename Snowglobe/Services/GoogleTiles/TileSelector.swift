//
//  TileSelector.swift
//  Snowglobe
//
//  Walks Google's 3D Tiles hierarchy and picks the tiles that cover a circle on the ground,
//  at a level of detail that suits a miniature (finer tiles for small areas, coarser for big ones).
//

import Foundation
import simd

/// WGS84 helpers.
enum Geodesy {
    static let semiMajorAxis = 6_378_137.0
    static let eccentricitySquared = 6.69437999014e-3

    /// Earth-centred, Earth-fixed position (meters) of a coordinate at `height` above the ellipsoid.
    static func ecef(latitude: Double, longitude: Double, height: Double = 0) -> SIMD3<Double> {
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        let n = semiMajorAxis / (1 - eccentricitySquared * sin(lat) * sin(lat)).squareRoot()
        return SIMD3((n + height) * cos(lat) * cos(lon),
                     (n + height) * cos(lat) * sin(lon),
                     (n * (1 - eccentricitySquared) + height) * sin(lat))
    }

    /// East-north-up frame on the ellipsoid at a coordinate.
    struct LocalFrame: Sendable {
        let origin: SIMD3<Double>
        let east: SIMD3<Double>
        let north: SIMD3<Double>
        let up: SIMD3<Double>

        init(center: GeoCoordinate) {
            let lat = center.latitude * .pi / 180
            let lon = center.longitude * .pi / 180
            origin = Geodesy.ecef(latitude: center.latitude, longitude: center.longitude)
            east = SIMD3(-sin(lon), cos(lon), 0)
            north = SIMD3(-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat))
            up = SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        }

        /// (east, north, up) meters of an ECEF point relative to the centre.
        func local(_ point: SIMD3<Double>) -> SIMD3<Double> {
            let d = point - origin
            return SIMD3(simd_dot(d, east), simd_dot(d, north), simd_dot(d, up))
        }
    }
}

actor TileSelector {
    private enum Tuning {
        /// Detail target: about radius / 30 meters of geometric error. Google's levels are ~2, 4, 8, 16… m,
        /// so a 300 m globe gets the 8 m level: ~65 tiles, a few MB. Each finer level is ~4× more tiles.
        static let errorPerRadius = 1.0 / 30.0
        static let minimumError = 1.0
        /// If more tiles than this are needed, coarsen the detail and try again.
        static let maxTiles = 120
        /// Vertical extent searched for the ground: from below sea level up to high mountains.
        static let searchHeights: ClosedRange<Double> = -300...6000
    }

    private let client: GoogleTilesClient
    private let radius: Double
    private let segmentStart: SIMD3<Double>
    private let segmentEnd: SIMD3<Double>
    private var targetError = 1.0
    private var tilesetCache: [String: (TilesetJSON, URL)] = [:]

    init(client: GoogleTilesClient, center: GeoCoordinate, radiusMeters: Double) {
        self.client = client
        self.radius = radiusMeters * 1.02 // a little margin so the clipped edge has no gaps
        segmentStart = Geodesy.ecef(latitude: center.latitude, longitude: center.longitude,
                                    height: Tuning.searchHeights.lowerBound)
        segmentEnd = Geodesy.ecef(latitude: center.latitude, longitude: center.longitude,
                                  height: Tuning.searchHeights.upperBound)
    }

    /// URLs of the .glb tiles to download.
    func select() async throws -> [URL] {
        let (root, rootURL) = try await client.root()
        var error = max(radius * Tuning.errorPerRadius, Tuning.minimumError)
        var urls: [URL] = []
        for _ in 0..<5 {
            targetError = error
            urls = try await visit(root.root, base: rootURL)
            if urls.count <= Tuning.maxTiles { break }
            error *= 2
        }
        return Array(Set(urls)).sorted { $0.absoluteString < $1.absoluteString }.prefix(Tuning.maxTiles * 2).map { $0 }
    }

    private func visit(_ tile: TileJSON, base: URL) async throws -> [URL] {
        guard let box = tile.boundingVolume.box, box.count == 12, distance(toBox: box) <= radius else { return [] }

        if tile.hasTilesetContent, let uri = tile.content?.uri {
            let (subtileset, url) = try await nestedTileset(uri, base: base)
            return try await visit(subtileset.root, base: url)
        }

        // Refine ("REPLACE"): use the children instead of this tile while it's still too coarse.
        if let children = tile.children, !children.isEmpty, tile.geometricError > targetError {
            return try await withThrowingTaskGroup(of: [URL].self) { group in
                for child in children {
                    group.addTask { try await self.visit(child, base: base) }
                }
                var urls: [URL] = []
                for try await childURLs in group { urls += childURLs }
                return urls
            }
        }

        guard let uri = tile.content?.uri else { return [] }
        return [try await client.resolve(uri, relativeTo: base)]
    }

    private func nestedTileset(_ uri: String, base: URL) async throws -> (TilesetJSON, URL) {
        let cacheKey = URLComponents(string: uri)?.path ?? uri
        if let cached = tilesetCache[cacheKey] { return cached }
        let result = try await client.tileset(at: uri, relativeTo: base)
        tilesetCache[cacheKey] = result
        return result
    }

    // MARK: - Geometry

    /// Shortest distance between the vertical search segment through the centre and an oriented box.
    private func distance(toBox box: [Double]) -> Double {
        let center = SIMD3(box[0], box[1], box[2])
        let axes = [SIMD3(box[3], box[4], box[5]), SIMD3(box[6], box[7], box[8]), SIMD3(box[9], box[10], box[11])]
        func distance(to point: SIMD3<Double>) -> Double {
            let d = point - center
            var sum = 0.0
            for axis in axes {
                let half = simd_length(axis)
                guard half > 0 else { continue }
                let excess = abs(simd_dot(d, axis) / half) - half
                if excess > 0 { sum += excess * excess }
            }
            return sum.squareRoot()
        }
        // Distance to a convex box along a line is convex, so a ternary search finds the minimum.
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let a = low + (high - low) / 3
            let b = high - (high - low) / 3
            if distance(to: point(at: a)) < distance(to: point(at: b)) { high = b } else { low = a }
        }
        return distance(to: point(at: (low + high) / 2))
    }

    private func point(at t: Double) -> SIMD3<Double> {
        segmentStart + (segmentEnd - segmentStart) * t
    }
}
