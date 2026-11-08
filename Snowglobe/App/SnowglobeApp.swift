//
//  SnowglobeApp.swift
//  Snowglobe
//

import SwiftUI

@main
struct SnowglobeApp: App {
    @State private var store = GlobeStore()

    var body: some Scene {
        WindowGroup {
            ShelfView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}
