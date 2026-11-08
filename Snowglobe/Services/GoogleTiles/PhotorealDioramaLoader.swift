//
//  PhotorealDioramaLoader.swift
//  Snowglobe
//
//  Gets the real place for a globe and turns it into the miniature shown inside the glass,
//  reporting progress for the UI:
//    1. built this app session?       → reuse it (instant)
//    2. tiles in memory or on device?  → build from them (no network, ~1-2 s) — see TileStore
//    3. otherwise                      → download Google's Photorealistic 3D Tiles, then save them
//
//  Choosing a new globe's size (see GlobeSizing) only changes how big a circle is cut from the
//  tiles. While choosing, every zoom is cut from one wide download, so the slider never waits on
//  the network. Locking the size then gets sharp tiles for just the chosen circle: a copy of
//  tiles already on hand when they're detailed enough, otherwise one more download, while the
//  globe keeps showing the preview.
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
    /// True while the real place is inside the glass (not the placeholder village, not empty).
    private(set) var showsRealPlace = false
    /// True while a zoom change is being re-cut from tiles already on hand (no download needed).
    private(set) var isRebuilding = false

    /// Miniatures built during this app session (shared by every loader), keyed by tiles + shown size.
    private static var built: [String: (entity: Entity, attributions: [String])] = [:]
    private static var builtOrder: [String] = []
    private static let builtLimit = 4

    /// Parsed tiles kept in memory, so moving the zoom slider doesn't re-read them from disk.
    private static var parsed: [String: [ParsedTile]] = [:]
    private static var parsedOrder: [String] = []
    private static let parsedLimit = 3

    /// Downloads in flight, by tile key. They keep going when the zoom changes again (or the screen
    /// closes), so a half-finished download is never thrown away; it's saved for next time.
    private static var downloads: [String: Task<[ParsedTile], Error>] = [:]
    /// Tile sets being copied to a locked globe's own key (so the same copy never runs twice at once).
    private static var copying: Set<String> = []

    /// Bumped by every `load`, so a superseded load never overwrites a newer one.
    private var generation = 0
    /// The download whose progress the UI is showing.
    private var activeDownloadKey: String?
    /// Real-world radius of what's inside the glass now.
    private var shownRadius: Double?

    /// Shows `globe`: at its locked size, or (while its size is still being chosen) at `zoom`.
    func load(_ globe: SnowGlobe, zoom: Double = 1) async {
        generation += 1
        let current = generation
        activeDownloadKey = nil
        let viewRadius = globe.isSizeLocked
            ? globe.radiusMeters
            : GlobeSizing.radius(baseRadius: globe.radiusMeters, zoom: zoom)
        let plan = Self.plan(for: globe, viewRadius: viewRadius)
        if let saveAs = plan.saveAs { Self.copyTiles(from: plan.key, to: saveAs) }

        let builtKey = plan.key + String(format: "_view%.1f", viewRadius)
        if let cached = Self.built[builtKey] {
            show(cached.entity.clone(recursive: true), attributions: cached.attributions, radius: viewRadius)
            isRebuilding = false
            phase = .ready
            return
        }

        // With a real place already on screen (a zoom change, or locking), keep it there meanwhile.
        if showsRealPlace {
            isRebuilding = true
            phase = .ready
        } else {
            phase = .loading(message: "Opening your miniature…", progress: 0.05)
        }
        defer { if generation == current { isRebuilding = false } }

        do {
            var tiles = plan.needsDownload ? nil : await Self.tilesOnHand(key: plan.key)
            if tiles == nil {
                // While the tiles download, show the place cut from tiles already on hand,
                // unless the right circle is already on screen (e.g. the preview the size was locked from).
                if let standIn = plan.standInKey, !(showsRealPlace && shownRadius == viewRadius),
                   let standInTiles = await Self.tilesOnHand(key: standIn) {
                    let (entity, credits) = try await Self.makeMiniature(from: standInTiles, center: globe.coordinate,
                                                                         radiusMeters: viewRadius)
                    guard generation == current else { return }
                    show(entity, attributions: credits, radius: viewRadius)
                }
                guard generation == current else { return }
                isRebuilding = false
                let message = !showsRealPlace ? "Finding Google's 3D tiles…"
                    : globe.isSizeLocked ? "Sharpening your miniature…"
                    : "Fetching more of the area…"
                phase = .loading(message: message, progress: 0.05)
                tiles = try await download(around: globe.coordinate, radiusMeters: plan.radius, key: plan.key)
                guard generation == current else { return }
                phase = .loading(message: "Building your miniature…", progress: 0.9)
            }

            let (entity, credits) = try await Self.makeMiniature(from: tiles ?? [], center: globe.coordinate,
                                                                 radiusMeters: viewRadius)
            remember(entity, attributions: credits, key: builtKey) // even if superseded: going back is instant
            guard generation == current else { return }
            try Task.checkCancellation()
            show(entity.clone(recursive: true), attributions: credits, radius: viewRadius)
            phase = .ready
        } catch {
            guard generation == current else { return }
            activeDownloadKey = nil
            if Task.isCancelled {
                phase = .idle
                return
            }
            if !showsRealPlace {
                content = GlobeEntityFactory.makePlaceholderVillage(for: globe)
                attributions = []
                shownRadius = nil
            }
            phase = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// For a globe whose size was just locked as its screen closed: makes sure its own tiles end up
    /// saved on the device (copied or downloaded in the background), so it opens sharp next time.
    func finishLocking(_ globe: SnowGlobe) {
        guard globe.isSizeLocked else { return }
        let plan = Self.plan(for: globe, viewRadius: globe.radiusMeters)
        if let saveAs = plan.saveAs {
            Self.copyTiles(from: plan.key, to: saveAs)
        } else if plan.needsDownload {
            _ = downloadTask(around: globe.coordinate, radiusMeters: plan.radius, key: plan.key)
        }
    }

    private func show(_ entity: Entity, attributions: [String], radius: Double) {
        content = entity
        self.attributions = attributions
        showsRealPlace = true
        shownRadius = radius
    }

    // MARK: - Which tiles

    /// Where the miniature's tiles come from for one load.
    private struct Plan {
        /// The tiles to cut the miniature from…
        var key: String
        /// …which cover this radius (meters) around the globe's centre…
        var radius: Double
        /// …and have to be downloaded first.
        var needsDownload = false
        /// Also save a copy of them under this key (a locked globe's own tiles).
        var saveAs: String?
        /// Tiles on hand to show while downloading.
        var standInKey: String?
    }

    private static func plan(for globe: SnowGlobe, viewRadius: Double) -> Plan {
        let onHand = onHandSets(around: globe.coordinate)
        // Keys round radii to whole meters, and every set reaches ~2% past its radius.
        let covering = onHand.filter { $0.radius >= viewRadius * 0.99 }
        let standIn = (covering.first ?? onHand.last)?.key

        if globe.isSizeLocked {
            let own = TileStore.key(for: globe)
            if onHand.contains(where: { $0.key == own }) {
                return Plan(key: own, radius: globe.radiusMeters)
            }
            if let best = covering.first, best.radius <= viewRadius * GlobeSizing.reusableCoverage {
                return Plan(key: best.key, radius: best.radius, saveAs: own)
            }
            return Plan(key: own, radius: globe.radiusMeters, needsDownload: true, standInKey: standIn)
        }

        // Choosing the size: the sharpest tiles on hand that cover this zoom, else the one wide download.
        if let best = covering.first {
            return Plan(key: best.key, radius: best.radius)
        }
        let wide = GlobeSizing.sizingRadius(baseRadius: globe.radiusMeters)
        return Plan(key: TileStore.key(coordinate: globe.coordinate, radiusMeters: wide), radius: wide,
                    needsDownload: true, standInKey: standIn)
    }

    /// Tile sets around `coordinate` in memory or on the device, smallest (sharpest) first.
    private static func onHandSets(around coordinate: GeoCoordinate) -> [(key: String, radius: Double)] {
        var radii = Set(TileStore.savedRadii(around: coordinate))
        for key in parsed.keys {
            if let radius = TileStore.radius(inKey: key, around: coordinate) { radii.insert(radius) }
        }
        return radii.sorted().map { (TileStore.key(coordinate: coordinate, radiusMeters: $0), $0) }
    }

    /// Tiles for `key` from memory or the device, or nil if they still need downloading.
    private static func tilesOnHand(key: String) async -> [ParsedTile]? {
        if let tiles = parsed[key] {
            rememberParsed(tiles, key: key)
            return tiles
        }
        guard TileStore.contains(key: key),
              let saved = await Task.detached(priority: .userInitiated, operation: { TileStore.load(key: key) }).value
        else { return nil }
        rememberParsed(saved, key: key)
        return saved
    }

    private static func rememberParsed(_ tiles: [ParsedTile], key: String) {
        parsed[key] = tiles
        parsedOrder.removeAll { $0 == key }
        parsedOrder.append(key)
        while parsedOrder.count > parsedLimit {
            parsed[parsedOrder.removeFirst()] = nil
        }
    }

    /// Saves a copy of a tile set under a locked globe's own key, in the background (once at a time).
    private static func copyTiles(from source: String, to destination: String) {
        guard source != destination, !copying.contains(destination) else { return }
        copying.insert(destination)
        Task {
            _ = await Task.detached(priority: .utility) { TileStore.copy(from: source, to: destination) }.value
            copying.remove(destination)
        }
    }

    // MARK: - Downloading

    /// Downloads one tile set from Google (or joins that download if it's already running) and
    /// shows its progress while it's the one this screen is waiting for.
    private func download(around coordinate: GeoCoordinate, radiusMeters: Double, key: String) async throws -> [ParsedTile] {
        activeDownloadKey = key
        return try await downloadTask(around: coordinate, radiusMeters: radiusMeters, key: key).value
    }

    private func downloadTask(around coordinate: GeoCoordinate, radiusMeters: Double, key: String) -> Task<[ParsedTile], Error> {
        if let running = Self.downloads[key] { return running }
        let task = Task { [weak self] in
            defer { Self.downloads[key] = nil }
            let tiles = try await Self.fetch(around: coordinate, radiusMeters: radiusMeters, key: key) { message, progress in
                guard let self, self.activeDownloadKey == key, case .loading = self.phase else { return }
                self.phase = .loading(message: message, progress: progress)
            }
            Self.rememberParsed(tiles, key: key)
            return tiles
        }
        Self.downloads[key] = task
        return task
    }

    /// Picks, downloads and parses the tiles covering `radiusMeters` around `coordinate`, and saves them on the device.
    private static func fetch(around coordinate: GeoCoordinate, radiusMeters: Double, key: String,
                              progress: @escaping @MainActor @Sendable (String, Double) -> Void) async throws -> [ParsedTile] {
        let client = GoogleTilesClient.shared
        _ = try await client.root() // reuses the current session when it's still valid
        let urls: [URL]
        if let saved = await client.savedSelection(for: key) {
            urls = saved
        } else {
            let selector = TileSelector(client: client, center: coordinate, radiusMeters: radiusMeters)
            urls = try await selector.select()
            await client.saveSelection(urls, for: key)
        }
        guard !urls.isEmpty else { throw GoogleTilesError.nothingHere }

        progress("Downloading \(urls.count) tiles…", 0.15)
        let downloaded = try await TileDownloader.download(urls) { done, total in
            Task { @MainActor in
                progress("Downloading tiles \(done)/\(total)…", 0.15 + 0.7 * Double(done) / Double(max(total, 1)))
            }
        }

        // Saved before returning, so whatever is in memory is also on the device (and can be copied).
        let rawTiles = downloaded.map(\.data)
        await Task.detached(priority: .utility) { TileStore.save(rawTiles, key: key) }.value
        return downloaded.map(\.tile)
    }

    // MARK: - Building

    /// Cuts a circle of `radiusMeters` from the tiles and turns it into RealityKit entities.
    private static func makeMiniature(from tiles: [ParsedTile], center: GeoCoordinate,
                                      radiusMeters: Double) async throws -> (Entity, [String]) {
        let diorama = await Task.detached(priority: .userInitiated) {
            PhotorealDioramaBuilder.build(tiles: tiles, center: center, radiusMeters: radiusMeters)
        }.value
        guard !diorama.tiles.isEmpty else { throw GoogleTilesError.nothingHere }
        return (try await PhotorealDioramaEntity.make(from: diorama), diorama.attributions)
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
