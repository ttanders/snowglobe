//
//  PhotorealDioramaBuilder.swift
//  Snowglobe
//
//  Turns downloaded Google tiles into the miniature: converts them to local meters around the
//  globe's centre, finds the ground level, cuts a clean circle, scales it into globe units
//  (see GlobeMetrics), squeezes very tall towers so they fit under the dome, and adds an earthy
//  band around the cut edge. Pure data — runs off the main actor.
//

import Foundation
import CoreGraphics
import ImageIO
import simd

/// A textured piece of the miniature in globe units, ready for RealityKit.
struct TexturedMesh: @unchecked Sendable { // CGImage is immutable, so sharing it across threads is safe
    var positions: [SIMD3<Float>] = []
    /// RealityKit convention (see GlobeMetrics.textureOriginIsBottomLeft).
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []
    var image: CGImage?
}

struct PhotorealDiorama: @unchecked Sendable {
    var tiles: [TexturedMesh]
    /// Vertical band from the cut edge down to the snow, drawn in an earthy colour.
    var edge: MeshPart
    /// Data credits to show on screen (Google first).
    var attributions: [String]
    var triangleCount: Int
}

enum PhotorealDioramaBuilder {
    private enum Tuning {
        /// The circle is cut as a polygon with this many sides.
        static let clipSegments = 128
        /// Ground level = this low percentile of heights inside the circle (ignores odd low spikes).
        static let groundPercentile: Float = 0.03
        /// The miniature's ground sits just above the snow disk (GlobeEntityFactory.surfaceY + 4 mm).
        static let baseY: Float = GlobeMetrics.groundY + 0.014
        /// Where the cut-edge band ends (just inside the snow disk).
        static let edgeBottomY: Float = GlobeMetrics.groundY + 0.006
        /// Heights above this share of the room under the dome are smoothly compressed so towers fit.
        static let compressionKnee: Float = 0.7
    }

    private struct Vertex {
        var p: SIMD3<Float>   // local meters: east, north, up
        var uv: SIMD2<Float>  // glTF convention
    }

    static func build(tiles: [ParsedTile], center: GeoCoordinate, radiusMeters: Double) -> PhotorealDiorama {
        let frame = Geodesy.LocalFrame(center: center)
        let radius = Float(radiusMeters)
        let scale = GlobeMetrics.unitsPerMeter(radiusMeters: radiusMeters)

        // 1. Every vertex in local meters.
        let sources = tiles.flatMap(\.meshes)
        let locals: [[SIMD3<Float>]] = sources.map { mesh in mesh.positions.map { SIMD3<Float>(frame.local($0)) } }

        // 2. Ground level.
        let ground = groundLevel(locals, radius: radius)

        // 3. Local meters → globe units.
        func globePoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let x = p.x * scale
            let z = -p.y * scale
            let room = max(GlobeMetrics.maxContentY(atRadius: (x * x + z * z).squareRoot()) - Tuning.baseY, 0.02)
            let knee = room * Tuning.compressionKnee
            var height = max((p.z - ground) * scale, -0.02)
            if height > knee {
                height = knee + (room - knee) * tanh((height - knee) / (room - knee))
            }
            return SIMD3(x, Tuning.baseY + height, z)
        }

        // 4. Cut each mesh to the circle.
        let clipper = CircleClipper(radius: radius, segments: Tuning.clipSegments)
        var result: [TexturedMesh] = []
        var edge = MeshPart()
        var triangleCount = 0

