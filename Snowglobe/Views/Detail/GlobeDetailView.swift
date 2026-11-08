//
//  GlobeDetailView.swift
//  Snowglobe
//
//  One globe, full screen, in live 3D. The real place inside the glass comes from
//  Google's Photorealistic 3D Tiles (see PhotorealDioramaLoader).
//

import SwiftUI

struct GlobeDetailView: View {
    let globeID: SnowGlobe.ID

    @Environment(GlobeStore.self) private var store
    @State private var loader = PhotorealDioramaLoader()

    var body: some View {
        ZStack {
            Color(uiColor: Theme.sceneBackground).ignoresSafeArea()

            if let globe = store.globe(id: globeID) {
                GlobeSceneView(globe: globe, dioramaContent: loader.content)
                    .ignoresSafeArea()
                    .task(id: globe.id) { await loader.load(globe) }

                VStack(spacing: 12) {
                    header(for: globe)
                    Spacer()
                    status(for: globe)
                    Text("Drag to spin · Pinch to zoom · Double-tap to reset")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect()
                    credits
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

    @ViewBuilder
    private func status(for globe: SnowGlobe) -> some View {
        switch loader.phase {
        case .loading(let message, let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .tint(Theme.ice)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: 280)
            .glassEffect(in: .rect(cornerRadius: 18))
        case .failed(let message):
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                Button("Try Again") {
                    Task { await loader.load(globe) }
                }
                .buttonStyle(.glass)
            }
            .padding(14)
            .frame(maxWidth: 320)
            .glassEffect(in: .rect(cornerRadius: 18))
        case .idle, .ready:
            EmptyView()
        }
    }

    /// Google requires its name and the data credits to be visible with the 3D content.
    @ViewBuilder
    private var credits: some View {
        if !loader.attributions.isEmpty {
            let others = loader.attributions.filter { $0 != "Google" }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Google Maps")
                    .font(.caption.weight(.semibold))
                if !others.isEmpty {
                    Text(others.joined(separator: " · "))
                        .font(.caption2)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
        }
    }
}
