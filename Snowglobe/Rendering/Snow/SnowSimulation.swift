//
//  SnowSimulation.swift
//  Snowglobe
//
//  The snow inside a globe: ~1,500 flakes in a slow, syrupy liquid. Pure physics, no RealityKit:
//  SnowRenderer draws it and SnowController feeds it the globe's motion.
//
//  Everything is in globe units (glass radius 1, see GlobeMetrics) and seen from the glass. When
//  the glass is jerked one way, the snow lags the other way; when it's spun, the liquid lags behind
//  and then keeps swirling after the glass stops, like tea in a cup.
//
//  The liquid's flow at a point is the sum of
//    • slosh:      a drift opposite to the glass's latest jolts,
//    • swirl:      a rotation around the globe's vertical axis,
//    • turbulence: a chaotic, swirly flow (an "ABC flow", which never piles snow up in one place)
//                  that shaking pumps up,
//  and all three fade away within a few seconds. Flakes ride the flow, sink slowly while
//  fluttering and tumbling, bounce off the glass, and come to rest on the ground and on rooftops
//  (`surface`). A resting flake is picked up again when the flow around it is strong enough.
//  Once everything rests and the liquid is still, the simulation sleeps until it's stirred.
//
//  Down is wherever `gravity` points. Turn the globe upside down and the snow sinks to the top of
//  the glass and piles up there; tip it past snow's angle of repose and settled snow slides off the
//  roofs, piling against walls and the glass.
//

import Foundation
import simd

/// One flake. Sizes are in globe units, speeds in globe units per second.
struct SnowFlake {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float> = .zero
    /// Half the drawn size.
    var size: Float
    /// Sinking speed through still liquid.
    var sinkSpeed: Float
    /// How quickly the flake takes on the liquid's speed (per second; big flakes react slower).
    var grip: Float
    /// Flow speed that picks the flake up off the ground (it only settles where the flow is calmer).
    var liftSpeed: Float
    /// A sinking flake drifts around a little circle at `flutterRate` (radians per second) from `phase`.
    var phase: Float
    var flutterRate: Float
    /// Tumbling angle and speed (radians, radians per second); the renderer turns these into glints.
    var tumble: Float
    var tumbleRate: Float
    /// The direction this flake's flat face points when `tumble` is 0 (unit vector); varies which flakes glint.
    var facet: SIMD3<Float>
    /// Glitter is smaller and flashes far more often than plain snow.
    var isGlitter: Bool
    /// How far a flake slides down the curved glass before it stops (0 = as soon as the glass is
    /// gentler than snow's angle of repose, 1 = nearly to the lowest point). Varies per flake, so
    /// snow on the glass piles up thickest in the middle instead of in a ring.
    var slide: Float = 0
    var isResting = false
    /// This flake's own wandering in a storm (slowly changing, different for every flake), so the
    /// snow tumbles about chaotically instead of flowing in streams. Scaled by the turbulence.
    var wander: SIMD3<Float> = .zero
}

final class SnowSimulation {
    /// Snow feel. Speeds are globe units per second (the glass radius is 1).
    enum Tuning {
        // Flakes
        /// Half-sizes of the flakes (most are near the small end).
        static let sizeRange: ClosedRange<Float> = 0.009...0.02
        static let glitterShare: Float = 0.18
        /// Sinking speed through still liquid: ~12 s from the top of the glass to the ground.
        static let sinkSpeedRange: ClosedRange<Float> = 0.075...0.13
        /// How quickly flakes follow the liquid (per second).
        static let gripRange: ClosedRange<Float> = 3.5...7
        /// Flow speed needed to lift a resting flake (each flake picks its own from this range, so a
        /// gentle stir lifts only some of the snow and a hard shake lifts all of it).
        static let liftSpeedRange: ClosedRange<Float> = 0.16...0.85
        /// Radius of a sinking flake's flutter, as a share of its sinking speed.
        static let flutter: Float = 0.45
        /// How far a resting flake's centre sits above the surface, as a share of its size.
        static let restHeight: Float = 0.55
        /// Resting flakes start out spread over this radius.
        static let restingSpread: Float = 0.84

