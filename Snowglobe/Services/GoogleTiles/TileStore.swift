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
        key(coordinate: globe.coordinate, radiusMeters: globe.radiusMeters)
    }

    /// Tiles covering `radiusMeters` around `coordinate`.
    static func key(coordinate: GeoCoordinate, radiusMeters: Double) -> String {
        "\(coordinatePrefix(coordinate))_" + String(format: "%.0f", radiusMeters)
    }

    /// Every tile set a globe needs kept: its own, plus the wide one used while its size is being chosen.
    static func keys(for globe: SnowGlobe) -> [String] {
        var keys = [key(for: globe)]
        if !globe.isSizeLocked {
            keys.append(key(coordinate: globe.coordinate,
                            radiusMeters: GlobeSizing.sizingRadius(baseRadius: globe.radiusMeters)))
        }
        return keys
    }

    /// Radii (meters) of every tile set saved around `coordinate`, by any globe.
    static func savedRadii(around coordinate: GeoCoordinate) -> [Double] {
        guard keepTilesForever,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        else { return [] }
        return names.compactMap { radius(inKey: $0, around: coordinate) }
    }

    /// The radius in `key` if it's a tile set around `coordinate` (nil for other places and unfinished saves).
    static func radius(inKey key: String, around coordinate: GeoCoordinate) -> Double? {
        let prefix = coordinatePrefix(coordinate) + "_"
        guard key.hasPrefix(prefix) else { return nil }
        return Double(key.dropFirst(prefix.count))
    }

    /// True if tiles are saved for `key` (cheap: doesn't read them).
    static func contains(key: String) -> Bool {
        keepTilesForever && FileManager.default.fileExists(atPath: directory(for: key).path(percentEncoded: false))
    }

    private static func coordinatePrefix(_ coordinate: GeoCoordinate) -> String {
        String(format: "%.6f_%.6f", coordinate.latitude, coordinate.longitude)
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

    /// Saves a copy of one tile set under another key (a wide set becoming a locked globe's own).
    /// Returns false if there was nothing to copy or the copy failed. Touches files: call it off the main actor.
    static func copy(from source: String, to destination: String) -> Bool {
        guard keepTilesForever, contains(key: source) else { return false }
        guard source != destination else { return true }
        let fileManager = FileManager.default
        let staging = root.appending(path: destination + ".partial", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.copyItem(at: directory(for: source), to: staging)
            try? fileManager.removeItem(at: directory(for: destination))
            try fileManager.moveItem(at: staging, to: directory(for: destination))
            return true
        } catch {
            try? fileManager.removeItem(at: staging)
            return false
        }
    }

    /// Deletes every saved tile set except `keys` (sets no globe uses any more). Saves still being
    /// written (".partial") are left alone. Touches files: call it off the main actor.
    static func prune(keeping keys: Set<String>) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path(percentEncoded: false)) else { return }
        for name in names where !name.hasSuffix(".partial") && !keys.contains(name) {
            try? fileManager.removeItem(at: directory(for: name))
        }
    }

    private static func directory(for key: String) -> URL {
        root.appending(path: key, directoryHint: .isDirectory)
    }
}
