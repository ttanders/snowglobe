//
//  SnowglobeApp.swift
//  Snowglobe
//

import SwiftUI

@main
struct SnowglobeApp: App {
    @State private var store = GlobeStore()
    @State private var thumbnails = GlobeThumbnailStore()

    init() {
        Theme.registerFonts()
        SnowSurfaceComponent.registerComponent()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(thumbnails)
                .font(Theme.font(.body))
                .preferredColorScheme(.dark)
                // Render shelf pictures of the real globes in the background (re-runs when globes are
                // added/removed, or a plaque's engraved date changes). Keyed by a dictionary, so just
                // rearranging the shelf doesn't restart it.
                .task(id: Dictionary(uniqueKeysWithValues: store.globes.map { ($0.id, $0.photoDate) })) {
                    await thumbnails.renderMissing(store.globes)
                }
        }
    }
}
