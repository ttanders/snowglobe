//
//  GlobeDetailView.swift
//  Snowglobe
//
//  One globe, full screen, in live 3D.
//

import SwiftUI

struct GlobeDetailView: View {
    let globeID: SnowGlobe.ID

    @Environment(GlobeStore.self) private var store

    var body: some View {
        ZStack {
            Color(uiColor: Theme.sceneBackground).ignoresSafeArea()

            if let globe = store.globe(id: globeID) {
                GlobeSceneView(globe: globe)
                    .ignoresSafeArea()

                VStack {
                    header(for: globe)
                    Spacer()
                    Text("Drag to spin · Pinch to zoom · Double-tap to reset")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect()
                }
                .padding()
            } else {
                ContentUnavailableView("Globe not found", systemImage: "snowflake")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func header(for globe: SnowGlobe) -> some View {
        VStack(spacing: 4) {
            Text(globe.title)
                .font(Theme.titleFont(30))
                .foregroundStyle(Theme.snow)
                .multilineTextAlignment(.center)
            if let subtitle = globe.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ice)
            }
            Text(globe.coordinate.formatted)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
    }
}
