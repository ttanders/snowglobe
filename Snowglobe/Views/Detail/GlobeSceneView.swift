//
//  GlobeSceneView.swift
//  Snowglobe
//
//  The live 3D globe: a RealityKit ARView in non-AR mode with a turntable, an orbiting camera,
//  lights, snow, and touch controls (drag to spin/tilt, pinch to zoom, double-tap to reset,
//  tap the glass to flick the snow). The globe is "in your hand" here: shaking the iPhone
//  shakes the snow (see SnowController).
//

import SwiftUI
import RealityKit
import Combine

struct GlobeSceneView: UIViewRepresentable {
    let globe: SnowGlobe
    /// What stands inside the glass (nil = just snow while it loads).
    var dioramaContent: Entity?
    /// Bump this to make the globe hop and rattle (the Shake button).
    var shakeRequests = 0
    /// Called when the user stirs the snow themselves: shakes the iPhone, or taps the globe.
    var onUserStir: () -> Void = {}

    func makeCoordinator() -> GlobeSceneCoordinator {
        GlobeSceneCoordinator()
    }

    func makeUIView(context: Context) -> GlobeARView {
        let arView = GlobeARView()
        let coordinator = context.coordinator
        coordinator.onUserStir = onUserStir
        coordinator.handledShakeRequests = shakeRequests
        coordinator.attach(to: arView, globe: GlobeEntityFactory.makeGlobe(for: globe))
        coordinator.showDioramaContent(dioramaContent)
        return arView
    }

    func updateUIView(_ uiView: GlobeARView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onUserStir = onUserStir
        coordinator.showDioramaContent(dioramaContent)
        if shakeRequests != coordinator.handledShakeRequests {
            coordinator.handledShakeRequests = shakeRequests
            coordinator.shakeGlobe()
        }
    }

    static func dismantleUIView(_ uiView: GlobeARView, coordinator: GlobeSceneCoordinator) {
        coordinator.detach()
    }
}

/// An ARView that hears the shake gesture (Device ▸ Shake in the Simulator, where there's no motion sensor).
final class GlobeARView: ARView {
    var onShakeGesture: (() -> Void)?

    init() {
        super.init(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
    }

    required init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
    }

    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            onShakeGesture?()
        } else {
            super.motionEnded(motion, with: event)
        }
    }
}

@MainActor
final class GlobeSceneCoordinator: NSObject, UIGestureRecognizerDelegate {
    private enum Tuning {
        static let target = SIMD3<Float>(0, 0.08, 0)       // what the camera looks at (middle of glass + base)
        static let defaultYaw: Float = 0.3
        static let defaultPitch: Float = 0.2                // radians above the horizon
        static let defaultDistance: Float = 3.7
        static let pitchRange: ClosedRange<Float> = -0.1...0.8
        static let distanceRange: ClosedRange<Float> = 2.4...6.0
        static let horizontalFieldOfView: Float = 38        // degrees; horizontal so the globe fits a portrait screen
        static let radiansPerPoint: Float = 0.012
        static let maxSpinSpeed: Float = 8                  // radians / second
        static let spinDamping: Float = 2.5                 // per second
    }

    private weak var arView: GlobeARView?
    private let anchor = AnchorEntity(world: .zero)
    private let turntable = Entity()
    private let camera = PerspectiveCamera()
    private var updateSubscription: (any Cancellable)?

    private var yaw = Tuning.defaultYaw
    private var pitch = Tuning.defaultPitch
    private var distance = Tuning.defaultDistance
    private var spinVelocity: Float = 0
    private var pinchStartDistance = Tuning.defaultDistance

    private var snow: SnowController?
    private let rattle = GlobeRattlePlayer()
    private var rattlePose = GlobeRattle.Pose()
    private let tapFeedback = UIImpactFeedbackGenerator(style: .light)

    /// The Shake button presses already acted on (see GlobeSceneView.shakeRequests).
    var handledShakeRequests = 0
    var onUserStir: (() -> Void)?

    /// The globe currently on the turntable.
    private(set) var globe: Entity?

