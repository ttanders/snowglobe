//
//  GlobeMetrics.swift
//  Snowglobe
//
//  CORE CONTRACT — the physical layout of a snowglobe, in "globe units".
//
//  Globe-local space (used by every RealityKit entity inside a globe):
//    • origin = centre of the glass sphere, glass radius = 1
//    • +Y = up, +X = east, -Z = north   (so a default camera on +Z looks "north")
//    • the root entity is scaled to physical size only in AR (see `arGlassRadiusMeters`)
//
//            .-""""-.        ← glass dome (sphere radius 1, cut off at groundY)
//          /  snow    \
//         |  ▟▙  ▟█▙   |     ← diorama disk (radius 0.8) sitting at groundY
//   ------+------------+---- groundY = -0.40 (top of the pedestal)
//         |  pedestal  |     octagonal, circumradius `baseRadius`
//         +------------+     baseBottomY = -0.77
//

import CoreGraphics
import simd

enum GlobeMetrics {
    /// Radius of the glass sphere.
    static let glassRadius: Float = 1.0
    /// Y of the lowest ground level of the diorama (= top face of the pedestal).
    static let groundY: Float = -0.40
    /// Radius of the circular diorama (the cut-out piece of the world).
    static let dioramaRadius: Float = 0.80
    /// Where the glass meets the ground plane is sqrt(1 - groundY²) ≈ 0.9165.
    /// A snowy ring fills the gap between `dioramaRadius` and this radius.
    static let snowRingRadius: Float = 0.912
    /// Snow flakes are kept inside this radius (glass thickness + flake size).
    static let snowContainmentRadius: Float = 0.955
    /// Pedestal: an octagonal prism from `groundY` down to `baseBottomY`, flat face toward +Z.
    /// Circumradius just big enough that its flat faces (apothem ≈ 0.94) cover where the glass meets the wood.
    static let baseRadius: Float = 1.02
    static let baseBottomY: Float = -0.77
    /// Vertical exaggeration so buildings / hills read well at miniature scale.
    static let buildingExaggeration: Float = 1.6
    static let terrainExaggeration: Float = 1.6
    /// Content may rise to at most this fraction of the dome height at a given radius.
    static let domeClearance: Float = 0.88
    /// Size of the glass radius when the globe is placed in AR (meters) → ~20 cm tall globe.
    static let arGlassRadiusMeters: Float = 0.09
    /// Default number of snow flakes in a globe.
    static let snowFlakeCount: Int = 320

    /// RealityKit samples textures made from a CGImage with v = 0 at the BOTTOM row of the image
    /// (USD convention). If ground imagery ever appears mirrored north/south, flip this one flag.
    static let textureOriginIsBottomLeft = true

    /// Highest Y that content may reach at horizontal distance `rho` from the vertical axis
    /// while staying comfortably inside the dome.
    static func maxContentY(atRadius rho: Float) -> Float {
        let r = min(abs(rho), glassRadius * 0.999)
        return (glassRadius * glassRadius - r * r).squareRoot() * domeClearance
    }

    /// Horizontal scale from real-world meters to globe units for a globe of the given real-world radius.
    static func unitsPerMeter(radiusMeters: Double) -> Float {
        dioramaRadius / Float(max(radiusMeters, 1))
    }

    /// Maps local (east, north) meters to globe-local (x, z): x = east, z = -north.
    static func globeXZ(east: Float, north: Float, unitsPerMeter: Float) -> SIMD2<Float> {
        SIMD2(east * unitsPerMeter, -north * unitsPerMeter)
    }

    /// UV into the ground image for a local position in meters.
    /// The ground image covers [-r, r]² meters with north at the top row and west at the left column.
    static func groundUV(east: Float, north: Float, radiusMeters: Float) -> SIMD2<Float> {
        let u = (east + radiusMeters) / (2 * radiusMeters)
        let vFromTop = (radiusMeters - north) / (2 * radiusMeters) // 0 at the north (top) edge
        return SIMD2(u, textureOriginIsBottomLeft ? 1 - vFromTop : vFromTop)
    }

    /// Thumbnail framing contract shared by GlobeThumbnailRenderer (producer) and the shelf UI (consumer).
    /// All values are fractions of the square thumbnail's side length.
    enum Thumbnail {
        /// Rendered size in pixels. Same aspect ratio as the shelf's drawn globe (`GlobeIllustration`)
        /// so the picture can replace the drawing without the shelf layout shifting.
        static let pixelSize = CGSize(width: 810, height: 750)
        /// Approximate centre of the glass sphere's silhouette in the image (origin top-left).
        static let glassCenter = CGPoint(x: 0.5, y: 0.40)
        /// Approximate radius of the glass sphere's silhouette.
        static let glassRadius: CGFloat = 0.34
        /// Approximate y of the bottom of the pedestal (where it touches the shelf).
        static let baseBottom: CGFloat = 0.94
    }
}
