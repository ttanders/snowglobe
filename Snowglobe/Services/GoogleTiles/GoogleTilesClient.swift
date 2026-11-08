//
//  GoogleTilesClient.swift
//  Snowglobe
//
//  Talks to Google's Map Tiles API (Photorealistic 3D Tiles). It adds the API key, the iOS
//  bundle-ID header (required when the key is restricted to this app), and the session token
//  Google hands out with the root tileset. One root request is one billable event and is good
//  for about 3 hours of tile downloads.
//

import Foundation

/// The parts of a 3D Tiles tileset JSON we use.
struct TilesetJSON: Decodable, Sendable {
    let root: TileJSON
}

struct TileJSON: Decodable, Sendable {
    struct BoundingVolume: Decodable, Sendable {
        /// Oriented box: centre (3 numbers) followed by three half-axis vectors (3 × 3), in ECEF meters.
        let box: [Double]?
    }

    struct Content: Decodable, Sendable {
        let uri: String?
    }

    let boundingVolume: BoundingVolume
    let geometricError: Double
    let content: Content?
    let children: [TileJSON]?

    /// The `session` query parameter Google puts on the child URIs of the root tileset.
    var sessionToken: String? {
        if let uri = content?.uri,
           let token = URLComponents(string: uri)?.queryItems?.first(where: { $0.name == "session" })?.value {
            return token
        }
        for child in children ?? [] {
            if let token = child.sessionToken { return token }
        }
        return nil
    }

    /// True when this tile's content is another tileset (JSON) rather than a mesh (.glb).
    var hasTilesetContent: Bool {
        guard let uri = content?.uri else { return false }
        return (URLComponents(string: uri)?.path ?? uri).hasSuffix(".json")
    }
}

enum GoogleTilesError: LocalizedError {
    case missingAPIKey
    case http(status: Int)
    case badData(String)
    case nothingHere

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your Google Maps API key to Snowglobe/Secrets.plist to load real 3D places."
        case .http(status: 403):
            "Google refused the API key. Check that the Map Tiles API is enabled and that the key allows this app's bundle ID."
        case .http(status: 429):
            "Google's 3D tiles are busy right now. Try again in a minute."
        case .http(let status):
            "Google's 3D tiles returned an error (HTTP \(status))."
        case .badData(let detail):
            "Couldn't read Google's 3D data (\(detail))."
        case .nothingHere:
            "Google has no 3D data for this spot."
        }
    }
}

