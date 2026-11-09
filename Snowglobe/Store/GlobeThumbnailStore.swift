//
//  GlobeThumbnailStore.swift
//  Snowglobe
//
//  Pictures of the real 3D globes for the shelf, rendered in the background after launch.
//
//  Kept in memory only: the pictures are made from Google's Photorealistic 3D Tiles, and
//  Google's terms don't allow storing that content long-term. So they're re-rendered each launch,
//  and a pulsing outline of a globe (GlobeOutlinePlaceholder) shows until a picture is ready.
//

import Foundation
import Observation
import UIKit

@MainActor @Observable
final class GlobeThumbnailStore {
    private(set) var images: [SnowGlobe.ID: UIImage] = [:]
    /// Data credits for the pictures on screen; Google requires these to stay visible with its content.
    private(set) var attributions: [String] = []

    /// Globes already rendered or attempted this session.
    private var attempted: Set<SnowGlobe.ID> = []
    /// Globes whose picture couldn't be made this session (their outline stops pulsing).
    private(set) var failed: Set<SnowGlobe.ID> = []
    private var attributionsByGlobe: [SnowGlobe.ID: [String]] = [:]

    func image(for id: SnowGlobe.ID) -> UIImage? {
        images[id]
    }

    /// Re-renders a globe's picture on the next pass (e.g. after its plaque changed).
    /// The old picture stays on the shelf until the new one is ready.
    func refresh(_ id: SnowGlobe.ID) {
        attempted.remove(id)
        failed.remove(id)
    }

    /// True until the globe's picture is ready or has failed.
    func isLoading(_ id: SnowGlobe.ID) -> Bool {
        images[id] == nil && !failed.contains(id)
    }

    /// Renders every globe that doesn't have a picture yet, one at a time to keep network and GPU load low.
    func renderMissing(_ globes: [SnowGlobe]) async {
        // Drop pictures of deleted globes.
        let ids = Set(globes.map(\.id))
        images = images.filter { ids.contains($0.key) }
        attributionsByGlobe = attributionsByGlobe.filter { ids.contains($0.key) }
        failed = failed.filter { ids.contains($0) }
        updateAttributions()

        for globe in globes where !attempted.contains(globe.id) {
            if Task.isCancelled { return }
            attempted.insert(globe.id)

            let loader = PhotorealDioramaLoader()
            await loader.load(globe)
            // Interrupted (the globe list changed and this pass was restarted): not a failure.
            // Leave it un-attempted so the next pass picks it up again.
            if Task.isCancelled {
                attempted.remove(globe.id)
                return
            }
            // Only real places get a picture; if loading failed, the outline stays.
            guard loader.phase == .ready, loader.showsRealPlace, let content = loader.content else {
                failed.insert(globe.id)
                continue
            }

            do {
                let cgImage = try await GlobeThumbnailRenderer.render(globe: globe, content: content)
                images[globe.id] = UIImage(cgImage: cgImage, scale: 3, orientation: .up)
                attributionsByGlobe[globe.id] = loader.attributions
                updateAttributions()
            } catch {
                if Task.isCancelled {
                    attempted.remove(globe.id)
                    return
                }
                print("GlobeThumbnailStore: couldn't render \(globe.title): \(error)")
                failed.insert(globe.id)
            }
        }
    }

    private func updateAttributions() {
        var seen: Set<String> = []
        attributions = attributionsByGlobe.values.flatMap { $0 }.filter { seen.insert($0).inserted }
    }
}
