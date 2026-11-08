//
//  GLBParser.swift
//  Snowglobe
//
//  Minimal binary glTF (.glb) reader for Google's Photorealistic 3D Tiles: triangle meshes with
//  positions, one set of texture coordinates and an embedded JPEG texture. Google serves these
//  uncompressed (no Draco), so no third-party decoder is needed.
//

import Foundation
import simd

/// One textured triangle mesh from a tile, positioned in ECEF meters.
struct TileMesh: Sendable {
    var positions: [SIMD3<Double>]
    /// glTF convention: v = 0 is the TOP row of the image.
    var uvs: [SIMD2<Float>]
    var indices: [UInt32]
    /// Encoded texture (JPEG).
    var imageData: Data?
}

struct ParsedTile: Sendable {
    var meshes: [TileMesh]
    /// e.g. "Google;Airbus;Landsat / Copernicus" (must be shown on screen).
    var copyright: String?
}

enum GLBParser {
    enum ParseError: Error {
        case notGLB, missingJSON, badAccessor
    }

    /// glTF is Y-up; 3D Tiles (ECEF) is Z-up: (x, y, z) → (x, -z, y).
    private static let yUpToZUp = simd_double4x4(rows: [
        SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1),
    ])

    static func parse(_ data: Data) throws -> ParsedTile {
        let (json, binary) = try chunks(of: data)
        let document = try JSONDecoder().decode(GLTFDocument.self, from: json)
        let reader = GLTFAccessorReader(document: document, binary: binary)
        let nodes = document.nodes ?? []
        var meshes: [TileMesh] = []

        func visit(_ nodeIndex: Int, parent: simd_double4x4, depth: Int) throws {
            guard nodes.indices.contains(nodeIndex), depth < 32 else { return }
            let node = nodes[nodeIndex]
            let world = parent * node.localMatrix
            if let meshIndex = node.mesh, let mesh = document.meshes?[safe: meshIndex] {
                for primitive in mesh.primitives where (primitive.mode ?? 4) == 4 {
                    if let tileMesh = try reader.mesh(for: primitive, transform: world) {
                        meshes.append(tileMesh)
                    }
                }
            }
            for child in node.children ?? [] {
                try visit(child, parent: world, depth: depth + 1)
            }
        }

        let roots = document.scenes?[safe: document.scene ?? 0]?.nodes ?? Array(nodes.indices)
        for root in roots {
            try visit(root, parent: yUpToZUp, depth: 0)
        }
        return ParsedTile(meshes: meshes, copyright: document.asset?.copyright)
    }

    /// Splits a .glb into its JSON and binary chunks.
    private static func chunks(of data: Data) throws -> (json: Data, binary: Data) {
        let bytes = [UInt8](data)
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        guard bytes.count >= 20, uint32(0) == 0x4654_6C67 /* "glTF" */ else { throw ParseError.notGLB }
        var json: Data?
        var binary = Data()
        var offset = 12
        while offset + 8 <= bytes.count {
            let length = Int(uint32(offset))
            let type = uint32(offset + 4)
            let start = offset + 8
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if type == 0x4E4F_534A { json = Data(bytes[start..<end]) }          // "JSON"
            else if type == 0x004E_4942 { binary = Data(bytes[start..<end]) }   // "BIN\0"
            offset = end
        }
        guard let json else { throw ParseError.missingJSON }
        return (json, binary)
    }
}

// MARK: - glTF JSON (only the parts we need)

private struct GLTFDocument: Decodable {
    struct Asset: Decodable { let copyright: String? }
    struct Scene: Decodable { let nodes: [Int]? }

    struct Node: Decodable {
        let matrix: [Double]?
        let translation: [Double]?
        let rotation: [Double]?
        let scale: [Double]?
        let mesh: Int?
        let children: [Int]?

        var localMatrix: simd_double4x4 {
            if let m = matrix, m.count == 16 { // column-major
                return simd_double4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                                SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
            }
            var result = matrix_identity_double4x4
            if let t = translation, t.count == 3 { result.columns.3 = SIMD4(t[0], t[1], t[2], 1) }
            if let r = rotation, r.count == 4 { result *= simd_double4x4(simd_quatd(ix: r[0], iy: r[1], iz: r[2], r: r[3])) }
            if let s = scale, s.count == 3 { result *= simd_double4x4(diagonal: SIMD4(s[0], s[1], s[2], 1)) }
            return result
        }
    }

    struct Mesh: Decodable { let primitives: [Primitive] }
    struct Primitive: Decodable {
        let attributes: [String: Int]
        let indices: Int?
        let material: Int?
        let mode: Int?
    }
    struct Accessor: Decodable {
        let bufferView: Int?
        let byteOffset: Int?
        let componentType: Int
        let normalized: Bool?
        let count: Int
    }
    struct BufferView: Decodable {
        let byteOffset: Int?
        let byteLength: Int
        let byteStride: Int?
    }
    struct Material: Decodable {
        struct PBR: Decodable {
            struct TextureRef: Decodable { let index: Int }
            let baseColorTexture: TextureRef?
        }
        let pbrMetallicRoughness: PBR?
    }
    struct Texture: Decodable { let source: Int? }
    struct Image: Decodable { let bufferView: Int? }