        for (source, local) in zip(sources, locals) {
            var out = TexturedMesh()
            var remap = [Int32](repeating: -1, count: local.count)
            func emitShared(_ index: Int) -> UInt32 {
                if remap[index] < 0 {
                    remap[index] = Int32(out.positions.count)
                    out.positions.append(globePoint(local[index]))
                    out.uvs.append(realityKitUV(source.uvs[index]))
                }
                return UInt32(remap[index])
            }

            var t = 0
            while t + 2 < source.indices.count {
                let i0 = Int(source.indices[t]), i1 = Int(source.indices[t + 1]), i2 = Int(source.indices[t + 2])
                t += 3
                switch clipper.classify(local[i0], local[i1], local[i2]) {
                case .inside:
                    out.indices += [emitShared(i0), emitShared(i1), emitShared(i2)]
                case .outside:
                    continue
                case .crossing:
                    let triangle = [Vertex(p: local[i0], uv: source.uvs[i0]),
                                    Vertex(p: local[i1], uv: source.uvs[i1]),
                                    Vertex(p: local[i2], uv: source.uvs[i2])]
                    let (polygon, boundaryEdges) = clipper.clip(triangle)
                    guard polygon.count >= 3 else { continue }
                    let base = UInt32(out.positions.count)
                    for vertex in polygon {
                        out.positions.append(globePoint(vertex.p))
                        out.uvs.append(realityKitUV(vertex.uv))
                    }
                    for k in 1..<(polygon.count - 1) { // clipped triangle is convex: fan it
                        out.indices += [base, base + UInt32(k), base + UInt32(k + 1)]
                    }
                    for (a, b) in boundaryEdges {
                        addEdgeQuad(from: globePoint(polygon[a].p), to: globePoint(polygon[b].p), into: &edge)
                    }
                }
            }

            guard !out.indices.isEmpty else { continue }
            triangleCount += out.indices.count / 3
            out.image = source.imageData.flatMap(decodeImage)
            result.append(out)
        }

