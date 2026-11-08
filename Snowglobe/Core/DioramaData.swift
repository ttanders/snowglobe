//
//  DioramaData.swift
//  Snowglobe
//
//  CORE CONTRACT — the real-world description of a globe's miniature.
//
//  Produced by Services/MapData (OpenStreetMap + terrain, or procedural fallback),
//  cached to disk as JSON by the Store, and consumed by Rendering/Mesh.
//
//  Local frame (meters): origin = globe center coordinate, +x = east, +y = north.
//

import Foundation
import simd

struct DioramaData: Codable, Sendable {
    static let currentVersion = 1

    /// Bump `currentVersion` when the format changes; the Store rebuilds globes with older data.
    var version: Int = DioramaData.currentVersion
    var center: GeoCoordinate
    var radiusMeters: Double
    var buildings: [BuildingFootprint]
    var trees: [TreePlacement]
    /// nil = flat ground.
    var terrain: TerrainGrid?
    var source: DioramaSource
    /// Data credits to show in the UI, e.g. "© OpenStreetMap contributors".
    var attribution: [String]
}

enum DioramaSource: String, Codable, Sendable {
    /// Real buildings / trees from OpenStreetMap (Overpass API).
    case openStreetMap
    /// Generated toy town (offline / network failure fallback).
    case procedural
}

struct BuildingFootprint: Codable, Sendable, Hashable {
    /// Outer ring in local meters, counter-clockwise when viewed from above (x east, y north),
    /// NOT closed (first point != last point), already clipped to the diorama disk, ≥ 3 points.
    var outline: [SIMD2<Float>]
    /// Height above the local ground in meters (> 0), before any exaggeration.
    var height: Float
    var kind: BuildingKind
}

enum BuildingKind: String, Codable, Sendable, CaseIterable {
    case residential, commercial, industrial, civic, religious, other
}

struct TreePlacement: Codable, Sendable, Hashable {
    /// Local meters (east, north).
    var position: SIMD2<Float>
    /// Total tree height in meters (before exaggeration).
    var height: Float
    var kind: TreeKind
}

enum TreeKind: String, Codable, Sendable {
    case conifer, deciduous
}

/// Regular height map covering the square [-radiusMeters, radiusMeters]² (meters).
struct TerrainGrid: Codable, Sendable {
    /// Samples per side (≥ 2).
    var resolution: Int
    /// Half extent of the square grid in meters.
    var radiusMeters: Float
    /// `resolution * resolution` heights in meters, row-major.
    /// Row 0 = south edge (y = -radius), last row = north edge (y = +radius).
    /// Column 0 = west edge (x = -radius), last column = east edge.
    /// Heights are relative to the lowest sample inside the disk (so ≥ 0 inside the disk).
    var heights: [Float]

    init(resolution: Int, radiusMeters: Float, heights: [Float]) {
        self.resolution = resolution
        self.radiusMeters = radiusMeters
        self.heights = heights
    }

    var maxHeight: Float { heights.max() ?? 0 }

    /// Bilinear sample at a local position in meters (x east, y north). Clamped to the grid edge.
    func height(atEast x: Float, north y: Float) -> Float {
        guard resolution >= 2, heights.count == resolution * resolution, radiusMeters > 0 else { return 0 }
        let n = Float(resolution - 1)
        let fx = clamp((x + radiusMeters) / (2 * radiusMeters) * n, 0, n)
        let fy = clamp((y + radiusMeters) / (2 * radiusMeters) * n, 0, n)
        let x0 = min(Int(fx), resolution - 2)
        let y0 = min(Int(fy), resolution - 2)
        let tx = fx - Float(x0)
        let ty = fy - Float(y0)
        let h00 = heights[y0 * resolution + x0]
        let h10 = heights[y0 * resolution + x0 + 1]
        let h01 = heights[(y0 + 1) * resolution + x0]
        let h11 = heights[(y0 + 1) * resolution + x0 + 1]
        return lerp(lerp(h00, h10, tx), lerp(h01, h11, tx), ty)
    }
}
