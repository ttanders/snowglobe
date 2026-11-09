//
//  SnowController.swift
//  Snowglobe
//
//  The snow of one live globe. Owns its SnowSimulation and SnowRenderer, and every frame tells the
//  snow how the glass moved: spun on the turntable, rattled by the Shake button, dragged across a
//  table in AR or, on the globe screen (where the globe is "in your hand"), shaken with the iPhone.
//  Also turns a tap into a flick on the glass or a knock on the wooden base.
//

import RealityKit
import UIKit
import simd

@MainActor
final class SnowController {
    enum Tuning {
        /// How hard the iPhone's motion moves the glass: globe units/s² per g of acceleration.
        static let deviceAcceleration: Float = 18
        /// Phone motion below this (g) is ignored: a hand holding a phone still always trembles a bit.
        static let deviceStillness: Float = 0.05
        /// Twisting slower than this (radians/s) is ignored.
        static let deviceTwistStillness: Float = 0.25
        /// Phone acceleration (g) that counts as a deliberate shake.
        static let deliberateShake: Float = 0.8
        /// A new deliberate shake starts once the phone has been calmer than that for this long (seconds).
        static let shakePause: Float = 0.6
        /// Seconds over which the iPhone's sense of down is smoothed.
        static let gravitySmoothing: Float = 0.12
        /// Below this much gravity across the screen (g) the phone is lying nearly flat, and which way is
        /// down across the screen is just noise: the snow keeps the last direction.
        static let flatPhone: Float = 0.25
    }

    enum TapTarget {
        case glass, base
    }

    let simulation: SnowSimulation
    private let renderer: SnowRenderer?
    private weak var globe: Entity?
    private var tracker = GlassMotionTracker()
    private var followsDevice = false
    private var deviceSpin: Float = 0
    /// Seconds since the iPhone last moved like a deliberate shake.
    private var timeSinceShake: Float = .infinity
    private var lastView: SnowView?
    private var needsDraw = true
    /// The iPhone's gravity across the screen (x right, y up), smoothed; nil until it's been read.
    private var screenGravity: SIMD2<Float>?
    /// Down for the snow in world axes, as last worked out from the iPhone.
    private var deviceDown = SIMD3<Float>(0, -1, 0)

    /// Called each time the user deliberately shakes the iPhone (once per shake, as it starts).
    var onDeliberateShake: (() -> Void)?

    /// Adds snow to `globe` (a GlobeEntityFactory globe). `startsSnowing`: drifting down, as if the
    /// globe had just been picked up; otherwise it starts settled.
    init(globe: Entity, startsSnowing: Bool, flakeCount: Int = GlobeMetrics.snowFlakeCount) {
        self.globe = globe
        simulation = SnowSimulation(flakeCount: flakeCount)
        do {
            let renderer = try SnowRenderer(capacity: flakeCount)
            globe.addChild(renderer.entity)
            self.renderer = renderer
        } catch {
            print("SnowController: couldn't make the snow mesh: \(error)")
            renderer = nil
        }
        showContent(globe.findEntity(named: GlobeEntityFactory.dioramaContentName))
        if startsSnowing { simulation.scatter() }
    }

    /// With the globe in your hand (the globe screen), the iPhone's own motion moves the glass too.
    func followDeviceMotion(_ follow: Bool) {
        guard follow != followsDevice else { return }
        followsDevice = follow
        if follow {
            DeviceMotion.shared.start()
        } else {
            DeviceMotion.shared.stop()
            deviceSpin = 0
            timeSinceShake = .infinity
            screenGravity = nil
            deviceDown = SIMD3(0, -1, 0)
        }
    }

    /// Call when the globe goes away.
    func stop() {
        followDeviceMotion(false)
    }

    /// The miniature inside the glass changed: the snow settles on its ground and roofs instead.
    func showContent(_ content: Entity?) {
        simulation.setSurface(content?.components[SnowSurfaceComponent.self]?.field ?? .flat())
        needsDraw = true
    }

    /// Snow drifting down everywhere, as if the globe had just been picked up.
    func scatter() {
        simulation.scatter()
    }

    func shake(strength: Float = 1) {
        simulation.shake(strength: strength)
    }

    /// A tap along a world-space ray: a flick where it meets the glass, or a knock if it hits the base.
    /// Returns what was hit (nil if the tap missed the globe).
    func tap(rayOrigin: SIMD3<Float>, direction: SIMD3<Float>) -> TapTarget? {
        guard let globe else { return nil }
        let toGlobe = globe.transformMatrix(relativeTo: nil).inverse
        let o = toGlobe * SIMD4(rayOrigin, 1)
        let d = toGlobe * SIMD4(direction, 0)
        let origin = SIMD3(o.x, o.y, o.z)
        let ray = simd_normalize(SIMD3(d.x, d.y, d.z))

        if let t = Self.hitSphere(origin: origin, direction: ray, radius: GlobeMetrics.glassRadius) {
            let point = origin + ray * t
            if point.y > GlobeMetrics.groundY {
                simulation.flick(at: point)
                return .glass
            }
        }
        if Self.hitsBase(origin: origin, direction: ray) {
            simulation.knock()
            return .base
        }
        return nil
    }

