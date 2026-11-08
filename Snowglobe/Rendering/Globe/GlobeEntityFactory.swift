//
//  GlobeEntityFactory.swift
//  Snowglobe
//
//  Builds a snowglobe as a RealityKit entity, in globe units (see GlobeMetrics):
//  wooden pedestal + brass collar + title plaque, a miniature on snowy ground, and a glass dome.
//
//  The miniature lives in a child entity named "Diorama". For now it's a little procedural
//  village (seeded by the globe's coordinate); a later feature swaps in real map data.
//

import RealityKit
import UIKit

@MainActor
enum GlobeEntityFactory {
    /// Name of the swappable entity standing on the snow (the real place, or the placeholder village).
    static let dioramaContentName = "DioramaContent"

    /// - Parameter content: what stands inside the glass; nil = just snow (e.g. while the real place downloads).
    static func makeGlobe(for globe: SnowGlobe, content: Entity? = nil) -> Entity {
        let root = Entity()
        root.name = "SnowGlobe"
        root.addChild(makePedestal(title: globe.title))

        let diorama = Entity()
        diorama.name = "Diorama"
        diorama.addChild(makeSnowGround())
        root.addChild(diorama)
        if let content { setDioramaContent(content, in: root) }

        root.addChild(makeGlass())
        return root
    }

    /// Replaces whatever stands on the snow inside `globe`.
    static func setDioramaContent(_ content: Entity, in globe: Entity) {
        guard let diorama = globe.findEntity(named: "Diorama") else { return }
        for old in diorama.children.filter({ $0.name == dioramaContentName }) {
            old.removeFromParent()
        }
        content.name = dioramaContentName
        diorama.addChild(content)
    }

    /// Y of the snowy ground's top surface (1 cm above the pedestal top).
    static let surfaceY = GlobeMetrics.snowGroundTopY

    /// See-through things inside a globe are drawn in a fixed order, so snow is always seen through
    /// the near side of the glass but in front of the far side.
    static let insideGlass = ModelSortGroup()

    enum DrawOrder {
        static let glassBack: Int32 = 0
        static let snow: Int32 = 1
        static let glassFront: Int32 = 2
    }

    // MARK: - Pedestal

    private static func makePedestal(title: String) -> Entity {
        let pedestal = Entity()
        pedestal.name = "Pedestal"
        let top = GlobeMetrics.groundY
        let bottom = GlobeMetrics.baseBottomY
        let plinthHeight: Float = 0.05
        let bodyHeight = top - bottom - plinthHeight
        let sides = 8
        // Distance from the centre to the middle of a flat face.
        let apothem = GlobeMetrics.baseRadius * cos(Float.pi / Float(sides))

        // Slim octagonal wooden base on a slightly wider dark plinth.
        let body = ModelEntity(mesh: GlobeMeshes.prism(sides: sides, circumradius: GlobeMetrics.baseRadius, height: bodyHeight),
                               materials: [GlobeMaterials.wood])
        body.position.y = bottom + plinthHeight
        pedestal.addChild(body)

        let plinth = ModelEntity(mesh: GlobeMeshes.prism(sides: sides, circumradius: GlobeMetrics.baseRadius + 0.06, height: plinthHeight),
                                 materials: [GlobeMaterials.woodDark])
        plinth.position.y = bottom
        pedestal.addChild(plinth)

        // Brass ring where the glass meets the wood; its top sits 5 mm above the pedestal.
        let collar = ModelEntity(mesh: .generateCylinder(height: 0.05, radius: 0.935), materials: [GlobeMaterials.brass])
        collar.position.y = top + 0.005 - 0.025
        pedestal.addChild(collar)

        // Brass plaque with the title on the front (+Z) face.
        let plaqueY = bottom + plinthHeight + bodyHeight / 2
        let plaque = ModelEntity(mesh: .generateBox(width: 0.64, height: 0.17, depth: 0.02, cornerRadius: 0.008),
                                 materials: [GlobeMaterials.brass])
        plaque.position = [0, plaqueY, apothem + 0.01]
        pedestal.addChild(plaque)

        // Shrink the font for long names so they fit on the plaque.
        let fontSize = CGFloat(clamp(0.6 / (Float(max(title.count, 1)) * 0.56), 0.035, 0.07))
        let font = UIFont(name: "Georgia-Bold", size: fontSize) ?? .boldSystemFont(ofSize: fontSize)
        let textMesh = MeshResource.generateText(title, extrusionDepth: 0.006, font: font,
                                                 containerFrame: CGRect(x: -0.29, y: -fontSize * 0.8, width: 0.58, height: fontSize * 1.6),
                                                 alignment: .center, lineBreakMode: .byTruncatingTail)
        let text = ModelEntity(mesh: textMesh, materials: [GlobeMaterials.engraving])
        text.position = [0, plaqueY, apothem + 0.021]
        pedestal.addChild(text)
        return pedestal
    }