        // Liquid
        /// Seconds for turbulence, swirl and slosh to fade to about a third.
        static let turbulenceFade: Float = 2.2
        static let swirlFade: Float = 2.6
        static let sloshFade: Float = 0.35
        static let maxTurbulence: Float = 1.1
        static let maxSwirl: Float = 9
        static let maxSlosh: Float = 2
        /// Eddy size of the turbulence (radians per globe unit; 2.6 ≈ one eddy per globe radius),
        /// plus a layer of smaller, faster eddies on top.
        static let eddyScale: Float = 2.6
        static let smallEddyScale: Float = 6.1
        static let smallEddyShare: Float = 0.45
        /// Each flake's own wandering in a storm: how long it keeps a direction (s) and how fast it goes
        /// (globe units/s at full turbulence).
        static let wanderTime: Float = 0.5
        static let wanderSpeed: Float = 0.8
        /// Share of the turbulence that counts toward lifting resting snow on top of the flow itself.
        static let turbulenceLift: Float = 0.5
        /// Share of the glass's jolts that the snow lags behind (0 = moves with the glass, 1 = stays put).
        static let lag: Float = 0.45
        /// Share of a change in the glass's spin that the liquid lags behind.
        static let swirlLag: Float = 0.9
        /// Turbulence added per globe unit/s of jolt. (Spinning only swirls the liquid: turning the
        /// globe to look at it shouldn't whip up a storm, though a hard flick lifts some snow.)
        static let joltTurbulence: Float = 0.11
        /// Share of the swirl's speed that counts toward lifting resting snow (it mostly slides past it):
        /// turning the globe to look at it stirs only the lightest flakes; a hard flick lifts them all.
        static let swirlLift: Float = 0.35
        /// A flick on the glass reaches flakes this far away.
        static let flickReach: Float = 0.8

        // Glass and buildings
        /// Flakes stay inside this radius (the glass is a little thick).
        static let containment = GlobeMetrics.snowContainmentRadius
        /// A rise in the surface steeper than this between two steps is a wall: flakes drifting
        /// sideways into it stay on their side instead of popping up onto the roof.
        static let wallStep: Float = 0.02
        /// Snow stays put on a surface tipped less than snow's angle of repose (about 37°) from level,
        /// and slides off one tipped further. This is the cosine of that angle.
        static let repose: Float = 0.8
        /// Resting snow is checked again when gravity turns more than about 3° (the cosine of that).
        static let gravityRecheck: Float = 0.9986
        /// Longest step simulated at once; after a hitch the snow slows down instead of jumping.
        static let maxStep: Float = 1.0 / 20
    }

    private(set) var flakes: [SnowFlake] = []
    /// Where flakes come to rest.
    private(set) var surface: SnowHeightField
    /// True when every flake rests and the liquid is still; `step` does nothing until it's stirred.
    private(set) var isAsleep = false
    /// Seconds simulated so far.
    private(set) var time: Float = 0
    /// Which way the snow sinks (unit vector, globe axes). See `setGravity`.
    private(set) var gravity = SIMD3<Float>(0, -1, 0)
    /// Two directions across `gravity`, for fluttering and for throwing snow sideways.
    private var across1 = SIMD3<Float>(0, 0, 1)
    private var across2 = SIMD3<Float>(1, 0, 0)
    /// The gravity resting snow was last checked against.
    private var checkedGravity = SIMD3<Float>(0, -1, 0)

    // The liquid's motion, all relative to the glass.
    private var turbulence: Float = 0
    private var swirl: Float = 0
    private var slosh: SIMD3<Float> = .zero
    /// Velocity change every drifting flake takes at the next step (the glass jolting around it).
    private var kick: SIMD3<Float> = .zero
    /// Drives how the turbulent eddies change; runs faster in a storm.
    private var flowClock: Float = 0
    private var flowPhases = SIMD3<Float>(1.3, 4.1, 2.7)
    private var smallFlowPhases = SIMD3<Float>(0.4, 2.2, 5.0)
    private var random: SeededRandom

    init(flakeCount: Int, surface: SnowHeightField = .flat(), seed: UInt64 = .random(in: 0 ... .max)) {
        self.surface = surface
        random = SeededRandom(seed: seed)
        flakes.reserveCapacity(flakeCount)
        for _ in 0..<max(flakeCount, 0) {
            flakes.append(makeFlake())
        }
        settle()
    }

    // MARK: - Setting the scene

    /// Lays every flake down on the ground and roofs, and stills the liquid.
    func settle() {
        for i in flakes.indices {
            let radius = random.nextUnit().squareRoot() * Tuning.restingSpread
            let angle = random.nextFloat(in: 0...(2 * .pi))
            let x = cos(angle) * radius, z = sin(angle) * radius
            flakes[i].position = SIMD3(x, restingY(x: x, z: z, size: flakes[i].size), z)
            flakes[i].velocity = .zero
            flakes[i].isResting = true
        }
        turbulence = 0
        swirl = 0
        slosh = .zero
        kick = .zero
        isAsleep = true
        dropUnsupportedSnow() // the globe might be tipped right now
    }