    // MARK: - Per frame

    /// Moves the snow on by one frame and redraws it. `camera` is the camera's world transform;
    /// `orientation` is the interface orientation (for reading the iPhone's motion).
    func update(deltaTime dt: Float, camera: Transform, orientation: UIInterfaceOrientation = .portrait) {
        guard let globe else { return }
        let world = Transform(matrix: globe.transformMatrix(relativeTo: nil))

        // How the glass itself moved: spun, rattled, dragged…
        let motion = tracker.update(world, deltaTime: dt)
        simulation.jolt(velocityChange: motion.velocityChange, spinChange: motion.spinChange)
        // …and, with the globe in your hand, how the iPhone moved.
        let sample = followsDevice ? DeviceMotion.shared.latest(for: orientation) : nil
        if let sample, dt > 0 {
            joltFromDevice(sample, camera: camera, globe: world, deltaTime: dt)
        }
        // Which way the snow sinks.
        simulation.setGravity(down(from: sample, camera: camera, globe: world, deltaTime: dt))

        let moving = !simulation.isAsleep
        simulation.step(deltaTime: dt)

        let view = Self.view(from: camera, globe: world)
        if moving || needsDraw || view != lastView {
            renderer?.draw(simulation, view: view)
            lastView = view
            needsDraw = false
        }
    }

    private func joltFromDevice(_ sample: DeviceMotion.Sample, camera: Transform, globe: Transform, deltaTime dt: Float) {
        // Screen axes → world (through the camera) → the globe's own axes.
        func globeAxes(_ v: SIMD3<Float>) -> SIMD3<Float> {
            globe.rotation.inverse.act(camera.rotation.act(v))
        }
        var acceleration = sample.acceleration
        let strength = simd_length(acceleration)
        if strength > Tuning.deliberateShake {
            if timeSinceShake > Tuning.shakePause { onDeliberateShake?() }
            timeSinceShake = 0
        } else {
            timeSinceShake += dt
        }
        var velocityChange = SIMD3<Float>.zero
        if strength > Tuning.deviceStillness {
            acceleration *= (strength - Tuning.deviceStillness) / strength
            velocityChange = globeAxes(acceleration) * (Tuning.deviceAcceleration * dt)
        }
        // Twisting the phone around the globe's vertical axis turns the glass under the liquid.
        let twist = globeAxes(sample.rotationRate).y
        let spin = abs(twist) > Tuning.deviceTwistStillness
            ? twist - Tuning.deviceTwistStillness * (twist > 0 ? 1 : -1)
            : 0
        let spinChange = spin - deviceSpin
        deviceSpin = spin
        simulation.jolt(velocityChange: velocityChange, spinChange: spinChange)
    }

    /// Which way the snow sinks, in the globe's axes. In AR (and in the Simulator) that's the real
    /// world's down. With the globe in your hand it's the iPhone's: turn the phone upside down and the
    /// snow falls to the top of the glass. Only the tilt across the screen counts (turning the phone
    /// like a steering wheel); tipping it back to look at it doesn't, or the snow would always slide
    /// to the back of the globe.
    private func down(from sample: DeviceMotion.Sample?, camera: Transform, globe: Transform, deltaTime dt: Float) -> SIMD3<Float> {
        var worldDown = SIMD3<Float>(0, -1, 0)
        if followsDevice {
            if let sample {
                let across = SIMD2(sample.gravity.x, sample.gravity.y)
                let smoothed = screenGravity.map { $0 + (across - $0) * (1 - exp(-dt / Tuning.gravitySmoothing)) } ?? across
                screenGravity = smoothed
                let strength = simd_length(smoothed)
                if strength > Tuning.flatPhone {
                    // Screen right → the camera's right, made level; screen up → straight up.
                    let right = camera.rotation.act([1, 0, 0])
                    let levelRight = SIMD3(right.x, 0, right.z)
                    let sideways = simd_length(levelRight) > 1e-3 ? simd_normalize(levelRight) : SIMD3<Float>(1, 0, 0)
                    deviceDown = sideways * (smoothed.x / strength) + SIMD3(0, smoothed.y / strength, 0)
                }
            }
            worldDown = deviceDown
        }
        return globe.rotation.inverse.act(worldDown)
    }

    private static func view(from camera: Transform, globe: Transform) -> SnowView {
        let toGlobe = globe.matrix.inverse
        func direction(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let d = toGlobe * SIMD4(v, 0)
            return simd_normalize(SIMD3(d.x, d.y, d.z))
        }
        let eye = toGlobe * SIMD4(camera.translation, 1)
        return SnowView(right: direction(camera.rotation.act([1, 0, 0])),
                        up: direction(camera.rotation.act([0, 1, 0])),
                        toward: simd_normalize(SIMD3(eye.x, eye.y, eye.z)))
    }

