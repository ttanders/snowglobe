//
//  PhotorealDioramaLoader.swift
//  Snowglobe
//
//  Gets the real place for a globe and turns it into the miniature shown inside the glass,
//  reporting progress for the UI:
//    1. built this app session?       → reuse it (instant)
//    2. tiles saved on the device?     → build from them (no network, ~1-2 s) — see TileStore
//    3. otherwise                      → download Google's Photorealistic 3D Tiles, then save them
//

import Foundation
import Observation
import RealityKit

@MainActor @Observable
final class PhotorealDioramaLoader {
    enum Phase: Equatable {
        case idle
        case loading(message: String, progress: Double)
        case ready
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle
    /// What to show inside the glass: the real place, or the placeholder village if loading failed.
    private(set) var content: Entity?
    /// Data credits that must stay visible while the miniature is on screen (Google first).
    private(set) var attributions: [String] = []

    /// Miniatures built during this app session (shared by every loader).
    private static var built: [String: (entity: Entity, attributions: [String])] = [:]
    private static var builtOrder: [String] = []
    private static let builtLimit = 4

    func load(_ globe: SnowGlobe) async {
        let key = TileStore.key(for: globe)
        if let cached = Self.built[key] {
            content = cached.entity.clone(recursive: true)
            attributions = cached.attributions
            phase = .ready
            return
        }

        do {
            phase = .loading(message: "Opening your miniature…", progress: 0.05)
            let tiles: [ParsedTile]
            if let saved = await Task.detached(priority: .userInitiated, operation: { TileStore.load(key: key) }).value {
                tiles = saved
            } else {
                tiles = try await download(globe, key: key)
            }

            phase = .loading(message: "Building your miniature…", progress: 0.9)
            let center = globe.coordinate
            let radius = globe.radiusMeters
            let diorama = await Task.detached(priority: .userInitiated) {
                PhotorealDioramaBuilder.build(tiles: tiles, center: center, radiusMeters: radius)
            }.value
            guard !diorama.tiles.isEmpty else { throw GoogleTilesError.nothingHere }

            let entity = try await PhotorealDioramaEntity.make(from: diorama)
            try Task.checkCancellation()
            remember(entity, attributions: diorama.attributions, key: key)
            content = entity.clone(recursive: true)
            attributions = diorama.attributions
            phase = .ready
        } catch {
            if Task.isCancelled {
                phase = .idle
                return
            }
            content = GlobeEntityFactory.makePlaceholderVillage(for: globe)
            attributions = []
            phase = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Downloads the globe's tiles from Google and saves them on the device for next time.
    private func download(_ globe: SnowGlobe, key: String) async throws -> [ParsedTile] {
        phase = .loading(message: "Finding Google's 3D tiles…", progress: 0.05)
        let client = GoogleTilesClient.shared
        _ = try await client.root() // reuses the current session when it's still valid
        let urls: [URL]
        if let saved = await client.savedSelection(for: key) {
            urls = saved
        } else {
            let selector = TileSelector(client: client, center: globe.coordinate, radiusMeters: globe.radiusMeters)
            urls = try await selector.select()
            await client.saveSelection(urls, for: key)
        }
        guard !urls.isEmpty else { throw GoogleTilesError.nothingHere }

        phase = .loading(message: "Downloading \(urls.count) tiles…", progress: 0.15)
        let downloaded = try await TileDownloader.download(urls) { [weak self] done, total in
            Task { @MainActor in
                guard let self, case .loading = self.phase else { return }
                self.phase = .loading(message: "Downloading tiles \(done)/\(total)…",
                                      progress: 0.15 + 0.7 * Double(done) / Double(max(total, 1)))
            }
        }

        let rawTiles = downloaded.map(\.data)
        Task.detached(priority: .utility) { TileStore.save(rawTiles, key: key) }
        return downloaded.map(\.tile)
    }

    private func remember(_ entity: Entity, attributions: [String], key: String) {
        Self.built[key] = (entity, attributions)
        Self.builtOrder.removeAll { $0 == key }
        Self.builtOrder.append(key)
        while Self.builtOrder.count > Self.builtLimit {
            Self.built[Self.builtOrder.removeFirst()] = nil
        }
    }
}

/// A downloaded tile: the raw .glb (to save on the device) and its parsed contents.
struct DownloadedTile: Sendable {
    let data: Data
    let tile: ParsedTile
}

/// Downloads and parses tiles, several at a time.
enum TileDownloader {
    static let maxConcurrent = 8

    static func download(_ urls: [URL], progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [DownloadedTile] {
        try await withThrowingTaskGroup(of: Result<DownloadedTile, Error>.self) { group in
            var next = 0
            var finished = 0
            var tiles: [DownloadedTile] = []
            var lastError: Error?

            func enqueue(_ url: URL) {
                group.addTask {
                    do {
                        let data = try await GoogleTilesClient.shared.tileData(at: url)
                        return .success(DownloadedTile(data: data, tile: try GLBParser.parse(data)))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            while next < min(maxConcurrent, urls.count) {
                enqueue(urls[next])
                next += 1
            }
            while let result = try await group.next() {
                finished += 1
                progress(finished, urls.count)
                switch result {
                case .success(let tile):
                    tiles.append(tile)
                case .failure(let error):
                    // A broken tile is skipped; key, quota or cancellation problems stop everything.
                    if Task.isCancelled { throw CancellationError() }
                    if let tilesError = error as? GoogleTilesError, case .http = tilesError { throw tilesError }
                    if case GoogleTilesError.missingAPIKey = error { throw error }
                    lastError = error
                }
                if next < urls.count {
                    enqueue(urls[next])
                    next += 1
                }
            }
            if tiles.isEmpty, let lastError { throw lastError }
            return tiles
        }
    }
}