    // MARK: - Miniature

    /// Snowy ground disk filling the glass; its top is at `surfaceY`.
    private static func makeSnowGround() -> ModelEntity {
        let ground = ModelEntity(mesh: .generateCylinder(height: 0.04, radius: GlobeMetrics.snowRingRadius),
                                 materials: [GlobeMaterials.snow])
        ground.name = "SnowGround"
        ground.position.y = surfaceY - 0.02
        return ground
    }

    /// A little procedural village (seeded by the coordinate), used when the real place can't be loaded.
    static func makePlaceholderVillage(for globe: SnowGlobe) -> Entity {
        let diorama = Entity()
        diorama.name = dioramaContentName

        var rng = SeededRandom(coordinate: globe.coordinate)
        var occupied: [(center: SIMD2<Float>, radius: Float)] = []
        func isFree(_ point: SIMD2<Float>, _ radius: Float) -> Bool {
            occupied.allSatisfy { simd_distance($0.center, point) > $0.radius + radius + 0.02 }
        }

        if globe.radiusMeters >= RadiusPreset.landscape.rawValue {
            // Landscape globes get a snowy mountain.
            let peak = SIMD2<Float>(-0.12, -0.1)
            let mountain = ModelEntity(mesh: .generateCone(height: 0.62, radius: 0.5), materials: [GlobeMaterials.rock])
            mountain.position = [peak.x, surfaceY + 0.31, peak.y]
            diorama.addChild(mountain)
            let cap = ModelEntity(mesh: .generateCone(height: 0.22, radius: 0.186), materials: [GlobeMaterials.snow])
            cap.position = [peak.x, surfaceY + 0.62 - 0.11 + 0.003, peak.y]
            diorama.addChild(cap)
            occupied.append((peak, 0.5))
        } else {
            // A cluster of buildings, taller towards the middle, with snow on the roofs.
            for _ in 0..<60 where occupied.count < 14 {
                let angle = rng.nextFloat(in: 0...(2 * .pi))
                let distance = rng.nextUnit().squareRoot() * 0.62
                let point = SIMD2<Float>(cos(angle) * distance, sin(angle) * distance)
                let width = rng.nextFloat(in: 0.08...0.18)
                let depth = rng.nextFloat(in: 0.08...0.18)
                let footprint = max(width, depth) * 0.6
                guard isFree(point, footprint) else { continue }
                let height = rng.nextFloat(in: 0.07...0.2) + (1 - distance / 0.62) * rng.nextFloat(in: 0...0.22)

                let material = GlobeMaterials.walls[Int(rng.next() % UInt64(GlobeMaterials.walls.count))]
                let building = ModelEntity(mesh: .generateBox(width: width, height: height, depth: depth, cornerRadius: 0.006),
                                           materials: [material])
                building.position = [point.x, surfaceY + height / 2, point.y]
                building.orientation = simd_quatf(angle: rng.nextFloat(in: -0.3...0.3), axis: [0, 1, 0])

                let roofSnow = ModelEntity(mesh: .generateBox(width: width + 0.008, height: 0.012, depth: depth + 0.008, cornerRadius: 0.004),
                                           materials: [GlobeMaterials.snow])
                roofSnow.position.y = height / 2 + 0.006
                building.addChild(roofSnow)

                diorama.addChild(building)
                occupied.append((point, footprint))
            }
        }

        // Pine trees scattered around.
        var treeCount = 0
        for _ in 0..<80 where treeCount < 12 {
            let angle = rng.nextFloat(in: 0...(2 * .pi))
            let distance = rng.nextUnit().squareRoot() * 0.74
            let point = SIMD2<Float>(cos(angle) * distance, sin(angle) * distance)
            guard isFree(point, 0.05) else { continue }
            diorama.addChild(makePine(at: SIMD3(point.x, surfaceY, point.y), height: rng.nextFloat(in: 0.11...0.2)))
            occupied.append((point, 0.05))
            treeCount += 1
        }
        // So falling snow settles on the roofs and treetops.
        diorama.components.set(SnowSurfaceComponent(field: .measuring(diorama)))
        return diorama
    }