        return PhotorealDiorama(tiles: result, edge: edge,
                                attributions: attributions(from: tiles.compactMap(\.copyright)),
                                triangleCount: triangleCount)
    }

    // MARK: - Helpers

    private static func groundLevel(_ locals: [[SIMD3<Float>]], radius: Float) -> Float {
        let total = locals.reduce(0) { $0 + $1.count }
        let step = max(1, total / 150_000) // sampling is plenty
        var heights: [Float] = []
        var counter = 0
        for mesh in locals {
            for p in mesh {
                counter += 1
                if counter % step == 0, p.x * p.x + p.y * p.y <= radius * radius { heights.append(p.z) }
            }
        }
        guard !heights.isEmpty else { return 0 }
        heights.sort()
        return heights[min(heights.count - 1, Int(Float(heights.count) * Tuning.groundPercentile))]
    }

    private static func realityKitUV(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        GlobeMetrics.textureOriginIsBottomLeft ? SIMD2(uv.x, 1 - uv.y) : uv
    }

    /// A quad from a cut-edge segment straight down to the snow, facing outward.
    private static func addEdgeQuad(from a: SIMD3<Float>, to b: SIMD3<Float>, into part: inout MeshPart) {
        let middle = (a + b) / 2
        let outward = simd_normalize(SIMD3(middle.x, 0, middle.z))
        let aBottom = SIMD3(a.x, Tuning.edgeBottomY, a.z)
        let bBottom = SIMD3(b.x, Tuning.edgeBottomY, b.z)
        let base = UInt32(part.positions.count)
        part.positions += [a, b, bBottom, aBottom]
        part.normals += [outward, outward, outward, outward]
        part.uvs += [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        // Wind so the front face points outward (the material is double-sided anyway).
        let faceNormal = simd_cross(b - a, aBottom - a)
        if simd_dot(faceNormal, outward) >= 0 {
            part.indices += [base, base + 1, base + 3, base + 1, base + 2, base + 3]
        } else {
            part.indices += [base, base + 3, base + 1, base + 1, base + 3, base + 2]
        }
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// "Google;Airbus;Landsat" strings → unique credits, most common first, Google first.
    private static func attributions(from copyrights: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for copyright in copyrights {
            for credit in copyright.split(separator: ";") {
                let trimmed = credit.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { counts[trimmed, default: 0] += 1 }
            }
        }
        return counts.sorted { lhs, rhs in
            if (lhs.key == "Google") != (rhs.key == "Google") { return lhs.key == "Google" }
            return lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }.map(\.key)
    }

    // MARK: - Circle clipping

    /// Clips triangles (in the east/north plane) to a regular polygon approximating the circle.
    private struct CircleClipper {
        enum Classification { case inside, outside, crossing }

        let radius: Float
        let corners: [SIMD2<Float>]
        let innerRadiusSquared: Float
        let step: Float

        init(radius: Float, segments: Int) {
            self.radius = radius
            step = 2 * .pi / Float(segments)
            corners = (0..<segments).map { k in
                let angle = Float(k) * 2 * .pi / Float(segments)
                return SIMD2(cos(angle), sin(angle)) * radius
            }
            let inner = radius * cos(.pi / Float(segments))
            innerRadiusSquared = inner * inner
        }

        func classify(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Classification {
            let ra = a.x * a.x + a.y * a.y, rb = b.x * b.x + b.y * b.y, rc = c.x * c.x + c.y * c.y
            if ra <= innerRadiusSquared, rb <= innerRadiusSquared, rc <= innerRadiusSquared { return .inside }
            let outer = radius * radius
            if ra > outer, rb > outer, rc > outer,
               !segmentNearOrigin(a, b), !segmentNearOrigin(b, c), !segmentNearOrigin(c, a),
               !containsOrigin(a, b, c) {
                return .outside
            }
            return .crossing
        }

        /// Sutherland–Hodgman against the polygon edges near the triangle.
        /// Returns the clipped polygon and the index pairs of its edges that lie on the circle.
        func clip(_ triangle: [Vertex]) -> ([Vertex], [(Int, Int)]) {
            let edges = relevantEdges(for: triangle)
            var polygon = triangle
            for k in edges {
                polygon = clip(polygon, edge: k)
                if polygon.count < 3 { return ([], []) }
            }
            var boundary: [(Int, Int)] = []
            for i in 0..<polygon.count {
                let j = (i + 1) % polygon.count
                if edges.contains(where: { onEdge(polygon[i], $0) && onEdge(polygon[j], $0) }) {
                    boundary.append((i, j))
                }
            }
            return (polygon, boundary)
        }

        private func clip(_ polygon: [Vertex], edge k: Int) -> [Vertex] {
            var output: [Vertex] = []
            for i in 0..<polygon.count {
                let current = polygon[i]
                let previous = polygon[(i + polygon.count - 1) % polygon.count]
                let currentSide = side(current, k)
                let previousSide = side(previous, k)
                if currentSide >= 0 {
                    if previousSide < 0 { output.append(intersection(previous, current, previousSide, currentSide)) }
                    output.append(current)
                } else if previousSide >= 0 {
                    output.append(intersection(previous, current, previousSide, currentSide))
                }
            }
            return output
        }

        /// ≥ 0 inside (left of the counter-clockwise edge k).
        private func side(_ v: Vertex, _ k: Int) -> Float {
            let a = corners[k], b = corners[(k + 1) % corners.count]
            let edge = b - a
            let offset = SIMD2(v.p.x, v.p.y) - a
            return edge.x * offset.y - edge.y * offset.x
        }

        private func onEdge(_ v: Vertex, _ k: Int) -> Bool {
            let a = corners[k], b = corners[(k + 1) % corners.count]
            return abs(side(v, k)) <= simd_length(b - a) * 0.01 // within 1 cm of the edge line
        }

        private func intersection(_ a: Vertex, _ b: Vertex, _ sideA: Float, _ sideB: Float) -> Vertex {
            let t = sideA / (sideA - sideB)
            return Vertex(p: a.p + (b.p - a.p) * t, uv: a.uv + (b.uv - a.uv) * t)
        }

        /// Polygon edges whose sectors overlap the triangle's angular span (all edges for huge triangles).
        private func relevantEdges(for triangle: [Vertex]) -> [Int] {
            let angles = triangle.map { atan2($0.p.y, $0.p.x) }
            var low: Float = 0, high: Float = 0
            for angle in angles.dropFirst() {
                var delta = angle - angles[0]
                if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
                low = min(low, delta)
                high = max(high, delta)
            }
            let count = corners.count
            if high - low > .pi / 2 || containsOrigin(triangle[0].p, triangle[1].p, triangle[2].p) {
                return Array(0..<count)
            }
            let first = Int(floor((angles[0] + low) / step)) - 1
            let last = Int(ceil((angles[0] + high) / step)) + 1
            return (first...last).map { (($0 % count) + count) % count }
        }

        private func segmentNearOrigin(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            let p = SIMD2(a.x, a.y), q = SIMD2(b.x, b.y)
            let d = q - p
            let lengthSquared = simd_length_squared(d)
            let t = lengthSquared > 0 ? clamp(-simd_dot(p, d) / lengthSquared, Float(0), Float(1)) : 0
            return simd_length(p + d * t) <= radius
        }

        private func containsOrigin(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Bool {
            func cross(_ p: SIMD3<Float>, _ q: SIMD3<Float>) -> Float { p.x * q.y - p.y * q.x }
            let d1 = cross(a, b), d2 = cross(b, c), d3 = cross(c, a)
            return (d1 >= 0 && d2 >= 0 && d3 >= 0) || (d1 <= 0 && d2 <= 0 && d3 <= 0)
        }
    }
}
