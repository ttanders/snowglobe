//
//  ShelfView.swift
//  Snowglobe
//
//  Home screen: snowglobes standing on wooden shelves, two per shelf.
//

import SwiftUI

struct ShelfView: View {
    @Environment(GlobeStore.self) private var store
    @Namespace private var zoomNamespace
    @State private var path: [SnowGlobe.ID] = []
    @State private var renameTarget: SnowGlobe?
    @State private var renameText = ""

    private let globesPerShelf = 2
    private let columnSpacing: CGFloat = 18

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 34) {
                    header
                    ForEach(Array(shelves.enumerated()), id: \.offset) { _, row in
                        shelf(row)
                    }
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
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Snowglobes")
                .font(Theme.titleFont(40))
                .foregroundStyle(Theme.snow)
            Text("Places you've been, under glass")
                .font(.subheadline)
                .foregroundStyle(Theme.ice.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    /// Globes chunked into shelves; always at least two shelves so an empty shelf still looks like one.
    private var shelves: [[SnowGlobe]] {
        var rows = stride(from: 0, to: store.globes.count, by: globesPerShelf).map {
            Array(store.globes[$0..<min($0 + globesPerShelf, store.globes.count)])
        }
        while rows.count < 2 { rows.append([]) }
        return rows
    }

    private func shelf(_ row: [SnowGlobe]) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: columnSpacing) {
                ForEach(0..<globesPerShelf, id: \.self) { slot in
                    if slot < row.count {
                        globeButton(row[slot])
                    } else {
                        Color.clear
                            .aspectRatio(GlobeIllustration.aspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 10)
            .offset(y: 9) // stand the pedestals on the plank's top surface
            .zIndex(1)

            ShelfPlank(titles: row.map(\.title), columns: globesPerShelf, columnSpacing: columnSpacing)
        }
    }

    private func globeButton(_ globe: SnowGlobe) -> some View {
        Button {
            path.append(globe.id)
        } label: {
            GlobeIllustration(globe: globe)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: globe.id, in: zoomNamespace)
        .frame(maxWidth: .infinity)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renameText = globe.title
                renameTarget = globe
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                store.delete(id: globe.id)
            }
        }
        .accessibilityLabel("\(globe.title) snowglobe")
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
}

/// A wooden plank: lit top surface, darker front edge with brass-coloured name labels.
private struct ShelfPlank: View {
    let titles: [String]
    let columns: Int
    let columnSpacing: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Theme.woodHighlight, Theme.wood], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
            ZStack {
                LinearGradient(colors: [Theme.wood, Theme.woodDark], startPoint: .top, endPoint: .bottom)
                HStack(spacing: columnSpacing) {
                    ForEach(0..<columns, id: \.self) { index in
                        Text(index < titles.count ? titles[index] : " ")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.brass)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 26)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 14, y: 12)
    }
}

#Preview {
    ShelfView()
        .environment(GlobeStore())
        .preferredColorScheme(.dark)
}
