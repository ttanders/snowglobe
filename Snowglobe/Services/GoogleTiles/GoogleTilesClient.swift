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

    init() {
        let configuration = URLSessionConfiguration.default
        // Google only allows caching tiles as their Cache-Control headers say (a few hours); URLCache follows that.
        configuration.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: configuration)
    }

    /// The root tileset and the URL other URIs resolve against. Starts a new session when needed.
    func root() async throws -> (TilesetJSON, URL) {
        if let current, Date().timeIntervalSince(current.startedAt) < Self.sessionLifetime {
            return (current.root, Self.rootURL)
        }
        let data = try await fetch(Self.rootURL, token: nil)
        let tileset = try decodeTileset(data)
        current = (tileset, tileset.root.sessionToken, Date())
        return (tileset, Self.rootURL)
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