    // MARK: - Hit testing (globe units)

    /// Distance along a unit ray to where it first enters (or, from inside, leaves) a sphere at the origin.
    private static func hitSphere(origin: SIMD3<Float>, direction: SIMD3<Float>, radius: Float) -> Float? {
        let b = simd_dot(origin, direction)
        let c = simd_dot(origin, origin) - radius * radius
        let discriminant = b * b - c
        guard discriminant >= 0 else { return nil }
        let root = discriminant.squareRoot()
        if -b - root >= 0 { return -b - root }
        return -b + root >= 0 ? -b + root : nil
    }

    /// Whether a ray hits the pedestal (its sides, or the ring of its top around the glass).
    private static func hitsBase(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Bool {
        let radius = GlobeMetrics.baseRadius + 0.06
        // Sides: a cylinder from the bottom of the plinth up to the top of the pedestal.
        let a = direction.x * direction.x + direction.z * direction.z
        if a > 1e-8 {
            let b = origin.x * direction.x + origin.z * direction.z
            let c = origin.x * origin.x + origin.z * origin.z - radius * radius
            let discriminant = b * b - a * c
            if discriminant >= 0 {
                let root = discriminant.squareRoot()
                for t in [(-b - root) / a, (-b + root) / a] where t >= 0 {
                    let y = origin.y + direction.y * t
                    if y >= GlobeMetrics.baseBottomY, y <= GlobeMetrics.groundY + 0.02 { return true }
                }
            }
        }
        // Top: the ring of wood and brass around the bottom of the glass.
        if abs(direction.y) > 1e-6 {
            let t = (GlobeMetrics.groundY - origin.y) / direction.y
            if t >= 0 {
                let point = origin + direction * t
                let distance = (point.x * point.x + point.z * point.z).squareRoot()
                if distance <= radius { return true }
            }
        }
        return false
    }
}

/// Works out how a globe moved since the last frame from its world transform: the change in its
/// velocity (globe units/s, in its own axes) and in its spin around its own vertical axis (radians/s).
/// Fingers move a globe in uneven steps (touches don't arrive in time with frames), so velocities are
/// smoothed: otherwise a slow, steady drag would read as violent jerking. Jumps (a reset, re-placing
/// in AR) and resizing are ignored.
struct GlassMotionTracker {
    /// Accelerations below these are jitter, not motion (globe units/s², radians/s²).
    static let stillAcceleration: Float = 2
    static let stillSpinAcceleration: Float = 1
    /// Seconds over which velocity and spin are smoothed.
    static let velocitySmoothing: Float = 0.08
    static let spinSmoothing: Float = 0.15
    /// Moving or turning more than this in one frame is a jump, not a motion (globe units, radians).
    static let jumpDistance: Float = 0.5
    static let jumpAngle: Float = 0.5

    private var previous: Transform?
    private var velocity: SIMD3<Float> = .zero // world axes, globe units/s
    private var spin: Float = 0

    mutating func update(_ transform: Transform, deltaTime dt: Float) -> (velocityChange: SIMD3<Float>, spinChange: Float) {
        defer { previous = transform }
        guard dt > 0, let last = previous,
              abs(transform.scale.x / max(last.scale.x, 1e-6) - 1) < 0.002 else {
            velocity = .zero
            spin = 0
            return (.zero, 0)
        }
        let moved = (transform.translation - last.translation) / max(transform.scale.x, 1e-6)
        var turn = last.rotation.inverse * transform.rotation // this frame's turn, in the globe's own axes
        if turn.real < 0 { turn = simd_quatf(vector: -turn.vector) }
        let angle = turn.angle
        guard simd_length(moved) < Self.jumpDistance, angle < Self.jumpAngle else {
            velocity = .zero
            spin = 0
            return (.zero, 0)
        }

        let newVelocity = velocity + (moved / dt - velocity) * (1 - exp(-dt / Self.velocitySmoothing))
        let rawSpin = angle > 1e-7 ? turn.axis.y * angle / dt : 0
        let newSpin = spin + (rawSpin - spin) * (1 - exp(-dt / Self.spinSmoothing))
        var velocityChange = transform.rotation.inverse.act(newVelocity - velocity)
        var spinChange = newSpin - spin
        velocity = newVelocity
        spin = newSpin

        // Soft dead zones, so tracking jitter doesn't keep stirring the snow.
        let acceleration = simd_length(velocityChange) / dt
        velocityChange = acceleration > Self.stillAcceleration
            ? velocityChange * ((acceleration - Self.stillAcceleration) / acceleration)
            : .zero
        let spinAcceleration = abs(spinChange) / dt
        spinChange = spinAcceleration > Self.stillSpinAcceleration
            ? spinChange * ((spinAcceleration - Self.stillSpinAcceleration) / spinAcceleration)
            : 0
        return (velocityChange, spinChange)
    }
}
