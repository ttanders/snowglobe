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
    @State private var showingAR = false
    /// Size slider position while a new globe's size is being chosen: log2 of the zoom (0 = starting size).
    @State private var zoomLog2: Double = 0
    /// Presses of the Shake button.
    @State private var shakeRequests = 0
    /// Set the first time the user shakes the iPhone or taps a globe; until then the hint teaches it.
    @AppStorage("hasStirredSnow") private var hasStirredSnow = false

    var body: some View {
        ZStack {
            Color(uiColor: Theme.sceneBackground).ignoresSafeArea()

            if let globe = store.globe(id: globeID) {
                // Only one 3D view at a time: this one shuts down while AR is open.
                if !showingAR {
                    GlobeSceneView(globe: globe, dioramaContent: loader.content, shakeRequests: shakeRequests) {
                        if !hasStirredSnow {
                            withAnimation(.easeInOut) { hasStirredSnow = true }
                        }
                    }
                    .ignoresSafeArea()
                }

                VStack(spacing: 12) {
                    header(for: globe)
                    Spacer()
                    status(for: globe)
                    if !globe.isSizeLocked {
                        sizeChooser(for: globe)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    HStack(spacing: 12) {
                        Button {
                            shakeRequests += 1
                        } label: {
                            Label("Shake", systemImage: "wind.snow")
                                .font(Theme.font(.headline, weight: .semibold))
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.glass)
                        .accessibilityHint("Makes it snow inside the globe.")
                        Button {
                            showingAR = true
                        } label: {
                            Label("View in AR", systemImage: "arkit")
                                .font(Theme.font(.headline, weight: .semibold))
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(loader.content == nil)
                    }
                    if globe.isSizeLocked && !hasStirredSnow {
                        snowHint
                            .transition(.opacity)
                    }
                    credits
                }
                .padding()
            } else {
                ContentUnavailableView("Globe not found", systemImage: "snowflake")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: LoadRequest(zoomLog2: zoomLog2, isSizeLocked: store.globe(id: globeID)?.isSizeLocked ?? true)) {
            guard let globe = store.globe(id: globeID) else { return }
            if loader.content != nil {
                // A zoom change (or locking): wait for the slider to settle before re-cutting the place.
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            await loader.load(globe, zoom: exp2(zoomLog2))
        }
        .onDisappear {
            // The size is chosen only on the first visit: leaving after the place has shown locks it in.
            guard !showingAR, let globe = store.globe(id: globeID) else { return }
            if !globe.isSizeLocked, loader.showsRealPlace {
                lockSize(of: globe)
            }
            if let globe = store.globe(id: globeID) {
                loader.finishLocking(globe)
            }
        }
        .fullScreenCover(isPresented: $showingAR) {
            if let globe = store.globe(id: globeID) {
                ARGlobeView(globe: globe, content: loader.content, attributions: loader.attributions)
            }
        }
    }

    private func header(for globe: SnowGlobe) -> some View {
        VStack(spacing: 4) {
            Text(globe.title)
                .font(Theme.titleFont(30))
                .foregroundStyle(Theme.snow)
                .multilineTextAlignment(.center)
            if let subtitle = globe.subtitle {
                Text(subtitle)
                    .font(Theme.font(.subheadline))
                    .foregroundStyle(Theme.ice)
            }
            Text(globe.coordinate.formatted)
                .font(Theme.font(.caption).monospacedDigit())
                .foregroundStyle(.secondary)
            if let photoDate = globe.photoDate {
                Label("Photo taken \(photoDate.formatted(date: .long, time: .omitted))", systemImage: "camera")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
    }

    /// Teaches making it snow; gone for good once the user has done it themselves.
    private var snowHint: some View {
        Text("Shake your iPhone or tap the glass to make it snow")
            .font(Theme.font(.footnote))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect()
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func status(for globe: SnowGlobe) -> some View {
        switch loader.phase {
        case .loading(let message, let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .tint(Theme.accent)
                Text(message)
                    .font(Theme.font(.footnote))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: 280)
            .glassEffect(in: .rect(cornerRadius: 18))
        case .failed(let message):
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Theme.font(.footnote))
                Button("Try Again") {
                    Task { await loader.load(globe, zoom: exp2(zoomLog2)) }
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

    // MARK: - Choosing the size (first visit only)

    private struct LoadRequest: Hashable {
        var zoomLog2: Double
        var isSizeLocked: Bool
    }

    private func lockSize(of globe: SnowGlobe) {
        let radius = GlobeSizing.radius(baseRadius: globe.radiusMeters, zoom: exp2(zoomLog2))
        withAnimation {
            store.lockSize(id: globe.id, radiusMeters: radius)
        }
    }

    /// Slider that zooms the place inside the glass (more of it, smaller ↔ less of it, bigger)
    /// and a button that locks that size in for good.
    private func sizeChooser(for globe: SnowGlobe) -> some View {
        let zoom = Binding<Double>(
            get: { zoomLog2 },
            // Snap to the starting size, so it's easy to get back to.
            set: { zoomLog2 = abs($0) < 0.15 ? 0 : $0 }
        )
        let across = Self.distanceText(2 * GlobeSizing.radius(baseRadius: globe.radiusMeters, zoom: exp2(zoomLog2)))
        return VStack(spacing: 6) {
            Text("How much should fit inside?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.snow)
            HStack(spacing: 12) {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: zoom, in: GlobeSizing.log2Range)
                    .tint(Theme.ice)
                    .accessibilityLabel("Size")
                    .accessibilityValue("\(across) across")
                Image(systemName: "plus.magnifyingglass")
            }
            .foregroundStyle(Theme.snow)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("\(across) across")
                            .font(.caption.monospacedDigit())
                            .contentTransition(.numericText())
                        if loader.isRebuilding {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    Text("You can only choose once")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                Button {
                    lockSize(of: globe)
                } label: {
                    Label("Lock In Size", systemImage: "lock.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .accessibilityHint("You can only choose the size once.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 340)
        .glassEffect(in: .rect(cornerRadius: 22))
        .disabled(!loader.showsRealPlace)
        .opacity(loader.showsRealPlace ? 1 : 0.6)
        .sensoryFeedback(.selection, trigger: zoomLog2 == 0) { _, isAtStartingSize in isAtStartingSize }
    }

    /// "85 m", "600 m", "1.2 km".
    private static func distanceText(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: meters >= 10_000 ? "%.0f km" : "%.1f km", meters / 1000)
        }
        let step: Double = meters < 100 ? 5 : 10
        return "\(Int((meters / step).rounded() * step)) m"
    }

    /// Google requires its name and the data credits to be visible with the 3D content.
    @ViewBuilder
    private var credits: some View {
        if !loader.attributions.isEmpty {
            let others = loader.attributions.filter { $0 != "Google" }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Google Maps")
                    .font(Theme.font(.caption, weight: .semibold))
                if !others.isEmpty {
                    Text(others.joined(separator: " · "))
                        .font(Theme.font(.caption2))
                        .lineLimit(2)
                }
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
        }
    }
}