actor GoogleTilesClient {
    static let shared = GoogleTilesClient()

    private static let rootURL = URL(string: "https://tile.googleapis.com/v1/3dtiles/root.json")!
    /// Google's sessions last about 3 hours; start a new one a little early.
    private static let sessionLifetime: TimeInterval = 2.5 * 60 * 60

    private let urlSession: URLSession
    private var current: (root: TilesetJSON, token: String?, startedAt: Date)?

    // MARK: On-device storage
    //
    // Google's terms only allow keeping tiles as long as their Cache-Control headers say (currently
    // 4 hours), so nothing here is permanent:
    //   • tiles live in an on-disk HTTP cache that follows those headers (survives app restarts),
    //   • the current session is saved, so tile URLs (which include the session) still match the
    //     cache after a restart,
    //   • each globe's list of tiles is remembered for the session, so the tile tree isn't re-walked.

    private static let storageDirectory: URL = {
        let directory = URL.cachesDirectory.appending(path: "GoogleTiles", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
    private static let sessionFile = storageDirectory.appending(path: "session.json")
    private static let selectionsFile = storageDirectory.appending(path: "selections.json")

    private struct StoredSession: Codable {
        let rootJSON: Data
        let token: String?
        let startedAt: Date
    }

    private struct StoredSelections: Codable {
        let token: String
        var tiles: [String: [String]] // globe key → tile URLs
    }

    private var selections: StoredSelections?
    private var loadedFromDisk = false

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024,
                                          directory: Self.storageDirectory.appending(path: "HTTP", directoryHint: .isDirectory))
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: configuration)
    }

    /// The root tileset and the URL other URIs resolve against. Reuses the saved session while it's
    /// still valid; otherwise starts a new one (one billable request).
    func root() async throws -> (TilesetJSON, URL) {
        loadFromDiskIfNeeded()
        if let current, Date().timeIntervalSince(current.startedAt) < Self.sessionLifetime {
            return (current.root, Self.rootURL)
        }
        let data = try await fetch(Self.rootURL, token: nil)
        let tileset = try decodeTileset(data)
        let session = StoredSession(rootJSON: data, token: tileset.root.sessionToken, startedAt: Date())
        current = (tileset, session.token, session.startedAt)
        try? JSONEncoder().encode(session).write(to: Self.sessionFile, options: .atomic)
        return (tileset, Self.rootURL)
    }

    /// Tiles picked earlier in this session for the globe identified by `key`, if any.
    func savedSelection(for key: String) -> [URL]? {
        loadFromDiskIfNeeded()
        guard let token = current?.token, let selections, selections.token == token,
              let strings = selections.tiles[key] else { return nil }
        return strings.compactMap(URL.init(string:))
    }

    func saveSelection(_ urls: [URL], for key: String) {
        guard let token = current?.token else { return }
        var updated = selections?.token == token ? selections! : StoredSelections(token: token, tiles: [:])
        updated.tiles[key] = urls.map(\.absoluteString)
        selections = updated
        try? JSONEncoder().encode(updated).write(to: Self.selectionsFile, options: .atomic)
    }

    private func loadFromDiskIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        if let data = try? Data(contentsOf: Self.sessionFile),
           let session = try? JSONDecoder().decode(StoredSession.self, from: data),
           Date().timeIntervalSince(session.startedAt) < Self.sessionLifetime,
           let tileset = try? JSONDecoder().decode(TilesetJSON.self, from: session.rootJSON) {
            current = (tileset, session.token, session.startedAt)
        }
        if let data = try? Data(contentsOf: Self.selectionsFile) {
            selections = try? JSONDecoder().decode(StoredSelections.self, from: data)
        }
    }

    /// Downloads a nested tileset JSON.
    func tileset(at uri: String, relativeTo base: URL) async throws -> (TilesetJSON, URL) {
        let url = try resolve(uri, relativeTo: base)
        return (try decodeTileset(try await fetch(url, token: current?.token)), url)
    }

    /// Downloads a tile (.glb).
    func tileData(at url: URL) async throws -> Data {
        try await fetch(url, token: current?.token)
    }

    func resolve(_ uri: String, relativeTo base: URL) throws -> URL {
        guard let url = URL(string: uri, relativeTo: base)?.absoluteURL else {
            throw GoogleTilesError.badData("bad tile address")
        }
        return url
    }

    // MARK: - Networking

    private func fetch(_ url: URL, token: String?) async throws -> Data {
        guard let key = Secrets.googleMapsAPIKey else { throw GoogleTilesError.missingAPIKey }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw GoogleTilesError.badData("bad tile address")
        }
        var items = (components.queryItems ?? []).filter { $0.name != "key" }
        items.append(URLQueryItem(name: "key", value: key))
        if let token, !items.contains(where: { $0.name == "session" }) {
            items.append(URLQueryItem(name: "session", value: token))
        }
        components.queryItems = items
        guard let requestURL = components.url else { throw GoogleTilesError.badData("bad tile address") }

        var request = URLRequest(url: requestURL)
        if let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }

        // Retry a couple of times on flaky networks and when Google asks us to slow down.
        var attempt = 0
        while true {
            do {
                let (data, response) = try await urlSession.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                if status == 429 || status >= 500, attempt < 2 {
                    attempt += 1
                    try await Task.sleep(for: .seconds(attempt))
                    continue
                }
                throw GoogleTilesError.http(status: status)
            } catch let error as URLError where error.code != .cancelled && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt))
            }
        }
    }

    private func decodeTileset(_ data: Data) throws -> TilesetJSON {
        do {
            return try JSONDecoder().decode(TilesetJSON.self, from: data)
        } catch {
            throw GoogleTilesError.badData("tileset")
        }
    }
}
