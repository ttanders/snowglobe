//
//  GlobeRattle.swift
//  Snowglobe
//
//  The hop-and-rattle a globe does when you press Shake: it lifts a little, rattles side to side
//  and lands. Nothing stirs the snow directly here: SnowController feels the glass move, so the
//  snow reacts to this motion exactly as it would to a real shake.
//

import UIKit
import simd

/// Plays a GlobeRattle with its haptics: `start()` it, then call `advance(by:)` every frame and
/// apply the pose it returns to the globe.
@MainActor
final class GlobeRattlePlayer {
    private var elapsed: Float?
    private var nextBeat = 0
    private let tick = UIImpactFeedbackGenerator(style: .rigid)
    private let landing = UIImpactFeedbackGenerator(style: .soft)

    func start() {
        elapsed = 0
        nextBeat = 0
        tick.prepare()
    }

    func advance(by deltaTime: Float) -> GlobeRattle.Pose {
        guard var t = elapsed else { return GlobeRattle.Pose() }
        t += deltaTime
        while nextBeat < GlobeRattle.beats.count, GlobeRattle.beats[nextBeat].time <= t {
            let beat = GlobeRattle.beats[nextBeat]
            nextBeat += 1
            if nextBeat == GlobeRattle.beats.count {
                landing.impactOccurred(intensity: beat.intensity)
            } else {
                tick.impactOccurred(intensity: beat.intensity)
            }
        }
        guard t < GlobeRattle.duration else {
            elapsed = nil
            return GlobeRattle.Pose()
        }
        elapsed = t
        return GlobeRattle.pose(at: t)
    }
}

enum GlobeRattle {
    static let duration: Float = 1.0

    /// Offset from the globe's resting place (globe units; x = sideways to the viewer, y = up) and
    /// roll around the viewing axis (radians).
    struct Pose {
        var offset: SIMD3<Float> = .zero
        var roll: Float = 0
    }

    private static let hop: Float = 0.1
    private static let swing: Float = 0.08
    private static let rattleStart: Float = 0.12
    private static let rattleLength: Float = 0.7
    private static let cycles: Float = 3.5
    private static let landingStart: Float = 0.78

    static func pose(at t: Float) -> Pose {
        guard t > 0, t < duration else { return Pose() }
        // Up, a little bounce while it rattles, then back down.
        let y: Float
        if t < 0.15 {
            let s = t / 0.15
            y = hop * (1 - (1 - s) * (1 - s))
        } else if t < landingStart {
            y = hop + 0.012 * sin((t - 0.15) * 2 * .pi * 2 * cycles / rattleLength)
        } else {
            let s = (t - landingStart) / (duration - landingStart)
            y = hop * (1 - s * s)
        }
        // Side to side, swelling and fading.
        var x: Float = 0
        let s = (t - rattleStart) / rattleLength
        if s > 0, s < 1 {
            x = swing * sin(s * 2 * .pi * cycles) * sin(s * .pi)
        }
        return Pose(offset: SIMD3(x, y, 0), roll: -x * 1.2)
    }

    /// A haptic tap for each change of direction while it rattles (when the snow inside would knock
    /// against the glass), then a soft one as it lands. Times in seconds; intensities 0…1.
    static let beats: [(time: Float, intensity: CGFloat)] = {
        var beats: [(Float, CGFloat)] = []
        let swings = Int(cycles * 2)
        for k in 0..<swings {
            let s = (Float(k) + 0.5) / (cycles * 2)
            beats.append((rattleStart + s * rattleLength, CGFloat(0.35 + 0.65 * sin(s * .pi))))
        }
        beats.append((duration - 0.02, 0.6))
        return beats
    }()
}
