//
//  ShelfView.swift
//  Snowglobe
//
//  A page of snowglobes standing on frosted shelves, two per shelf.
//  Used for both the Home tab (every globe) and the Favorites tab.
//

import PhotosUI
import SwiftUI

struct ShelfView: View {
    var title = "Snowglobes"
    var subtitle = "Places you've been, under glass"
    /// When true, only favorited globes are shown.
    var favoritesOnly = false

    @Environment(GlobeStore.self) private var store
    @Environment(GlobeThumbnailStore.self) private var thumbnails
    @Namespace private var zoomNamespace
    @State private var path: [SnowGlobe.ID] = []
    @State private var renameTarget: SnowGlobe?
    @State private var renameText = ""
    /// The photo picked with the Import Photo button; non-nil while its sheet is open.
    @State private var importedPhoto: PhotosPickerItem?
    /// A globe just made from a photo, opened once the import sheet has closed.
    @State private var globeToOpen: SnowGlobe.ID?

    private let globesPerShelf = 2
    private let columnSpacing: CGFloat = 18

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 34) {
                    header
                    if favoritesOnly && visibleGlobes.isEmpty {
                        emptyFavoritesHint
                    }
                    ForEach(Array(shelves.enumerated()), id: \.offset) { index, row in
                        shelf(row, index: index)
                    }
                    googleCredits
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background {
                ZStack {
                    Theme.nightGradient
                    FallingSnowView()
                }
                .ignoresSafeArea()
            }
            .navigationDestination(for: SnowGlobe.ID.self) { id in
                GlobeDetailView(globeID: id)
                    .navigationTransition(.zoom(sourceID: id, in: zoomNamespace))
            }
            .alert("Rename Snowglobe", isPresented: isRenaming) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let target = renameTarget { store.rename(id: target.id, to: renameText) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // `.current` hands over the original file so its location and date metadata survive.
                    PhotosPicker(selection: $importedPhoto, matching: .images, preferredItemEncoding: .current) {
                        Label("Import Photo", systemImage: "photo.badge.plus")
                    }
                }
            }
            .sheet(isPresented: isImporting, onDismiss: openNewGlobe) {
                if let importedPhoto {
                    PhotoImportSheet(item: importedPhoto) { globe in
                        store.add(globe)
                        globeToOpen = globe.id
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.titleFont(40))
                .foregroundStyle(Theme.snow)
            Text(subtitle)
                .font(Theme.font(.subheadline))
                .foregroundStyle(Theme.ice)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    private var emptyFavoritesHint: some View {
        Label("Double-tap a snowglobe on Home to add it here", systemImage: "heart")
            .font(Theme.font(.footnote, weight: .medium))
            .foregroundStyle(Theme.ice.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Google requires its name and the data credits to be visible wherever its 3D content appears.
    @ViewBuilder
    private var googleCredits: some View {
        let showsGoogleContent = visibleGlobes.contains { thumbnails.image(for: $0.id) != nil }
        if showsGoogleContent {
            let others = thumbnails.attributions.filter { $0 != "Google" }
            VStack(alignment: .leading, spacing: 2) {
                Text("Google Maps")
                    .font(Theme.font(.caption, weight: .semibold))
                if !others.isEmpty {
                    Text(others.joined(separator: " · "))
                        .font(Theme.font(.caption2))
                        .lineLimit(3)
                }
            }
            .foregroundStyle(Theme.ice.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var visibleGlobes: [SnowGlobe] {
        favoritesOnly ? store.globes.filter(\.isFavorite) : store.globes
    }

    /// Globes chunked into shelves; always at least two shelves so an empty shelf still looks like one.
    private var shelves: [[SnowGlobe]] {
        let globes = visibleGlobes
        var rows = stride(from: 0, to: globes.count, by: globesPerShelf).map {
            Array(globes[$0..<min($0 + globesPerShelf, globes.count)])
        }
        while rows.count < 2 { rows.append([]) }
        return rows
    }

    private func shelf(_ row: [SnowGlobe], index: Int) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: columnSpacing) {
                ForEach(0..<globesPerShelf, id: \.self) { slot in
                    if slot < row.count {
                        globeTile(row[slot])
                    } else {
                        Color.clear
                            .aspectRatio(GlobeIllustration.aspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 10)
            .offset(y: 11) // stand the pedestals on the plank's top surface, not its back edge
            .zIndex(1)

            ShelfPlank(titles: row.map(\.title), columns: globesPerShelf, columnSpacing: columnSpacing,
                       grainSeed: UInt64(index + 1))
        }
    }

    private func globeTile(_ globe: SnowGlobe) -> some View {
        GlobeTile(
            globe: globe,
            renderedImage: thumbnails.image(for: globe.id),
            onOpen: { path.append(globe.id) },
            onToggleFavorite: { store.toggleFavorite(id: globe.id) }
        )
        .matchedTransitionSource(id: globe.id, in: zoomNamespace)
        .frame(maxWidth: .infinity)
        .contextMenu {
            Button(globe.isFavorite ? "Unfavorite" : "Favorite",
                   systemImage: globe.isFavorite ? "heart.slash" : "heart") {
                store.toggleFavorite(id: globe.id)
            }
            Button("Rename", systemImage: "pencil") {
                renameText = globe.title
                renameTarget = globe
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                store.delete(id: globe.id)
            }
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var isImporting: Binding<Bool> {
        Binding(get: { importedPhoto != nil }, set: { if !$0 { importedPhoto = nil } })
    }

    private func openNewGlobe() {
        guard let id = globeToOpen else { return }
        globeToOpen = nil
        path.append(id)
    }
}

/// One globe on the shelf. Tap opens it; double-tap toggles favorite with a heart pop.
private struct GlobeTile: View {
    let globe: SnowGlobe
    /// Picture of the real 3D globe; until it's ready, the drawn globe shows instead.
    let renderedImage: UIImage?
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void

    /// Bumped each time the globe becomes a favorite, to replay the heart pop.
    @State private var heartPop = 0

    var body: some View {
        ZStack {
            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .aspectRatio(GlobeIllustration.aspectRatio, contentMode: .fit)
                    .transition(.opacity)
            } else {
                GlobeIllustration(globe: globe)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: renderedImage != nil)
        .background { contactShadow }
        .overlay(alignment: .topTrailing) {
            if globe.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.heart)
                    .padding(7)
                    .glassEffect(.regular, in: .circle)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay { heartPopView }
        .contentShape(Rectangle())
        // Double-tap is declared first so a single tap waits to rule it out.
        .onTapGesture(count: 2) { toggleFavorite() }
        .onTapGesture { onOpen() }
        .sensoryFeedback(.impact(weight: .light), trigger: globe.isFavorite)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(globe.title) snowglobe")
        .accessibilityValue(globe.isFavorite ? "Favorite" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityAction(named: globe.isFavorite ? "Unfavorite" : "Favorite") { toggleFavorite() }
    }

    /// Soft shadow on the plank under the pedestal so the globe looks like it's resting on the wood.
    private var contactShadow: some View {
        GeometryReader { geo in
            Ellipse()
                .fill(.black.opacity(0.6))
                .frame(width: geo.size.width * 0.8, height: 10)
                .blur(radius: 5)
                .position(x: geo.size.width / 2, y: geo.size.height - 1)
        }
        .allowsHitTesting(false)
    }

    /// Big heart that springs up in the middle of the glass and fades away.
    private var heartPopView: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 64))
            .foregroundStyle(Theme.heart)
            .shadow(color: Theme.heart.opacity(0.4), radius: 10)
            .keyframeAnimator(initialValue: HeartPop(), trigger: heartPop) { content, value in
                content
                    .scaleEffect(value.scale)
                    .opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.15, duration: 0.25, spring: .bouncy)
                    CubicKeyframe(1.0, duration: 0.15)
                    CubicKeyframe(1.0, duration: 0.3)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.1)
                    LinearKeyframe(1, duration: 0.4)
                    LinearKeyframe(0, duration: 0.2)
                }
            }
            .allowsHitTesting(false)
    }

    private func toggleFavorite() {
        let becomingFavorite = !globe.isFavorite
        withAnimation(.spring(duration: 0.3)) { onToggleFavorite() }
        if becomingFavorite { heartPop += 1 }
    }
}

private struct HeartPop {
    var scale: CGFloat = 0.3
    var opacity: Double = 0
}

/// A spruce plank: lit top surface, shaded front edge with name labels, both with wood grain.
private struct ShelfPlank: View {
    let titles: [String]
    let columns: Int
    let columnSpacing: CGFloat
    /// Varies the grain pattern from shelf to shelf.
    let grainSeed: UInt64

    var body: some View {
        VStack(spacing: 0) {
            // Top surface, seen at a shallow angle: lighter, with a soft back-to-front shade.
            ZStack {
                LinearGradient(colors: [Theme.spruce, Theme.spruceLight], startPoint: .top, endPoint: .bottom)
                WoodGrain(seed: grainSeed, lineCount: 5, knots: false)
            }
            .frame(height: 14)

            // Bevelled lip where the light catches the front corner.
            LinearGradient(colors: [Theme.spruceLight.mix(with: .white, by: 0.25), Theme.spruce],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 2)

            // Front face, in shadow.
            ZStack {
                LinearGradient(colors: [Theme.spruce, Theme.spruceDark], startPoint: .top, endPoint: .bottom)
                WoodGrain(seed: grainSeed &+ 101, lineCount: 9, knots: true)
                HStack(spacing: columnSpacing) {
                    ForEach(0..<columns, id: \.self) { index in
                        Text(index < titles.count ? titles[index] : " ")
                            .font(Theme.font(.caption, weight: .semibold))
                            .foregroundStyle(Theme.shelfLabel)
                            .shadow(color: .black.opacity(0.45), radius: 0, y: 1)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 26)

            // Darker underside edge.
            Theme.spruceGrain
                .frame(height: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
    }
}

/// Long, gently wavy grain lines plus the odd knot, drawn deterministically from `seed`.
private struct WoodGrain: View {
    let seed: UInt64
    let lineCount: Int
    let knots: Bool

    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: seed)

            for _ in 0..<lineCount {
                let baseY = CGFloat(rng.nextUnit()) * size.height
                let amplitude = CGFloat(rng.nextFloat(in: 0.3...1.4))
                let wavelength = CGFloat(rng.nextFloat(in: 60...180))
                let phase = CGFloat(rng.nextFloat(in: 0...(2 * .pi)))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: baseY + sin(phase) * amplitude))
                for x in stride(from: CGFloat(4), through: size.width, by: 4) {
                    line.addLine(to: CGPoint(x: x, y: baseY + sin(x / wavelength * 2 * .pi + phase) * amplitude))
                }
                ctx.stroke(line, with: .color(Theme.spruceGrain.opacity(Double(rng.nextFloat(in: 0.15...0.4)))),
                           lineWidth: CGFloat(rng.nextFloat(in: 0.5...1.4)))
            }

            // Thin light streaks between the dark grain for a bit of sheen.
            for _ in 0..<(lineCount / 2) {
                let y = CGFloat(rng.nextUnit()) * size.height
                let start = CGFloat(rng.nextUnit()) * size.width * 0.6
                let length = CGFloat(rng.nextFloat(in: 0.2...0.5)) * size.width
                ctx.fill(Path(CGRect(x: start, y: y, width: length, height: 0.6)),
                         with: .color(.white.opacity(0.07)))
            }

            guard knots else { return }
            for _ in 0..<2 {
                let center = CGPoint(x: CGFloat(rng.nextFloat(in: 0.05...0.95)) * size.width,
                                     y: CGFloat(rng.nextFloat(in: 0.3...0.7)) * size.height)
                let w = CGFloat(rng.nextFloat(in: 6...11))
                let h = w * 0.4
                for ring in 0..<3 {
                    let grow = CGFloat(ring) * 2.2
                    let rect = CGRect(x: center.x - (w + grow) / 2, y: center.y - (h + grow * 0.5) / 2,
                                      width: w + grow, height: h + grow * 0.5)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(Theme.spruceGrain.opacity(0.35 - Double(ring) * 0.1)),
                               lineWidth: 0.7)
                }
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)),
                         with: .color(Theme.spruceGrain.opacity(0.5)))
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ShelfView()
        .environment(GlobeStore())
        .environment(GlobeThumbnailStore())
}
