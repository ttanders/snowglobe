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
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(thumbnails)
                .font(Theme.font(.body))
                .preferredColorScheme(.dark)
                // Render shelf pictures of the real globes in the background (re-runs when globes are added/removed).
                .task(id: store.globes.map(\.id)) {
                    await thumbnails.renderMissing(store.globes)
                }
        }
    }
}
