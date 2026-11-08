//
//  SnowRenderer.swift
//  Snowglobe
//
//  Draws a SnowSimulation as ONE mesh (a LowLevelMesh rewritten each frame): a small quad per
//  flake, turned to face the camera and textured from a tiny sprite sheet of soft dots and
//  sparkles. Drifting flakes tumble (flipping edge-on and back) and glint as they catch the light;
//  resting flakes are plain soft dots.
//
//  The snow is drawn after the far side of the glass and before the near side (see
//  GlobeEntityFactory.insideGlass), and doesn't write depth, so flakes never cut holes in each other.
//

import RealityKit
import UIKit
import simd

/// The camera as seen from inside the globe (unit vectors in globe axes), for turning flakes to face it.
struct SnowView: Equatable {
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    /// From the middle of the globe toward the camera.
    var toward: SIMD3<Float>
}

@MainActor
final class SnowRenderer {
    let entity: ModelEntity
    private let mesh: LowLevelMesh
    private let capacity: Int

    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    init(capacity: Int) throws {
        self.capacity = capacity
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = capacity * 4
        descriptor.indexCapacity = capacity * 6
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.normal)!),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.uv)!),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)]
        descriptor.indexType = .uint32
        let mesh = try LowLevelMesh(descriptor: descriptor)

        // Two triangles per flake, counter-clockwise as seen from the camera.
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            for quad in 0..<capacity {
                let corner = UInt32(quad * 4)
                let first = quad * 6
                indices[first] = corner
                indices[first + 1] = corner + 1
                indices[first + 2] = corner + 2
                indices[first + 3] = corner
                indices[first + 4] = corner + 2
                indices[first + 5] = corner + 3
            }
        }
        // Nothing to see until the first frame is drawn.
        mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { raw in
            _ = raw.initializeMemory(as: UInt8.self, repeating: 0)
        }
        let reach = GlobeMetrics.glassRadius * 1.1 // glints grow a little past their flake
        mesh.parts.replaceAll([
            LowLevelMesh.Part(indexCount: capacity * 6, topology: .triangle,
                              bounds: BoundingBox(min: SIMD3(repeating: -reach), max: SIMD3(repeating: reach))),
        ])
        self.mesh = mesh

        entity = ModelEntity(mesh: try MeshResource(from: mesh), materials: [Self.material])
        entity.name = "Snow"
        entity.components.set(ModelSortGroupComponent(group: GlobeEntityFactory.insideGlass,
                                                      order: GlobeEntityFactory.DrawOrder.snow))
    }

    /// Writes every flake's quad for this frame.
    func draw(_ simulation: SnowSimulation, view: SnowView) {
        let flakes = simulation.flakes
        let count = min(flakes.count, capacity)
        let right = view.right, up = view.up, toward = view.toward
        let cells = Self.cells
        let capacity = capacity

        mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { raw in
            let vertices = raw.bindMemory(to: Vertex.self)
            guard vertices.count >= capacity * 4 else { return }
            for i in 0..<count {
                let flake = flakes[i]
                var frame = 0
                var size = flake.size
                var squish: Float = 1
                var spin = flake.phase
                if flake.isResting {
                    size *= 0.85
                } else {
                    // A flat flake flashes when its face turns toward the light; which flakes flash
                    // depends on where you look from, so turning the globe makes it sparkle too.
                    let facing = cos(flake.tumble + 2.4 * simd_dot(toward, flake.facet))
                    let glint = facing > 0 ? pow(facing, flake.isGlitter ? 10 : 48) : 0
                    let level = min(6, Int(glint * 7)) // 0 = no glint … 6 = brightest sparkle
                    frame = 1 + level
                    // Tumbling: the flake turns edge-on and back, but a sparkle stays round.
                    squish = max(0.28, abs(cos(flake.tumble)))
                    squish += (1 - squish) * glint
                    size *= 1 + Float(level) / 6 * (flake.isGlitter ? 1.8 : 1.4)
                    spin += flake.tumble * 0.1
                }
                let c = cos(spin), s = sin(spin)
                let across = (right * c + up * s) * (size * squish)
                let along = (up * c - right * s) * size
                let cell = cells[frame] // (u left, v bottom, u right, v top)
                let center = flake.position
                let first = i * 4
                vertices[first] = Vertex(position: center - across - along, normal: toward, uv: SIMD2(cell.x, cell.y))
                vertices[first + 1] = Vertex(position: center + across - along, normal: toward, uv: SIMD2(cell.z, cell.y))
                vertices[first + 2] = Vertex(position: center + across + along, normal: toward, uv: SIMD2(cell.z, cell.w))
                vertices[first + 3] = Vertex(position: center - across + along, normal: toward, uv: SIMD2(cell.x, cell.w))
            }
            // Spare quads collapse to nothing.
            for i in (count * 4)..<(capacity * 4) {
                vertices[i] = Vertex(position: .zero, normal: toward, uv: .zero)
            }
        }
    }

    // MARK: - Look

    private static let material: UnlitMaterial = {
        // Unlit and not tone-mapped: snow stays crisp white under any light, in the app and in AR.
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        if let sheet = makeSpriteSheet(),
           let texture = try? TextureResource(image: sheet, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        } else {
            material.color = .init(tint: .white)
        }
        material.blending = .transparent(opacity: 1.0)
        material.writesDepth = false
        material.faceCulling = .none
        return material
    }()

    private static let columns = 4
    private static let rows = 2
    private static let cellPixels = 64

    /// Each sprite's corners in texture space: (u left, v bottom, u right, v top), inset half a texel.
    private static let cells: [SIMD4<Float>] = (0..<(columns * rows)).map { frame in
        let column = frame % columns, row = frame / columns // row 0 = top of the image
        let width = Float(columns * cellPixels), height = Float(rows * cellPixels)
        let u0 = Float(column) / Float(columns) + 0.5 / width
        let u1 = Float(column + 1) / Float(columns) - 0.5 / width
        let topFromTop = Float(row) / Float(rows) + 0.5 / height
        let bottomFromTop = Float(row + 1) / Float(rows) - 0.5 / height
        return GlobeMetrics.textureOriginIsBottomLeft
            ? SIMD4(u0, 1 - bottomFromTop, u1, 1 - topFromTop)
            : SIMD4(u0, bottomFromTop, u1, topFromTop)
    }

    /// Soft white dots and sparkles in a 4 × 2 grid (white everywhere; the shapes are in the alpha).
    /// 0: a resting flake · 1: a drifting flake · 2…7: ever brighter glints (core, halo and star rays).
    private static func makeSpriteSheet() -> CGImage? {
        let width = cellPixels * columns, height = cellPixels * rows
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.plusLighter) // overlapping strokes add up, like light
        for frame in 0..<(columns * rows) {
            let column = frame % columns, row = frame / columns
            // Core Graphics' y axis points up, so the image's top row of sprites is at the largest y.
            let center = CGPoint(x: (CGFloat(column) + 0.5) * CGFloat(cellPixels),
                                 y: CGFloat(height) - (CGFloat(row) + 0.5) * CGFloat(cellPixels))
            drawSprite(frame, at: center, cell: CGFloat(cellPixels), in: context)
        }

        // Grey coverage → white pixels with that coverage as (straight, not premultiplied) alpha.
        guard let data = context.data else { return nil }
        let coverage = data.bindMemory(to: UInt8.self, capacity: width * height)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4 + 3] = coverage[i]
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func drawSprite(_ frame: Int, at center: CGPoint, cell: CGFloat, in context: CGContext) {
        let gray = CGColorSpaceCreateDeviceGray()

        func glow(radius: CGFloat, brightness: CGFloat, hardness: CGFloat) {
            let colors = [CGColor(gray: brightness, alpha: 1), CGColor(gray: brightness * 0.8, alpha: 1),
                          CGColor(gray: 0, alpha: 1)] as CFArray
            guard let gradient = CGGradient(colorsSpace: gray, colors: colors, locations: [0, hardness, 1]) else { return }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: radius, options: [])
        }

        /// A thin diamond through the centre: two opposite rays of a star.
        func rays(angle: CGFloat, length: CGFloat, width: CGFloat, brightness: CGFloat) {
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let side = CGPoint(x: -direction.y * width, y: direction.x * width)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x + direction.x * length, y: center.y + direction.y * length))
            path.addLine(to: CGPoint(x: center.x + side.x, y: center.y + side.y))
            path.addLine(to: CGPoint(x: center.x - direction.x * length, y: center.y - direction.y * length))
            path.addLine(to: CGPoint(x: center.x - side.x, y: center.y - side.y))
            path.closeSubpath()
            context.setFillColor(gray: brightness, alpha: 1)
            context.addPath(path)
            context.fillPath()
        }

        switch frame {
        case 0:
            glow(radius: cell * 0.42, brightness: 0.95, hardness: 0.45)
        case 1:
            glow(radius: cell * 0.42, brightness: 0.85, hardness: 0.35)
        default:
            let level = CGFloat(frame - 1) / 6
            // The renderer draws glints bigger, so the flake at the centre shrinks to keep its size on screen.
            let growth = 1 + level * 1.5
            glow(radius: cell * 0.42 / growth, brightness: 1, hardness: 0.5)
            glow(radius: cell * 0.3 * (0.6 + 0.4 * level), brightness: 0.35 * level, hardness: 0.1)
            let length = cell * 0.47 * (0.45 + 0.55 * level)
            for k in 0..<2 {
                rays(angle: CGFloat(k) * .pi / 2, length: length,
                     width: cell * (0.025 + 0.02 * level), brightness: 0.5 + 0.5 * level)
                rays(angle: .pi / 4 + CGFloat(k) * .pi / 2, length: length * 0.55,
                     width: cell * (0.018 + 0.012 * level), brightness: 0.35 + 0.4 * level)
            }
        }
    }
}