    let asset: Asset?
    let scene: Int?
    let scenes: [Scene]?
    let nodes: [Node]?
    let meshes: [Mesh]?
    let accessors: [Accessor]?
    let bufferViews: [BufferView]?
    let materials: [Material]?
    let textures: [Texture]?
    let images: [Image]?
}

private struct GLTFAccessorReader {
    let document: GLTFDocument
    let binary: Data

    func mesh(for primitive: GLTFDocument.Primitive, transform: simd_double4x4) throws -> TileMesh? {
        guard let positionAccessor = primitive.attributes["POSITION"] else { return nil }
        let raw = try floats(accessor: positionAccessor, components: 3)
        let count = raw.count / 3
        guard count >= 3 else { return nil }

        var positions = [SIMD3<Double>]()
        positions.reserveCapacity(count)
        for i in 0..<count {
            let p = transform * SIMD4(Double(raw[i * 3]), Double(raw[i * 3 + 1]), Double(raw[i * 3 + 2]), 1)
            positions.append(SIMD3(p.x, p.y, p.z))
        }

        var uvs = [SIMD2<Float>](repeating: .zero, count: count)
        if let uvAccessor = primitive.attributes["TEXCOORD_0"] {
            let rawUVs = try floats(accessor: uvAccessor, components: 2)
            if rawUVs.count == count * 2 {
                for i in 0..<count { uvs[i] = SIMD2(rawUVs[i * 2], rawUVs[i * 2 + 1]) }
            }
        }

        var indices = try primitive.indices.map { try self.indices(accessor: $0) } ?? (0..<UInt32(count)).map { $0 }
        indices = indices.count % 3 == 0 && indices.allSatisfy({ $0 < UInt32(count) }) ? indices : []
        guard !indices.isEmpty else { return nil }

        return TileMesh(positions: positions, uvs: uvs, indices: indices, imageData: imageData(material: primitive.material))
    }

    private func floats(accessor index: Int, components: Int) throws -> [Float] {
        let (accessor, start, stride) = try layout(of: index, components: components)
        var result = [Float]()
        result.reserveCapacity(accessor.count * components)
        let normalized = accessor.normalized ?? false
        binary.withUnsafeBytes { raw in
            for i in 0..<accessor.count {
                for c in 0..<components {
                    let offset = start + i * stride + c * Self.size(of: accessor.componentType)
                    switch accessor.componentType {
                    case 5126: result.append(raw.loadUnaligned(fromByteOffset: offset, as: Float.self))
                    case 5123:
                        let value = Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        result.append(normalized ? value / 65535 : value)
                    case 5121:
                        let value = Float(raw.load(fromByteOffset: offset, as: UInt8.self))
                        result.append(normalized ? value / 255 : value)
                    case 5122:
                        let value = Float(raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                        result.append(normalized ? max(value / 32767, -1) : value)
                    case 5120:
                        let value = Float(raw.load(fromByteOffset: offset, as: Int8.self))
                        result.append(normalized ? max(value / 127, -1) : value)
                    default:
                        result.append(0)
                    }
                }
            }
        }
        return result
    }

    private func indices(accessor index: Int) throws -> [UInt32] {
        let (accessor, start, stride) = try layout(of: index, components: 1)
        var result = [UInt32]()
        result.reserveCapacity(accessor.count)
        binary.withUnsafeBytes { raw in
            for i in 0..<accessor.count {
                let offset = start + i * stride
                switch accessor.componentType {
                case 5121: result.append(UInt32(raw.load(fromByteOffset: offset, as: UInt8.self)))
                case 5123: result.append(UInt32(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
                case 5125: result.append(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                default: result.append(0)
                }
            }
        }
        return result
    }

    /// Accessor + byte offset of its first element + stride, after bounds checks.
    private func layout(of index: Int, components: Int) throws -> (GLTFDocument.Accessor, Int, Int) {
        guard let accessor = document.accessors?[safe: index],
              let view = document.bufferViews?[safe: accessor.bufferView ?? -1] else { throw GLBParser.ParseError.badAccessor }
        let elementSize = Self.size(of: accessor.componentType) * components
        let stride = view.byteStride ?? elementSize
        let start = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        guard accessor.count > 0, elementSize > 0, stride >= elementSize,
              start + stride * (accessor.count - 1) + elementSize <= binary.count else { throw GLBParser.ParseError.badAccessor }
        return (accessor, start, stride)
    }

    private func imageData(material index: Int?) -> Data? {
        guard let index,
              let textureIndex = document.materials?[safe: index]?.pbrMetallicRoughness?.baseColorTexture?.index,
              let imageIndex = document.textures?[safe: textureIndex]?.source,
              let viewIndex = document.images?[safe: imageIndex]?.bufferView,
              let view = document.bufferViews?[safe: viewIndex] else { return nil }
        let start = view.byteOffset ?? 0
        guard start >= 0, start + view.byteLength <= binary.count else { return nil }
        return binary.subdata(in: start..<(start + view.byteLength))
    }

    private static func size(of componentType: Int) -> Int {
        switch componentType {
        case 5120, 5121: 1
        case 5122, 5123: 2
        case 5125, 5126: 4
        default: 0
        }
    }
}

extension Array {
    /// nil instead of a crash for out-of-range indices.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