    func attach(to arView: GlobeARView, globe: Entity) {
        self.arView = arView
        self.globe = globe
        arView.environment.background = .color(Theme.sceneBackground)
        if let environment = GlobeLighting.environment {
            arView.environment.lighting.resource = environment
        }

        turntable.addChild(globe)
        anchor.addChild(turntable)
        camera.camera.fieldOfViewInDegrees = Tuning.horizontalFieldOfView
        camera.camera.fieldOfViewOrientation = .horizontal
        anchor.addChild(camera)
        GlobeLighting.addLights(to: anchor)
        arView.scene.addAnchor(anchor)
        applyTransforms()

        // Opening a globe is like picking it up off the shelf: the snow is drifting down.
        let snow = SnowController(globe: globe, startsSnowing: !UIAccessibility.isReduceMotionEnabled)
        snow.followDeviceMotion(true)
        snow.onDeliberateShake = { [weak self] in self?.onUserStir?() }
        self.snow = snow
        arView.onShakeGesture = { [weak self] in self?.handleShakeGesture() }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        arView.addGestureRecognizer(pan)
        arView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        arView.addGestureRecognizer(doubleTap)
        // A single tap flicks the glass straight away (it doesn't wait to rule out a double-tap).
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        arView.addGestureRecognizer(tap)

        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.step(deltaTime: Float(event.deltaTime))
            }
        }
    }

    func detach() {
        updateSubscription?.cancel()
        updateSubscription = nil
        snow?.stop()
        arView?.scene.removeAnchor(anchor)
    }

    private var shownContent: ObjectIdentifier?

    /// Puts `content` on the snow inside the globe (no-op if it's already there).
    func showDioramaContent(_ content: Entity?) {
        guard let globe, let content, ObjectIdentifier(content) != shownContent else { return }
        shownContent = ObjectIdentifier(content)
        GlobeEntityFactory.setDioramaContent(content, in: globe)
        snow?.showContent(content)
    }

    // MARK: - Shaking

    /// The Shake button: the globe hops and rattles, and its motion stirs the snow.
    /// (With Reduce Motion it stays put and the snow is stirred directly.)
    func shakeGlobe() {
        if UIAccessibility.isReduceMotionEnabled {
            snow?.shake()
            tapFeedback.impactOccurred()
        } else {
            rattle.start()
            snow?.shake(strength: 0.5)
        }
    }

    /// The shake gesture (Device ▸ Shake in the Simulator). On a real iPhone the motion sensor
    /// already stirred the snow while it shook.
    private func handleShakeGesture() {
        guard !DeviceMotion.shared.isAvailable else { return }
        shakeGlobe()
        onUserStir?()
    }

    // MARK: - Gestures

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: gesture.view)
        gesture.setTranslation(.zero, in: gesture.view)
        yaw += Float(translation.x) * Tuning.radiansPerPoint
        pitch = clamp(pitch + Float(translation.y) * Tuning.radiansPerPoint * 0.5,
                      Tuning.pitchRange.lowerBound, Tuning.pitchRange.upperBound)
        switch gesture.state {
        case .began:
            spinVelocity = 0
        case .ended, .cancelled:
            let velocity = Float(gesture.velocity(in: gesture.view).x) * Tuning.radiansPerPoint
            spinVelocity = clamp(velocity, -Tuning.maxSpinSpeed, Tuning.maxSpinSpeed)
        default:
            break
        }
        applyTransforms()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { pinchStartDistance = distance }
        distance = clamp(pinchStartDistance / Float(max(gesture.scale, 0.01)),
                         Tuning.distanceRange.lowerBound, Tuning.distanceRange.upperBound)
        applyTransforms()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        spinVelocity = 0
        yaw = Tuning.defaultYaw
        pitch = Tuning.defaultPitch
        distance = Tuning.defaultDistance
        applyTransforms()
    }

    /// Tapping the glass flicks the snow away from your finger; tapping the base knocks the globe.
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let arView, let snow,
              let ray = arView.ray(through: gesture.location(in: arView)),
              let target = snow.tap(rayOrigin: ray.origin, direction: ray.direction) else { return }
        tapFeedback.impactOccurred(intensity: target == .glass ? 0.6 : 0.9)
        onUserStir?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UITapGestureRecognizer && other is UITapGestureRecognizer
    }

    // MARK: - Per frame

    private func step(deltaTime: Float) {
        // A flicked globe keeps spinning and slowly comes to rest.
        if abs(spinVelocity) > 0.001 {
            yaw += spinVelocity * deltaTime
            spinVelocity *= exp(-Tuning.spinDamping * deltaTime)
        }
        rattlePose = rattle.advance(by: deltaTime)
        applyTransforms()

        let orientation = arView?.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        snow?.update(deltaTime: deltaTime, camera: Transform(matrix: camera.transformMatrix(relativeTo: nil)),
                     orientation: orientation)
    }

    private func applyTransforms() {
        // The camera only orbits up and down; spinning turns the globe itself, and a rattle moves it
        // sideways to the camera (world x) and rocks it.
        turntable.position = rattlePose.offset
        turntable.orientation = simd_quatf(angle: rattlePose.roll, axis: [0, 0, 1]) * simd_quatf(angle: yaw, axis: [0, 1, 0])
        let offset = SIMD3<Float>(0, sin(pitch), cos(pitch)) * distance
        camera.look(at: Tuning.target, from: Tuning.target + offset, relativeTo: anchor)
    }
}
