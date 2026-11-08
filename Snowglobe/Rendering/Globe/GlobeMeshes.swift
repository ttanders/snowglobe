//
//  GlobeMeshes.swift
//  Snowglobe
//
//  Small custom meshes RealityKit can't generate directly.
//  Triangles are counter-clockwise when seen from outside (RealityKit's front faces).
//

import RealityKit

@MainActor
enum GlobeMeshes {
    /// The part of a sphere above `bottomY` (an open glass dome), normals pointing outward.
    static func dome(radius: Float, bottomY: Float, segments: Int = 72, rings: Int = 36) -> MeshResource {
        let bottomPolarAngle = acos(clamp(bottomY / radius, -1, 1)) // 0 = top of the sphere
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for ring in 0...rings {
            let theta = bottomPolarAngle * Float(ring) / Float(rings)
            for segment in 0...segments {
                let phi = 2 * Float.pi * Float(segment) / Float(segments)
                let normal = SIMD3<Float>(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                positions.append(normal * radius)
                normals.append(normal)
            }
        }
        let stride = UInt32(segments + 1)
        for ring in 0..<UInt32(rings) {
            for segment in 0..<UInt32(segments) {
                let upper = ring * stride + segment
                let lower = upper + stride
                indices += [upper, upper + 1, lower, upper + 1, lower + 1, lower]
            }
        }
        return (try? make("Dome", positions, normals, indices)) ?? .generateSphere(radius: radius)
    }

    /// A prism with a regular-polygon cross-section from y = 0 up to y = `height`, with a flat face
    /// toward +Z when `sides` is a multiple of 4. Top face and sides only (the bottom is never seen).
    static func prism(sides: Int, circumradius: Float, height: Float) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let step = 2 * Float.pi / Float(sides)
        func corner(_ index: Int, _ y: Float) -> SIMD3<Float> {
            let angle = (Float(index) + 0.5) * step
            return SIMD3(circumradius * cos(angle), y, circumradius * sin(angle))
        }

        // Top face: a fan around the centre.
        positions.append([0, height, 0])
        normals.append([0, 1, 0])
        for index in 0..<sides {
            positions.append(corner(index, height))
            normals.append([0, 1, 0])
        }
        for index in 0..<sides {
            let current = UInt32(1 + index)
            let next = UInt32(1 + (index + 1) % sides)
            indices += [0, next, current]
        }

        // Sides: one flat-shaded quad per edge.
        for index in 0..<sides {
            let midAngle = (Float(index) + 1) * step
            let normal = SIMD3<Float>(cos(midAngle), 0, sin(midAngle))
            let base = UInt32(positions.count)
            positions += [corner(index, height), corner(index + 1, height), corner(index, 0), corner(index + 1, 0)]
            normals += [normal, normal, normal, normal]
            indices += [base, base + 1, base + 2, base + 1, base + 3, base + 2]
        }
        let width = circumradius * 2
        return (try? make("Prism", positions, normals, indices))
            ?? .generateBox(width: width, height: height, depth: width)
    }

    private static func make(_ name: String, _ positions: [SIMD3<Float>], _ normals: [SIMD3<Float>],
                             _ indices: [UInt32]) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }
}
