//
//  GlobeLighting.swift
//  Snowglobe
//
//  Studio lights + a soft winter-night environment (image-based lighting) for showing a globe.
//

import RealityKit
import UIKit

@MainActor
enum GlobeLighting {
    /// Adds a warm shadow-casting key light, a cool fill and a blue rim light under `root`, aimed at the globe.
    static func addLights(to root: Entity) {
        let key = DirectionalLight()
        key.name = "Light.Key"
        key.light.color = UIColor(red: 1, green: 0.93, blue: 0.82, alpha: 1)
        key.light.intensity = 3200
        key.shadow = DirectionalLightComponent.Shadow(maximumDistance: 6, depthBias: 2)
        root.addChild(key)
        key.look(at: [0, -0.2, 0], from: [2.2, 3.6, 3.0], relativeTo: root)

        let fill = DirectionalLight()
        fill.name = "Light.Fill"
        fill.light.color = UIColor(red: 0.7, green: 0.8, blue: 1, alpha: 1)
        fill.light.intensity = 900
        root.addChild(fill)
        fill.look(at: .zero, from: [-3, 1.2, 2], relativeTo: root)

        let rim = DirectionalLight()
        rim.name = "Light.Rim"
        rim.light.color = UIColor(red: 0.6, green: 0.75, blue: 1, alpha: 1)
        rim.light.intensity = 1400
        root.addChild(rim)
        rim.look(at: .zero, from: [0, 2.5, -3], relativeTo: root)
    }

    /// Soft blue night sky with a glowing horizon, used for reflections on the glass. Generated once.
    static let environment: EnvironmentResource? = {
        guard let sky = makeSkyImage() else { return nil }
        return try? EnvironmentResource(equirectangular: sky)
    }()

    private static func makeSkyImage() -> CGImage? {
        let size = CGSize(width: 256, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let colors = [
            UIColor(red: 0.10, green: 0.14, blue: 0.30, alpha: 1).cgColor, // zenith
            UIColor(red: 0.50, green: 0.58, blue: 0.78, alpha: 1).cgColor, // horizon glow
            UIColor(red: 0.20, green: 0.16, blue: 0.14, alpha: 1).cgColor, // floor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) else {
            return nil
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }.cgImage
    }
}