    private static func makePine(at base: SIMD3<Float>, height h: Float) -> Entity {
        let tree = Entity()
        tree.position = base

        let trunk = ModelEntity(mesh: .generateCylinder(height: h * 0.25, radius: h * 0.07), materials: [GlobeMaterials.bark])
        trunk.position.y = h * 0.125
        tree.addChild(trunk)

        let foliage = ModelEntity(mesh: .generateCone(height: h * 0.8, radius: h * 0.3), materials: [GlobeMaterials.pine])
        foliage.position.y = h * 0.6
        tree.addChild(foliage)

        let cap = ModelEntity(mesh: .generateCone(height: h * 0.26, radius: h * 0.105), materials: [GlobeMaterials.snow])
        cap.position.y = h * 0.87 + 0.002
        tree.addChild(cap)
        return tree
    }

    // MARK: - Glass

    private static func makeGlass() -> Entity {
        // A dome cut off just below the ground line, so the glass never pokes out under the slim base.
        let dome = GlobeMeshes.dome(radius: GlobeMetrics.glassRadius, bottomY: GlobeMetrics.groundY - 0.01)
        let glass = Entity()
        glass.name = "Glass"
        // The same dome twice: its far side (drawn before the snow) and its near side (drawn after).
        for (side, culled, order) in [("Back", MaterialParameterTypes.FaceCulling.front, DrawOrder.glassBack),
                                      ("Front", .back, DrawOrder.glassFront)] {
            var material = GlobeMaterials.glass
            material.faceCulling = culled
            let half = ModelEntity(mesh: dome, materials: [material])
            half.name = "Glass\(side)"
            half.components.set(ModelSortGroupComponent(group: insideGlass, order: order))
            glass.addChild(half)
        }
        return glass
    }
}

/// Shared materials (created once).
@MainActor
enum GlobeMaterials {
    static let wood = pbr(UIColor(red: 0.36, green: 0.22, blue: 0.13, alpha: 1), roughness: 0.4, clearcoat: 0.7)
    static let woodDark = pbr(UIColor(red: 0.24, green: 0.14, blue: 0.08, alpha: 1), roughness: 0.5)
    static let brass = pbr(UIColor(red: 0.89, green: 0.72, blue: 0.42, alpha: 1), roughness: 0.28, metallic: 1)
    static let engraving = pbr(UIColor(red: 0.18, green: 0.11, blue: 0.05, alpha: 1), roughness: 0.6)
    static let snow = pbr(UIColor(red: 0.95, green: 0.97, blue: 1, alpha: 1), roughness: 0.85)
    static let rock = pbr(UIColor(red: 0.42, green: 0.45, blue: 0.52, alpha: 1), roughness: 0.9)
    static let pine = pbr(UIColor(red: 0.11, green: 0.33, blue: 0.24, alpha: 1), roughness: 0.85)
    static let bark = pbr(UIColor(red: 0.36, green: 0.24, blue: 0.16, alpha: 1), roughness: 0.9)

    /// Building wall colours: cream, brick, blue-grey, sandstone.
    static let walls: [PhysicallyBasedMaterial] = [
        pbr(UIColor(red: 0.93, green: 0.88, blue: 0.78, alpha: 1), roughness: 0.8),
        pbr(UIColor(red: 0.72, green: 0.38, blue: 0.32, alpha: 1), roughness: 0.8),
        pbr(UIColor(red: 0.60, green: 0.66, blue: 0.76, alpha: 1), roughness: 0.8),
        pbr(UIColor(red: 0.84, green: 0.71, blue: 0.54, alpha: 1), roughness: 0.8),
    ]

    /// Thin, glossy, mostly transparent glass that still catches highlights.
    static let glass: PhysicallyBasedMaterial = {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(red: 0.9, green: 0.95, blue: 1, alpha: 1))
        material.roughness = 0.04
        material.metallic = 0.0
        material.specular = 0.9
        material.clearcoat = 1.0
        material.clearcoatRoughness = 0.03
        material.blending = .transparent(opacity: 0.16)
        material.faceCulling = .none // see both the near and far side of the glass
        return material
    }()

    static func pbr(_ color: UIColor, roughness: Float, metallic: Float = 0, clearcoat: Float = 0) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: metallic)
        material.clearcoat = .init(floatLiteral: clearcoat)
        return material
    }
}
