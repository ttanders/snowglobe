//
//  SnowSurface.swift
//  Snowglobe
//
//  Where snow comes to rest inside a globe: a top-down height map of the ground, rooftops and
//  treetops (SnowHeightField, see MeshTypes), measured from the miniature's triangles.
//
//  A miniature carries its map in a SnowSurfaceComponent, so the map travels with the entity
//  (and its clones) from the loader to the detail view and to AR. Real places are measured off
//  the main actor while they're built (PhotorealDioramaBuilder); the little fallback village is
//  measured from its meshes (`SnowHeightField.measuring`).
//

import RealityKit
import simd

/// The snow surface of a miniature, attached to its content entity.
struct SnowSurfaceComponent: Component {
    var field: SnowHeightField
}

extension SnowHeightField {
    /// Grid size used for miniatures: 128 cells across the snowy disk, ~1.4 % of the glass radius each
    /// (about 4 m of real world in a 300 m globe).
    static let miniatureResolution = 128

    /// Builds a height field from triangle meshes in globe units. Each cell takes the height of the
    /// topmost triangle above its centre, or `floorY` (the snowy ground) where nothing stands.
    /// Pure data, safe off the main actor.
    struct Builder {
        private(set) var field: SnowHeightField

        init(resolution: Int = SnowHeightField.miniatureResolution,
             extent: Float = GlobeMetrics.snowRingRadius,
             floorY: Float = GlobeMetrics.snowGroundTopY) {
            field = SnowHeightField(resolution: resolution, extent: extent,
                                    heights: Array(repeating: floorY, count: resolution * resolution))
        }

        /// Adds a triangle list. `transform` (if any) takes the positions into globe units first.
        mutating func addTriangles(positions: [SIMD3<Float>], indices: [UInt32], transform: simd_float4x4? = nil) {
            let points: [SIMD3<Float>]
            if let transform {
                points = positions.map { p in
                    let q = transform * SIMD4(p, 1)
                    return SIMD3(q.x, q.y, q.z)
                }
            } else {
                points = positions
            }
            let n = field.resolution
            let extent = field.extent
            let cell = 2 * extent / Float(n)
            // Cell centres sit at -extent + (i + 0.5) * cell; these convert a coordinate to a fractional index.
            func index(_ value: Float) -> Float { (value + extent) / cell - 0.5 }

            field.heights.withUnsafeMutableBufferPointer { heights in
                var t = 0
                while t + 2 < indices.count {
                    let i0 = Int(indices[t]), i1 = Int(indices[t + 1]), i2 = Int(indices[t + 2])
                    t += 3
                    guard i0 < points.count, i1 < points.count, i2 < points.count else { continue }
                    let a = points[i0], b = points[i1], c = points[i2]

                    // Cell centres inside the triangle's bounding box (none for tiny or vertical triangles).
                    let col0 = max(0, Int(index(min(a.x, b.x, c.x)).rounded(.up)))
                    let col1 = min(n - 1, Int(index(max(a.x, b.x, c.x)).rounded(.down)))
                    let row0 = max(0, Int(index(min(a.z, b.z, c.z)).rounded(.up)))
                    let row1 = min(n - 1, Int(index(max(a.z, b.z, c.z)).rounded(.down)))
                    guard col0 <= col1, row0 <= row1 else { continue }

                    let area = (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
                    guard abs(area) > 1e-12 else { continue }
                    let inverseArea = 1 / area
                    let slack: Float = -1e-4 // so cells exactly on a shared edge aren't missed

                    for row in row0...row1 {
                        let z = -extent + (Float(row) + 0.5) * cell
                        for col in col0...col1 {
                            let x = -extent + (Float(col) + 0.5) * cell
                            // Barycentric weights of (x, z) in the triangle seen from above.
                            let wa = ((b.x - x) * (c.z - z) - (c.x - x) * (b.z - z)) * inverseArea
                            let wb = ((c.x - x) * (a.z - z) - (a.x - x) * (c.z - z)) * inverseArea
                            let wc = 1 - wa - wb
                            guard wa >= slack, wb >= slack, wc >= slack else { continue }
                            let y = wa * a.y + wb * b.y + wc * c.y
                            let cellIndex = row * n + col
                            if y > heights[cellIndex] { heights[cellIndex] = y }
                        }
                    }
                }
            }
        }
    }

    /// The snow surface of everything under `root` (whose space must be globe units, as for diorama
    /// content). Meant for small procedural scenes; real places are measured while they're built.
    @MainActor
    static func measuring(_ root: Entity) -> SnowHeightField {
        var builder = Builder()
        func visit(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self] {
                let toRoot = entity.transformMatrix(relativeTo: root)
                let contents = model.mesh.contents
                for instance in contents.instances {
                    guard let mesh = contents.models[instance.model] else { continue }
                    for part in mesh.parts {
                        guard let indices = part.triangleIndices?.elements else { continue }
                        builder.addTriangles(positions: part.positions.elements, indices: indices,
                                             transform: toRoot * instance.transform)
                    }
                }
            }
            for child in entity.children { visit(child) }
        }
        visit(root)
        return builder.field
    }
}
