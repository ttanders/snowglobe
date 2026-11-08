//
//  PhotoImportSheet.swift
//  Snowglobe
//
//  Opens after the user picks a photo with the shelf's photo button. Reads where and when
//  the photo was taken, names the place, and makes a new snowglobe there.
//

import MapKit
import PhotosUI
import SwiftUI

struct PhotoImportSheet: View {
    /// Called with the new globe when the user taps Make Snowglobe.
    let onCreate: (SnowGlobe) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var phase: Phase = .reading("Reading your photo…")
    @State private var title = ""

    /// Real-world size of new globes (the same default the rest of the app uses).
    private let radius = RadiusPreset.neighborhood

    init(item: PhotosPickerItem, onCreate: @escaping (SnowGlobe) -> Void) {
        self.onCreate = onCreate
        _selection = State(initialValue: item)
    }

    private struct ImportedPhoto {
        var preview: CGImage?
        var coordinate: GeoCoordinate
        var date: Date?
        var place: PlaceName?
    }

    private enum Phase {
        case reading(String)
        case ready(ImportedPhoto)
        case noLocation
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("New Snowglobe")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
        .task(id: selection) { await load(selection) }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .reading(let message):
            ProgressView(message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let photo):
            form(for: photo)
        case .noLocation:
            ContentUnavailableView {
                Label("No Location in This Photo", systemImage: "location.slash")
            } description: {
                Text("Choose a photo taken with Location Services on, like one from your iPhone's Camera. In the photo picker, make sure Location Included is turned on.")
            } actions: {
                choosePhotoButton("Choose Another Photo")
                    .buttonStyle(.glassProminent)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Open This Photo", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                choosePhotoButton("Choose Another Photo")
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private func form(for photo: ImportedPhoto) -> some View {
        Form {
            if let preview = photo.preview {
                Section {
                    Color.clear
                        .frame(height: 220)
                        .overlay {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                        .listRowInsets(EdgeInsets())
                }
            }

            Section("Name") {
                TextField("Name on the plaque", text: $title)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
            }

            Section {
                map(for: photo)
                    .listRowInsets(EdgeInsets())
                LabeledContent("Location") {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let area = photo.place?.subtitle {
                            Text(area)
                        }
                        Text(photo.coordinate.formatted)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.trailing)
                }
                LabeledContent("Taken", value: photo.date?.formatted(date: .long, time: .omitted) ?? "Unknown")
            } header: {
                Text("From Your Photo")
            } footer: {
                Text("Your snowglobe will hold about \(radius.detail) around the spot where you took this photo.")
            }

            Section {
                choosePhotoButton("Choose a Different Photo")
            }
        }
        .safeAreaBar(edge: .bottom) {
            Button {
                create(from: photo)
            } label: {
                Label("Make Snowglobe", systemImage: "snowflake")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(trimmedTitle.isEmpty)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    /// The photo's spot, with the circle of the world that will go inside the globe.
    private func map(for photo: ImportedPhoto) -> some View {
        let center = photo.coordinate.clCoordinate
        let span = radius.rawValue * 3.2
        return Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span)),
                   interactionModes: []) {
            MapCircle(center: center, radius: radius.rawValue)
                .foregroundStyle(Theme.ice.opacity(0.2))
                .stroke(Theme.ice, lineWidth: 2)
            Marker(trimmedTitle, systemImage: "camera.fill", coordinate: center)
        }
        .frame(height: 170)
        .id(photo.coordinate)
    }

    private func choosePhotoButton(_ label: String) -> some View {
        PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
            Label(label, systemImage: "photo.on.rectangle")
        }
    }

    // MARK: - Work

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        phase = .reading("Reading your photo…")

        // `.current` encoding above keeps the original file, so its EXIF/GPS metadata comes along.
        let data: Data
        do {
            guard let loaded = try await item.loadTransferable(type: Data.self) else {
                phase = .failed("This photo's file isn't available.")
                return
            }
            data = loaded
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            return
        }

        let (metadata, preview) = await Task.detached(priority: .userInitiated) {
            (PhotoMetadataReader.read(imageData: data), PhotoMetadataReader.thumbnail(imageData: data))
        }.value
        guard !Task.isCancelled else { return }
        guard let coordinate = metadata.coordinate else {
            phase = .noLocation
            return
        }

        phase = .reading("Finding the place…")
        let place = await PlaceNamer.name(for: coordinate)
        guard !Task.isCancelled else { return }
        title = place?.title ?? "My Snowglobe"
        phase = .ready(ImportedPhoto(preview: preview, coordinate: coordinate, date: metadata.date, place: place))
    }

    private func create(from photo: ImportedPhoto) {
        let globe = SnowGlobe(
            title: trimmedTitle,
            subtitle: photo.place?.subtitle,
            coordinate: photo.coordinate,
            radiusMeters: radius.rawValue,
            photoDate: photo.date
        )
        onCreate(globe)
        dismiss()
    }
}
