//
//  PhotorealDioramaLoader.swift
//  Snowglobe
//
//  Downloads Google's Photorealistic 3D Tiles around a globe's location and turns them into the
//  miniature shown inside the glass, reporting progress for the UI.
//
//  Built miniatures are kept in memory for this app session only: Google's terms don't allow
//  storing tiles long-term (beyond their Cache-Control lifetime, which URLCache already honours).
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

    private static var cache: [String: (entity: Entity, attributions: [String])] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLimit = 4

    func load(_ globe: SnowGlobe) async {
        let key = "\(globe.coordinate.latitude),\(globe.coordinate.longitude),\(globe.radiusMeters)"
        if let cached = Self.cache[key] {
            content = cached.entity.clone(recursive: true)
            attributions = cached.attributions
            phase = .ready
            return
        }

        do {
            phase = .loading(message: "Finding Google's 3D tiles…", progress: 0.05)
            let selector = TileSelector(client: .shared, center: globe.coordinate, radiusMeters: globe.radiusMeters)
            let urls = try await selector.select()
            guard !urls.isEmpty else { throw GoogleTilesError.nothingHere }

            phase = .loading(message: "Downloading \(urls.count) tiles…", progress: 0.15)
            let tiles = try await TileDownloader.download(urls) { [weak self] done, total in
                Task { @MainActor in
                    guard let self, case .loading = self.phase else { return }
                    self.phase = .loading(message: "Downloading tiles \(done)/\(total)…",
                                          progress: 0.15 + 0.7 * Double(done) / Double(max(total, 1)))
                }
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

    private func remember(_ entity: Entity, attributions: [String], key: String) {
        Self.cache[key] = (entity, attributions)
        Self.cacheOrder.removeAll { $0 == key }
        Self.cacheOrder.append(key)
        while Self.cacheOrder.count > Self.cacheLimit {
            Self.cache[Self.cacheOrder.removeFirst()] = nil
        }
    }
}

/// Downloads and parses tiles, several at a time.
enum TileDownloader {
    static let maxConcurrent = 8

    static func download(_ urls: [URL], progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [ParsedTile] {
        try await withThrowingTaskGroup(of: Result<ParsedTile, Error>.self) { group in
            var next = 0
            var finished = 0
            var tiles: [ParsedTile] = []
            var lastError: Error?

            func enqueue(_ url: URL) {
                group.addTask {
                    do { return .success(try GLBParser.parse(try await GoogleTilesClient.shared.tileData(at: url))) }
                    catch { return .failure(error) }
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
