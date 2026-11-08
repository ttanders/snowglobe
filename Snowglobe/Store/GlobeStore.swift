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

    func delete(id: SnowGlobe.ID) {
        globes.removeAll { $0.id == id }
        save()
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
