//
//  DeviceMotion.swift
//  Snowglobe
//
//  The iPhone's own motion (Core Motion). On the globe screen the globe is "in your hand", so
//  shaking or twisting the phone shakes or twists the glass (see SnowController). One shared
//  motion manager, started while any globe screen is open; reading it needs no permission.
//

import CoreMotion
import UIKit
import simd

@MainActor
final class DeviceMotion {
    static let shared = DeviceMotion()

    struct Sample {
        /// Acceleration the user gives the device (gravity removed), in g, in screen axes:
        /// x to the right, y up, z out of the screen toward the viewer.
        var acceleration: SIMD3<Float>
        /// Rotation rate in radians per second, same axes.
        var rotationRate: SIMD3<Float>
        /// Which way is down, in g, same axes: (0, -1, 0) with the phone upright, (0, 1, 0) upside down.
        var gravity: SIMD3<Float>
    }

    private let manager = CMMotionManager()
    private var users = 0

    /// False in the Simulator (shake it with Device ▸ Shake instead).
    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        users += 1
        guard users == 1, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates()
    }

    func stop() {
        guard users > 0 else { return }
        users -= 1
        if users == 0 { manager.stopDeviceMotionUpdates() }
    }

    /// The latest reading, turned into screen axes for the given interface orientation.
    func latest(for orientation: UIInterfaceOrientation) -> Sample? {
        guard users > 0, let motion = manager.deviceMotion else { return nil }
        let a = motion.userAcceleration, r = motion.rotationRate, g = motion.gravity
        return Sample(acceleration: Self.screenAxes(SIMD3(Float(a.x), Float(a.y), Float(a.z)), orientation),
                      rotationRate: Self.screenAxes(SIMD3(Float(r.x), Float(r.y), Float(r.z)), orientation),
                      gravity: Self.screenAxes(SIMD3(Float(g.x), Float(g.y), Float(g.z)), orientation))
    }

    /// Core Motion reports in the device's portrait axes; the screen turns with the interface (iPad).
    private static func screenAxes(_ v: SIMD3<Float>, _ orientation: UIInterfaceOrientation) -> SIMD3<Float> {
        switch orientation {
        case .portraitUpsideDown: SIMD3(-v.x, -v.y, v.z)
        case .landscapeLeft: SIMD3(v.y, -v.x, v.z)   // Home button on the left: the device's top points right
        case .landscapeRight: SIMD3(-v.y, v.x, v.z)  // Home button on the right: the device's top points left
        default: v
        }
    }
}
