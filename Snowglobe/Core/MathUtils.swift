//
//  MathUtils.swift
//  Snowglobe
//
//  CORE — tiny shared math helpers. Use these instead of redefining your own.
//

import Foundation
import simd

@inline(__always) func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}

@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}

/// Hermite smoothstep: 0 below `edge0`, 1 above `edge1`.
@inline(__always) func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)
}

/// Deterministic pseudo-random generator (SplitMix64).
/// Use it for procedural content so the same place always produces the same miniature.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// Seed derived from a coordinate (stable across launches, unlike `Hasher`).
    init(coordinate: GeoCoordinate, salt: UInt64 = 0) {
        let lat = UInt64(bitPattern: Int64((coordinate.latitude * 1e6).rounded()))
        let lon = UInt64(bitPattern: Int64((coordinate.longitude * 1e6).rounded()))
        self.init(seed: lat &* 0x9E3779B97F4A7C15 ^ lon &* 0xC2B2AE3D27D4EB4F ^ salt)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform Float in [0, 1).
    mutating func nextUnit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }
}

/// Stable 64-bit FNV-1a hash. Swift's `hashValue` is randomly seeded per launch — never use it for procedural content.
func stableHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return hash
}

func stableHash(_ value: Int64) -> UInt64 {
    stableHash(String(value))
}
