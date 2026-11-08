//
//  GlobeThumbnailRenderer.swift
//  Snowglobe
//
//  Renders a globe offscreen (RealityRenderer → Metal texture → CGImage) for the shelf,
//  with the same lights and environment as the live detail view.
//

import RealityKit
import Metal
import UIKit

@MainActor
enum GlobeThumbnailRenderer {
    enum RenderError: Error {
        case noMetalDevice
        case textureCreationFailed
        case imageCreationFailed
    }

    private enum Framing {
        /// What the camera looks at: roughly halfway between the glass top and the pedestal bottom.
        static let target = SIMD3<Float>(0, 0.075, 0)
        static let pitch: Float = 0.15           // radians above the horizon
        static let distance: Float = 4.8
        static let horizontalFieldOfView: Float = 30
        /// The render is taller than the final picture so nothing gets clipped; it's then cropped
        /// so the bottom of the pedestal lands exactly on the picture's bottom edge (on the shelf).
        static let renderHeightFactor: CGFloat = 1.35
    }

    /// Renders `globe` with `content` standing inside the glass.
    static func render(globe: SnowGlobe, content: Entity) async throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noMetalDevice }
        let width = Int(GlobeMetrics.Thumbnail.pixelSize.width)
        let height = Int(GlobeMetrics.Thumbnail.pixelSize.height * Framing.renderHeightFactor)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.textureCreationFailed }

        let renderer = try RealityRenderer()
        renderer.cameraSettings.colorBackground = .color(UIColor.clear.cgColor)
        renderer.cameraSettings.antialiasing = .multisample4X
        if let environment = GlobeLighting.environment {
            renderer.lighting.resource = environment
        }

        let root = Entity()
        root.addChild(GlobeEntityFactory.makeGlobe(for: globe, content: content))
        GlobeLighting.addLights(to: root)

        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = Framing.horizontalFieldOfView
        camera.camera.fieldOfViewOrientation = .horizontal
        root.addChild(camera)
        let offset = SIMD3<Float>(0, sin(Framing.pitch), cos(Framing.pitch)) * Framing.distance
        camera.look(at: Framing.target, from: Framing.target + offset, relativeTo: root)

        renderer.entities.append(root)
        renderer.activeCamera = camera

        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        // A couple of frames lets materials and shadows settle before we keep the last one.
        for _ in 0..<3 {
            try await renderFrame(renderer, output: output)
        }
        renderer.entities.removeAll()

        let pixels = readPixels(texture)
        let rendered = try makeImage(pixels: pixels, width: texture.width, height: texture.height)
        return cropStandingOnBottomEdge(rendered, pixels: pixels)
    }

    private static func renderFrame(_ renderer: RealityRenderer, output: RealityRenderer.CameraOutput) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try renderer.updateAndRender(deltaTime: 1.0 / 30.0, cameraOutput: output,
                                             onComplete: { _ in continuation.resume() })
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Copies the BGRA texture's pixels out (rows top to bottom, 4 bytes per pixel).
    private static func readPixels(_ texture: any MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return pixels
    }

    /// Wraps BGRA pixels in a CGImage (premultiplied alpha, so the background stays transparent).
    private static func makeImage(pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        var pixels = pixels
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo),
              let image = context.makeImage()
        else { throw RenderError.imageCreationFailed }
        return image
    }

    /// Crops to the final picture size so the lowest solid row (bottom of the pedestal) is the last row.
    private static func cropStandingOnBottomEdge(_ image: CGImage, pixels: [UInt8]) -> CGImage {
        let finalHeight = Int(GlobeMetrics.Thumbnail.pixelSize.height)
        let bytesPerRow = image.width * 4
        var contentBottom = image.height - 1
        // BGRA: alpha is byte 3. Scan up from the bottom for the first row with solid pixels.
        search: for row in stride(from: image.height - 1, through: 0, by: -1) {
            let start = row * bytesPerRow
            for x in stride(from: 3, to: bytesPerRow, by: 4) where pixels[start + x] > 128 {
                contentBottom = row
                break search
            }
        }
        let top = max(0, min(contentBottom + 1 - finalHeight, image.height - finalHeight))
        return image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: finalHeight)) ?? image
    }
}
