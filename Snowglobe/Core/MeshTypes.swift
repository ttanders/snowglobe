//
//  MeshTypes.swift
//  Snowglobe
//
//  CORE CONTRACT — pure geometry handed from Rendering/Mesh (producer, off the main actor)
//  to Rendering/Globe (consumer, turns it into RealityKit MeshResources).
//  No RealityKit types here on purpose.
//

import simd

/// A triangle-mesh chunk in globe-local units (see GlobeMetrics).
struct MeshPart: Sendable {
    var positions: [SIMD3<Float>] = []
    /// Unit normals, same count as `positions`.
    var normals: [SIMD3<Float>] = []
    /// Texture coordinates, same count as `positions`.
    var uvs: [SIMD2<Float>] = []
    /// Triangle list. Front faces are counter-clockwise when viewed from outside (RealityKit default culling).
    var indices: [UInt32] = []

    init() {}

    var isEmpty: Bool { indices.isEmpty }
    var triangleCount: Int { indices.count / 3 }

    /// Appends another part, re-basing its indices.
    mutating func append(_ other: MeshPart) {
        let base = UInt32(positions.count)
        positions.append(contentsOf: other.positions)
        normals.append(contentsOf: other.normals)
        uvs.append(contentsOf: other.uvs)
        indices.append(contentsOf: other.indices.map { $0 + base })
    }
}

/// Everything inside the glass except the snow, ready to be turned into entities.
struct DioramaGeometry: Sendable {
    /// Top surface of the terrain disk. UVs map into the ground image via `GlobeMetrics.groundUV`.
    var terrainTop = MeshPart()
    /// Vertical "cut earth" band around the disk edge, from the terrain edge down to groundY.
    /// UVs: u = angle / 2π (0...1 around the rim), v = 0 at the terrain edge, 1 at groundY.
    var terrainSkirt = MeshPart()
    /// Flat snowy ring between `dioramaRadius` and `snowRingRadius`, just above groundY.
    var snowRing = MeshPart()
    /// Building walls split into palette slots (array index = slot; slots may be empty).
    /// UVs are in window-grid modules (texture repeats): u = meters along the wall / 3.5, v = meters above ground / 3.2.
    var buildingWalls: [MeshPart] = []
    /// Building roofs; UVs map into the ground image exactly like `terrainTop`, so roofs show real roof imagery.
    var buildingRoofs = MeshPart()
    var treeFoliage = MeshPart()
    var treeTrunks = MeshPart()
    /// Little white caps on top of the trees.
    var treeSnowCaps = MeshPart()
    /// Where snow flakes come to rest.
    var snowSurface: SnowHeightField = .flat()
    /// Highest Y of any generated content (for framing / sanity checks).
    var maxContentY: Float = GlobeMetrics.groundY

    init() {}
}

/// Top-down height field of everything snow can land on (terrain, roofs, tree tops), in globe units.
struct SnowHeightField: Sendable {
    /// Cells per side. The grid covers x, z ∈ [-extent, extent].
    var resolution: Int
    var extent: Float
    /// `resolution * resolution` surface Y values (globe-local), row-major.
    /// Row index follows z (row 0 = z = -extent, i.e. the NORTH edge); column index follows x (col 0 = x = -extent, west).
    /// Each cell stores the MAX surface height inside it (so flakes rest on roofs, not beside them).
    var heights: [Float]

    init(resolution: Int, extent: Float, heights: [Float]) {
        self.resolution = resolution
        self.extent = extent
        self.heights = heights
    }

    /// A flat field at `y` (used for placeholders and as a fallback).
    static func flat(resolution: Int = 8,
                     extent: Float = GlobeMetrics.snowRingRadius,
                     y: Float = GlobeMetrics.groundY) -> SnowHeightField {
        SnowHeightField(resolution: resolution, extent: extent,
                        heights: Array(repeating: y, count: resolution * resolution))
    }

    /// Surface Y at globe-local (x, z) using nearest-cell lookup; `GlobeMetrics.groundY` outside the grid.
    func surfaceY(x: Float, z: Float) -> Float {
        guard resolution > 0, heights.count == resolution * resolution, extent > 0,
              abs(x) <= extent, abs(z) <= extent else { return GlobeMetrics.groundY }
        let n = Float(resolution)
        let col = min(resolution - 1, max(0, Int((x + extent) / (2 * extent) * n)))
        let row = min(resolution - 1, max(0, Int((z + extent) / (2 * extent) * n)))
        return heights[row * resolution + col]
    }
}
