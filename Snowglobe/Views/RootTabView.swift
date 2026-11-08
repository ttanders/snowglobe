//
//  RootTabView.swift
//  Snowglobe
//
//  Top-level pages in a Liquid Glass tab bar (like Photos): Home shows every globe,
//  Favorites shows the ones you've double-tapped.
//

import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "snowflake") {
                ShelfView()
            }
            Tab("Favorites", systemImage: "heart.fill") {
                ShelfView(title: "Favorites", subtitle: "The globes you love most", favoritesOnly: true)
            }
        }
        .tint(Theme.accent)
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

#Preview {
    RootTabView()
        .environment(GlobeStore())
        .environment(GlobeThumbnailStore())
}
