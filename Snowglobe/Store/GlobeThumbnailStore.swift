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
    /// The globes on the shelf, in shelf order, as last passed to `renderMissing`.
    private var shelfGlobes: [SnowGlobe] = []
    /// The one render loop, while it's running. It isn't tied to the caller, so when the shelf is
    /// rearranged (which calls `renderMissing` again) a picture already on its way still finishes.
    private var renderLoop: Task<Void, Never>?

    func image(for id: SnowGlobe.ID) -> UIImage? {
        images[id]
    }

    /// True until the globe's picture is ready or has failed.
    func isLoading(_ id: SnowGlobe.ID) -> Bool {
        images[id] == nil && !failed.contains(id)
    }

    /// Renders every globe that doesn't have a picture yet, one at a time (in shelf order) to keep
    /// network and GPU load low. Call it whenever the globes change; it returns straight away and
    /// the pictures arrive in the background.
    func renderMissing(_ globes: [SnowGlobe]) async {
        // Drop pictures of deleted globes.
        let ids = Set(globes.map(\.id))
        images = images.filter { ids.contains($0.key) }
        attributionsByGlobe = attributionsByGlobe.filter { ids.contains($0.key) }
        failed = failed.filter { ids.contains($0) }
        updateAttributions()

        shelfGlobes = globes
        if renderLoop == nil {
            renderLoop = Task { await self.renderUntilDone() }
        }
    }

    /// Works through the shelf until every globe has been tried, picking up globes added meanwhile.
    private func renderUntilDone() async {
        while let globe = shelfGlobes.first(where: { !attempted.contains($0.id) }) {
            attempted.insert(globe.id)
            await render(globe)
        }
        renderLoop = nil
    }

    private func render(_ globe: SnowGlobe) async {
        let loader = PhotorealDioramaLoader()
        await loader.load(globe)
        // Only real places get a picture; if loading failed, the outline stays.
        guard loader.phase == .ready, loader.showsRealPlace, let content = loader.content else {
            failed.insert(globe.id)
            return
        }

        do {
            let cgImage = try await GlobeThumbnailRenderer.render(globe: globe, content: content)
            // Deleted while it was rendering.
            guard shelfGlobes.contains(where: { $0.id == globe.id }) else { return }
            images[globe.id] = UIImage(cgImage: cgImage, scale: 3, orientation: .up)
            attributionsByGlobe[globe.id] = loader.attributions
            updateAttributions()
        } catch {
            print("GlobeThumbnailStore: couldn't render \(globe.title): \(error)")
            failed.insert(globe.id)
        }
    }

    private func updateAttributions() {
        var seen: Set<String> = []
        attributions = attributionsByGlobe.values.flatMap { $0 }.filter { seen.insert($0).inserted }
    }
}
