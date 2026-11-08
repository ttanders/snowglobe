//
//  TileStore.swift
//  Snowglobe
//
//  Keeps each globe's downloaded Google tiles on the device (Application Support/Snowglobes/Tiles),
//  so every globe downloads its 3D data only once and then opens offline.
//
//  ⚠️ Google's Map Tiles API policies only allow keeping tiles as long as their Cache-Control
//  headers say (a few hours). Keeping them forever is fine for a private hackathon prototype on
//  your own key, but set `keepTilesForever` to false before releasing the app publicly.
//

import Foundation

enum TileStore {
    static let keepTilesForever = true

    private static let root: URL = {
        var url = URL.applicationSupportDirectory.appending(path: "Snowglobes/Tiles", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true // re-downloadable; keep it out of iCloud backups
        try? url.setResourceValues(values)
        return url
    }()

    /// Same place + same size → same tiles.
    static func key(for globe: SnowGlobe) -> String {
        String(format: "%.6f_%.6f_%.0f", globe.coordinate.latitude, globe.coordinate.longitude, globe.radiusMeters)
    }

    /// The saved tiles for a globe, parsed, or nil if it hasn't been downloaded yet.
    /// Reads and parses files, so call it off the main actor.
    static func load(key: String) -> [ParsedTile]? {
        guard keepTilesForever,
              let files = try? FileManager.default.contentsOfDirectory(at: directory(for: key), includingPropertiesForKeys: nil)
        else { return nil }
        let tiles = files
            .filter { $0.pathExtension == "glb" }
            .compactMap { file in (try? Data(contentsOf: file)).flatMap { try? GLBParser.parse($0) } }
        return tiles.isEmpty ? nil : tiles
    }

    /// Saves a globe's raw tiles. Writes to a staging folder first so a half-written save is never used.
    static func save(_ tiles: [Data], key: String) {
        guard keepTilesForever, !tiles.isEmpty else { return }
        let fileManager = FileManager.default
        let staging = root.appending(path: key + ".partial", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for (index, data) in tiles.enumerated() {
                try data.write(to: staging.appending(path: "\(index).glb"))
            }
            try? fileManager.removeItem(at: directory(for: key))
            try fileManager.moveItem(at: staging, to: directory(for: key))
        } catch {
            try? fileManager.removeItem(at: staging)
        }
    }

    static func remove(key: String) {
        try? FileManager.default.removeItem(at: directory(for: key))
    }

    private static func directory(for key: String) -> URL {
        root.appending(path: key, directoryHint: .isDirectory)
    }
}
