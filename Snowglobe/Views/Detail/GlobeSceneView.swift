//
//  GlobeSceneView.swift
//  Snowglobe
//
//  The live 3D globe: a RealityKit ARView in non-AR mode with a turntable, an orbiting camera,
//  lights, and touch controls (drag to spin/tilt, pinch to zoom, double-tap to reset).
//

import SwiftUI
import RealityKit
import Combine

struct GlobeSceneView: UIViewRepresentable {
    let globe: SnowGlobe
    /// What stands inside the glass (nil = just snow while it loads).
    var dioramaContent: Entity?

    func makeCoordinator() -> GlobeSceneCoordinator {
        GlobeSceneCoordinator()
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        context.coordinator.attach(to: arView, globe: GlobeEntityFactory.makeGlobe(for: globe))
        context.coordinator.showDioramaContent(dioramaContent)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.showDioramaContent(dioramaContent)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: GlobeSceneCoordinator) {
        coordinator.detach()
    }
}

@MainActor
final class GlobeSceneCoordinator: NSObject {
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

    private weak var arView: ARView?
    private let anchor = AnchorEntity(world: .zero)
    private let turntable = Entity()
    private let camera = PerspectiveCamera()
    private var updateSubscription: (any Cancellable)?

    private var yaw = Tuning.defaultYaw
    private var pitch = Tuning.defaultPitch
    private var distance = Tuning.defaultDistance
    private var spinVelocity: Float = 0
    private var pinchStartDistance = Tuning.defaultDistance

    /// The globe currently on the turntable.
    private(set) var globe: Entity?

    func attach(to arView: ARView, globe: Entity) {
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

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        arView.addGestureRecognizer(pan)
        arView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        arView.addGestureRecognizer(doubleTap)

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
        arView?.scene.removeAnchor(anchor)
    }

    private var shownContent: ObjectIdentifier?

    /// Puts `content` on the snow inside the globe (no-op if it's already there).
    func showDioramaContent(_ content: Entity?) {
        guard let globe, let content, ObjectIdentifier(content) != shownContent else { return }
        shownContent = ObjectIdentifier(content)
        GlobeEntityFactory.setDioramaContent(content, in: globe)
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

    // MARK: - Per frame

    /// Lets a flicked globe keep spinning and slowly come to rest.
    private func step(deltaTime: Float) {
        guard abs(spinVelocity) > 0.001 else { return }
        yaw += spinVelocity * deltaTime
        spinVelocity *= exp(-Tuning.spinDamping * deltaTime)
        applyTransforms()
    }

    private func applyTransforms() {
        turntable.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        let offset = SIMD3<Float>(0, sin(pitch), cos(pitch)) * distance
        camera.look(at: Tuning.target, from: Tuning.target + offset, relativeTo: anchor)
    }
}
