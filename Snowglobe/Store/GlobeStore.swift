//
//  GlobeStore.swift
//  Snowglobe
//
//  Owns the list of snowglobes and saves it to Application Support/Snowglobes/globes.json.
//

import Foundation
import Observation

@MainActor @Observable
final class GlobeStore {
    /// Shelf order (oldest first).
    private(set) var globes: [SnowGlobe] = []

    private let fileURL: URL

    init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Snowglobes", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "globes.json")
        load()
        pruneTiles()
    }

    func globe(id: SnowGlobe.ID) -> SnowGlobe? {
        globes.first { $0.id == id }
    }

    func add(_ globe: SnowGlobe) {
        globes.append(globe)
        save()
    }

    func rename(id: SnowGlobe.ID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = globes.firstIndex(where: { $0.id == id }) else { return }
        globes[index].title = trimmed
        save()
    }

    /// Fixes how much of the place a globe holds (picked once, with the zoom slider; see GlobeSizing).
    func lockSize(id: SnowGlobe.ID, radiusMeters: Double) {
        guard let index = globes.firstIndex(where: { $0.id == id }), !globes[index].isSizeLocked,
              radiusMeters.isFinite, radiusMeters >= 1 else { return }
        globes[index].radiusMeters = radiusMeters
        globes[index].sizeLocked = true
        save()
    }

    func delete(id: SnowGlobe.ID) {
        globes.removeAll { $0.id == id }
        save()
        pruneTiles() // its saved 3D tiles, unless another globe of the same place still uses them
    }

    /// Deletes saved tile sets that no globe needs any more (e.g. the wide set used while choosing a
    /// size, once the size is locked). Runs at launch, when nothing is mid-copy, and after a delete.
    private func pruneTiles() {
        let keep = Set(globes.flatMap(TileStore.keys(for:)))
        Task.detached(priority: .utility) { TileStore.prune(keeping: keep) }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            // First launch: start with a few demo globes so the shelf isn't empty.
            globes = SampleGlobes.all
            save()
            return
        }
        do {
            globes = try Self.decoder.decode([SnowGlobe].self, from: data)
        } catch {
            print("GlobeStore: couldn't read globes.json (\(error)); starting with samples")
            globes = SampleGlobes.all
        }
    }

    private func save() {
        do {
            try Self.encoder.encode(globes).write(to: fileURL, options: .atomic)
        } catch {
            print("GlobeStore: save failed: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
