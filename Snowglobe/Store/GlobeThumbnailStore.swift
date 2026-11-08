//
//  GlobeThumbnailStore.swift
//  Snowglobe
//
//  Pictures of the real 3D globes for the shelf, rendered in the background after launch.
//
//  Kept in memory only: the pictures are made from Google's Photorealistic 3D Tiles, and
//  Google's terms don't allow storing that content long-term. So they're re-rendered each launch,
//  and the drawn globe (GlobeIllustration) shows until a picture is ready.
//

import Foundation
import Observation
import UIKit

@MainActor @Observable
final class GlobeThumbnailStore {
    private(set) var images: [SnowGlobe.ID: UIImage] = [:]
    /// Data credits for the pictures on screen; Google requires these to stay visible with its content.
    private(set) var attributions: [String] = []

    /// Globes already rendered or attempted this session (failures fall back to the drawing).
    private var attempted: Set<SnowGlobe.ID> = []
    private var attributionsByGlobe: [SnowGlobe.ID: [String]] = [:]

    func image(for id: SnowGlobe.ID) -> UIImage? {
        images[id]
    }

    /// Renders every globe that doesn't have a picture yet, one at a time to keep network and GPU load low.
    func renderMissing(_ globes: [SnowGlobe]) async {
        // Drop pictures of deleted globes.
        let ids = Set(globes.map(\.id))
        images = images.filter { ids.contains($0.key) }
        attributionsByGlobe = attributionsByGlobe.filter { ids.contains($0.key) }
        updateAttributions()

        for globe in globes where !attempted.contains(globe.id) {
            if Task.isCancelled { return }
            attempted.insert(globe.id)

            let loader = PhotorealDioramaLoader()
            await loader.load(globe)
            // Only real places get a picture; if loading failed, keep the drawing.
            guard loader.phase == .ready, loader.showsRealPlace, let content = loader.content else { continue }

            do {
                let cgImage = try await GlobeThumbnailRenderer.render(globe: globe, content: content)
                images[globe.id] = UIImage(cgImage: cgImage, scale: 3, orientation: .up)
                attributionsByGlobe[globe.id] = loader.attributions
                updateAttributions()
            } catch {
                print("GlobeThumbnailStore: couldn't render \(globe.title): \(error)")
            }
        }
    }

    private func updateAttributions() {
        var seen: Set<String> = []
        attributions = attributionsByGlobe.values.flatMap { $0 }.filter { seen.insert($0).inserted }
    }
}