    /// Scatters every flake through the liquid, swirling gently: a globe just picked up off the shelf.
    func scatter() {
        wake()
        for i in flakes.indices {
            flakes[i].position = randomPointInLiquid(margin: flakes[i].size)
            flakes[i].velocity = randomDirection() * random.nextFloat(in: 0...0.1)
            flakes[i].isResting = false
        }
        turbulence = max(turbulence, 0.22)
        swirl += randomSign() * 0.5
    }

    /// New ground and roofs (the miniature inside changed): resting snow moves onto them, and any
    /// flake now inside a building pops up onto its roof. Snow lying on the glass stays there.
    func setSurface(_ field: SnowHeightField) {
        surface = field
        for i in flakes.indices where !isTouchingGlass(flakes[i]) {
            let floor = restingY(x: flakes[i].position.x, z: flakes[i].position.z, size: flakes[i].size)
            if flakes[i].isResting || flakes[i].position.y < floor {
                flakes[i].position.y = floor
                flakes[i].velocity = .zero
                flakes[i].isResting = true
            }
        }
        dropUnsupportedSnow()
    }

    /// Which way is down for the snow (globe axes; any length). Turn the globe over and the snow
    /// sinks toward the top of the glass; tip it past snow's angle of repose and settled snow slides off.
    func setGravity(_ direction: SIMD3<Float>) {
        let length = simd_length(direction)
        guard length > 1e-4 else { return }
        let down = direction / length
        guard simd_dot(down, gravity) < 0.999_999 else { return }
        gravity = down
        let helper: SIMD3<Float> = abs(down.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
        across1 = simd_normalize(simd_cross(helper, down))
        across2 = simd_cross(down, across1)
        if simd_dot(down, checkedGravity) < Tuning.gravityRecheck {
            checkedGravity = down
            dropUnsupportedSnow()
        }
    }

    // MARK: - Stirring

    /// The glass moved. `velocityChange` is how much its velocity changed since the last call
    /// (globe units/s, globe axes); `spinChange` how much its spin around its vertical axis changed (radians/s).
    func jolt(velocityChange: SIMD3<Float>, spinChange: Float) {
        let speed = simd_length(velocityChange)
        guard speed > 1e-5 || abs(spinChange) > 1e-5 else { return }
        wake()
        // The snow, and the liquid along the walls, lag behind the glass…
        kick -= velocityChange * Tuning.lag
        slosh = limited(slosh - velocityChange * Tuning.lag, to: Tuning.maxSlosh)
        // …and the liquid keeps spinning the way it was while the glass changes its spin.
        swirl = clamp(swirl - spinChange * Tuning.swirlLag, -Tuning.maxSwirl, Tuning.maxSwirl)
        turbulence = min(Tuning.maxTurbulence, turbulence + speed * Tuning.joltTurbulence)
    }

    /// A shake by hand: the settled snow is thrown up (all of it at full strength), the liquid
    /// churns and swirls a little.
    func shake(strength: Float = 1) {
        wake()
        turbulence = min(Tuning.maxTurbulence, turbulence + 0.95 * strength)
        swirl = clamp(swirl + randomSign() * 1.2 * strength, -Tuning.maxSwirl, Tuning.maxSwirl)
        for i in flakes.indices where flakes[i].isResting && random.nextUnit() < strength {
            let angle = random.nextFloat(in: 0...(2 * .pi))
            let sideways = random.nextFloat(in: 0.2...0.9) * strength
            flakes[i].isResting = false
            flakes[i].velocity = (across1 * cos(angle) + across2 * sin(angle)) * sideways
                - gravity * (random.nextFloat(in: 0.6...1.8) * strength)
            flakes[i].wander = randomDirection() * Tuning.wanderSpeed
        }
    }

    /// A finger flicking the glass at `point` (on the glass, globe units): nearby snow bursts away
    /// from the finger, and the knock stirs the rest a little.
    func flick(at point: SIMD3<Float>, strength: Float = 1) {
        wake()
        let inward = -simd_normalize(point)
        turbulence = min(Tuning.maxTurbulence, turbulence + 0.35 * strength)
        slosh = limited(slosh + inward * (0.25 * strength), to: Tuning.maxSlosh)
        let reach = Tuning.flickReach
        for i in flakes.indices {
            let offset = flakes[i].position - point
            let distance = simd_length(offset)
            guard distance < reach else { continue }
            let falloff = 1 - distance / reach
            let away = distance > 1e-4 ? offset / distance : inward
            var push = simd_normalize(away + inward * 0.5) * (2.4 * strength * falloff * falloff)
            if flakes[i].isResting {
                // Settled snow puffs up and away (it can't go down into what it's lying on).
                let up = -gravity
                let along = simd_dot(push, up)
                push += up * (abs(along) - along + (0.5 + random.nextFloat(in: 0...0.6)) * strength * falloff)
                flakes[i].isResting = false
                flakes[i].velocity = push
                flakes[i].wander = randomDirection() * Tuning.wanderSpeed
            } else {
                flakes[i].velocity += push
            }
        }
    }

    /// A knock on the wooden base: the whole globe jumps a little and some snow hops up.
    func knock(strength: Float = 1) {
        wake()
        turbulence = min(Tuning.maxTurbulence, turbulence + 0.28 * strength)
        slosh = limited(slosh - gravity * (0.35 * strength), to: Tuning.maxSlosh)
    }

    // MARK: - Stepping

    func step(deltaTime: Float) {
        let dt = min(max(deltaTime, 0), Tuning.maxStep)
        guard dt > 0, !isAsleep else { return }
        time += dt

        turbulence *= exp(-dt / Tuning.turbulenceFade)
        swirl *= exp(-dt / Tuning.swirlFade)
        slosh *= exp(-dt / Tuning.sloshFade)
        flowClock += dt * (0.35 + 1.3 * turbulence)
        flowPhases = SIMD3(1.3 + 0.9 * flowClock, 4.1 - 0.7 * flowClock, 2.7 + 0.8 * flowClock)
        smallFlowPhases = SIMD3(0.4 - 1.7 * flowClock, 2.2 + 1.5 * flowClock, 5.0 + 1.9 * flowClock)

        let kick = self.kick
        self.kick = .zero
        let kickSpeed = simd_length(kick)
        let stirring = turbulence > 0.003 || abs(swirl) > 0.01 || simd_length_squared(slosh) > 1e-5 || kickSpeed > 0
        var anyDrifting = false
        // Each flake's wandering keeps its direction for about `wanderTime`, then drifts to another.
        let wanderKeep = exp(-dt / Tuning.wanderTime)
        let wanderNudge = Tuning.wanderSpeed * (1 - wanderKeep * wanderKeep).squareRoot()

        var flakes = self.flakes
        self.flakes = [] // keeps `flakes` uniquely owned, so it's updated in place
        flakes.withUnsafeMutableBufferPointer { buffer in
            for i in buffer.indices {
                var flake = buffer[i]
                if flake.isResting {
                    guard stirring else { continue }
                    let agitation = liftingFlow(at: flake.position) + kickSpeed + turbulence * Tuning.turbulenceLift
                    guard agitation > flake.liftSpeed else { continue }
                    // Swept up: off whatever it lay on with the flow, plus a little hop.
                    flake.isResting = false
                    flake.velocity = flow(at: flake.position) + kick
                    flake.velocity -= gravity * ((0.2 + 0.3 * min(agitation, 1.5)) * random.nextFloat(in: 0.5...1))
                } else {
                    flake.velocity += kick
                }
                if turbulence > 0.01 {
                    flake.wander = flake.wander * wanderKeep + randomDirection() * wanderNudge
                }
                advance(&flake, dt: dt)
                if !flake.isResting { anyDrifting = true }
                buffer[i] = flake
            }
        }
        self.flakes = flakes

        if !anyDrifting && !stirring {
            isAsleep = true
            turbulence = 0
            swirl = 0
            slosh = .zero
        }
    }

    /// Moves one drifting flake through the liquid and handles the glass, the ground and walls.
    private func advance(_ flake: inout SnowFlake, dt: Float) {
        let liquid = flow(at: flake.position)
        let angle = flake.phase + time * flake.flutterRate
        let flutter = (across1 * cos(angle) + across2 * sin(angle)) * (flake.sinkSpeed * Tuning.flutter)
        var target = liquid + gravity * flake.sinkSpeed + flutter
        target += flake.wander * min(turbulence, 1)
        flake.velocity += (target - flake.velocity) * (1 - exp(-flake.grip * dt))

        let old = flake.position
        flake.position += flake.velocity * dt
        flake.tumble += flake.tumbleRate * dt * (1 + 2.5 * min(1, simd_length(flake.velocity)))
        func calm() -> Bool { liftingFlow(at: flake.position) < flake.liftSpeed }

        // The glass: slide along it, bouncing back a little. Where it's the low side (the globe
        // turned over or tipped), snow settles on it once the liquid is calm.
        var settlesOnGlass = false
        let reach = Tuning.containment - flake.size
        let distanceSquared = simd_length_squared(flake.position)
        if distanceSquared > reach * reach {
            let normal = flake.position / distanceSquared.squareRoot()
            flake.position = normal * reach
            let outward = simd_dot(flake.velocity, normal)
            if outward > 0 { flake.velocity -= normal * (outward * 1.3) }
            let stopsAt = Tuning.repose + (1 - Tuning.repose) * 0.85 * flake.slide
            settlesOnGlass = simd_dot(normal, gravity) >= stopsAt && calm()
        }

        // The ground, roofs and walls.
        var floor = restingY(x: flake.position.x, z: flake.position.z, size: flake.size)
        if flake.position.y < floor {
            let oldFloor = restingY(x: old.x, z: old.z, size: flake.size)
            if floor > oldFloor + Tuning.wallStep && old.y >= oldFloor - 0.001 {
                // Drifted sideways into a wall: stay on this side of it…
                let into = SIMD2(flake.position.x - old.x, flake.position.z - old.z)
                flake.position.x = old.x
                flake.position.z = old.z
                flake.velocity.x *= -0.3
                flake.velocity.z *= -0.3
                floor = oldFloor
                // …and, with the globe tipped so far that the wall is the low side, pile up against it.
                if -gravity.y < Tuning.repose, simd_dot(into, SIMD2(gravity.x, gravity.z)) > 0, calm() {
                    flake.position.y = max(flake.position.y, floor)
                    flake.isResting = true
                    flake.velocity = .zero
                    return
                }
            }
            if flake.position.y < floor {
                flake.position.y = floor
                if -gravity.y >= Tuning.repose {
                    // Landed on level-enough ground or a roof.
                    if calm() {
                        flake.isResting = true
                        flake.velocity = .zero
                        return
                    }
                    flake.velocity.y = abs(flake.velocity.y) * 0.3
                } else {
                    // Tipped too far for snow to stay on it: slide along it.
                    flake.velocity.y = max(flake.velocity.y, 0)
                }
            }
        }
        if settlesOnGlass {
            flake.isResting = true
            flake.velocity = .zero
        }
    }

    // MARK: - The liquid

    /// Velocity of the liquid at `p`. Next to the glass it can only run along it, not into it.
    private func flow(at p: SIMD3<Float>) -> SIMD3<Float> {
        var u = slosh + SIMD3(p.z, 0, -p.x) * swirl + turbulentFlow(at: p)
        let r = simd_length(p)
        if r > 0.72 {
            let normal = p / r
            let outward = simd_dot(u, normal)
            if outward > 0 { u -= normal * (outward * smoothstep(0.72, 0.93, r)) }
        }
        return u
    }

    /// How hard the liquid tugs at a resting flake at `p` (the swirl mostly slides over it).
    private func liftingFlow(at p: SIMD3<Float>) -> Float {
        simd_length(slosh + turbulentFlow(at: p)) + Tuning.swirlLift * abs(swirl) * (p.x * p.x + p.z * p.z).squareRoot()
    }

    /// An ABC (Arnold–Beltrami–Childress) flow: chaotic, swirly and volume-preserving, so it mixes
    /// the snow without bunching it up. Calmer next to the glass, so snow doesn't pile against it.
    private func turbulentFlow(at p: SIMD3<Float>) -> SIMD3<Float> {
        guard turbulence > 0.0005 else { return .zero }
        let nearGlass = smoothstep(0.75, 0.95, simd_length(p))
        let big = Self.abcFlow(p * Tuning.eddyScale + flowPhases)
        let small = Self.abcFlow(p * Tuning.smallEddyScale + smallFlowPhases)
        return (big + small * Tuning.smallEddyShare) * (turbulence / 1.5 * (1 - nearGlass))
    }

    /// One ABC flow with A = 1, B = 0.8, C = 0.6, at `q` (already scaled and shifted). About 1.3 long on average.
    private static func abcFlow(_ q: SIMD3<Float>) -> SIMD3<Float> {
        let sz = sin(q.z), cz = cos(q.z), sy = sin(q.y), cy = cos(q.y), sx = sin(q.x), cx = cos(q.x)
        return SIMD3(sz + 0.6 * cy, 0.8 * sx + cz, 0.6 * sy + 0.8 * cx)
    }

    // MARK: - Helpers

    private func restingY(x: Float, z: Float, size: Float) -> Float {
        surface.surfaceY(x: x, z: z) + size * Tuning.restHeight
    }

    /// Resting flakes that nothing holds up any more (gravity turned) start sliding or falling.
    private func dropUnsupportedSnow() {
        for i in flakes.indices where flakes[i].isResting && !isSupported(flakes[i]) {
            flakes[i].isResting = false
            flakes[i].velocity = .zero
            wake()
        }
    }

    /// Whether something still holds a resting flake up, with gravity the way it is now: the glass
    /// or the ground (if tipped less than snow's angle of repose), or a wall it's pressed against.
    private func isSupported(_ flake: SnowFlake) -> Bool {
        let p = flake.position
        if isTouchingGlass(flake), simd_dot(p / simd_length(p), gravity) >= Tuning.repose {
            return true
        }
        if p.y <= restingY(x: p.x, z: p.z, size: flake.size) + 0.005, -gravity.y >= Tuning.repose {
            return true
        }
        // A wall: the surface rises just downhill of the flake.
        let downhill = SIMD2(gravity.x, gravity.z)
        let run = simd_length(downhill)
        guard run > 1e-3 else { return false }
        let step = downhill / run * (2 * surface.extent / Float(max(surface.resolution, 1)))
        return restingY(x: p.x + step.x, z: p.z + step.y, size: flake.size) > p.y + 0.005
    }

    private func isTouchingGlass(_ flake: SnowFlake) -> Bool {
        simd_length(flake.position) >= Tuning.containment - flake.size - 0.003
    }

    private func wake() {
        isAsleep = false
    }

    private func makeFlake() -> SnowFlake {
        let isGlitter = random.nextUnit() < Tuning.glitterShare
        // Squaring a uniform pick favours small flakes, with the odd big one.
        let pick = random.nextUnit()
        let heft = pick * pick // 0 = smallest … 1 = biggest
        let size = lerp(Tuning.sizeRange.lowerBound, Tuning.sizeRange.upperBound, heft) * (isGlitter ? 0.75 : 1)
        let sink = lerp(Tuning.sinkSpeedRange.lowerBound, Tuning.sinkSpeedRange.upperBound,
                        0.35 * heft + 0.65 * random.nextUnit()) * (isGlitter ? 0.85 : 1)
        return SnowFlake(
            position: .zero,
            size: size,
            sinkSpeed: sink,
            grip: lerp(Tuning.gripRange.upperBound, Tuning.gripRange.lowerBound, heft),
            liftSpeed: random.nextFloat(in: Tuning.liftSpeedRange),
            phase: random.nextFloat(in: 0...(2 * .pi)),
            flutterRate: random.nextFloat(in: 0.7...1.8) * randomSign(),
            tumble: random.nextFloat(in: 0...(2 * .pi)),
            tumbleRate: random.nextFloat(in: 1.5...4.5) * (isGlitter ? 1.8 : 1) * randomSign(),
            facet: randomDirection(),
            isGlitter: isGlitter,
            slide: random.nextUnit()
        )
    }

    private func randomPointInLiquid(margin: Float) -> SIMD3<Float> {
        let reach = Tuning.containment - margin
        for _ in 0..<40 {
            let p = SIMD3(random.nextFloat(in: -1...1), random.nextFloat(in: -1...1), random.nextFloat(in: -1...1)) * reach
            if simd_length_squared(p) < reach * reach, p.y > restingY(x: p.x, z: p.z, size: margin) + 0.03 {
                return p
            }
        }
        return SIMD3(0, 0.3, 0)
    }

    private func randomDirection() -> SIMD3<Float> {
        let z = random.nextFloat(in: -1...1)
        let angle = random.nextFloat(in: 0...(2 * .pi))
        let r = max(0, 1 - z * z).squareRoot()
        return SIMD3(r * cos(angle), r * sin(angle), z)
    }

    private func randomSign() -> Float {
        random.nextUnit() < 0.5 ? -1 : 1
    }

    private func limited(_ v: SIMD3<Float>, to maxLength: Float) -> SIMD3<Float> {
        let length = simd_length(v)
        return length > maxLength ? v * (maxLength / length) : v
    }
}
