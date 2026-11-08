//
//  ARGlobeView.swift
//  Snowglobe
//
//  Full-screen AR: find a table or floor, tap to place the snowglobe, then drag to move it,
//  twist to rotate and pinch to resize. Needs a real iPhone (the Simulator has no camera).
//
//  Snow: the globe stands on the table, not in your hand, so moving the iPhone doesn't stir it.
//  Dragging or twisting the globe does (the snow lags behind the glass), as do tapping it and
//  the Shake button, which makes it hop and rattle.
//

import SwiftUI
import RealityKit
import ARKit
import Combine

struct ARGlobeView: View {
    let globe: SnowGlobe
    /// The miniature shown in the detail view; it's cloned for AR.
    let content: Entity?
    /// Google's data credits (must stay visible with the 3D content).
    let attributions: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var controller = ARGlobeController()

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported {
                ARGlobeSceneView(globe: globe, content: content, controller: controller)
                    .ignoresSafeArea()
            } else {
                unsupported
            }

            VStack(spacing: 12) {
                HStack {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                    Spacer()
                }
                Spacer()
                if ARWorldTrackingConfiguration.isSupported {
                    bottomControls
                }
                credits
            }
            .padding()
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        Text(controller.hint)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(in: .rect(cornerRadius: 18))
            .animation(.default, value: controller.hint)
        if controller.isPlaced {
            HStack(spacing: 12) {
                Button("Place Again", systemImage: "arrow.counterclockwise") {
                    controller.placeAgain()
                }
                .buttonStyle(.glass)
                Button("Shake", systemImage: "wind.snow") {
                    controller.shake()
                }
                .buttonStyle(.glass)
                .accessibilityHint("Makes it snow inside the globe.")
            }
        }
    }

    private var unsupported: some View {
        ZStack {
            Theme.nightGradient.ignoresSafeArea()
            ContentUnavailableView {
                Label("AR needs a real iPhone", systemImage: "arkit")
            } description: {
                Text("The Simulator doesn't have a camera. Run Snowglobe on your iPhone to put \(globe.title) on your table.")
            }
        }
    }

    @ViewBuilder
    private var credits: some View {
        if !attributions.isEmpty {
            let others = attributions.filter { $0 != "Google" }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Google Maps")
                    .font(.caption.weight(.semibold))
                if !others.isEmpty {
                    Text(others.joined(separator: " · "))
                        .font(.caption2)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .shadow(radius: 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
        }
    }
}

/// Shared state between the SwiftUI overlay and the AR scene.
@MainActor @Observable
final class ARGlobeController {
    static let findSurfaceHint = "Move your iPhone slowly to find a table or floor, then tap to place your snowglobe."
    static let placedHint = "Tap the globe to make it snow\nDrag to move · Twist to rotate · Pinch to resize"

    var isPlaced = false
    var hint = ARGlobeController.findSurfaceHint
    @ObservationIgnored var onPlaceAgain: (() -> Void)?
    @ObservationIgnored var onShake: (() -> Void)?

    func placeAgain() {
        onPlaceAgain?()
    }

    func shake() {
        onShake?()
    }
}

/// The ARView: world tracking with horizontal planes, Apple's coaching overlay, tap-to-place.
struct ARGlobeSceneView: UIViewRepresentable {
    let globe: SnowGlobe
    let content: Entity?
    let controller: ARGlobeController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.environment.background = .cameraFeed() // the real room behind the globe
        let globeEntity = GlobeEntityFactory.makeGlobe(for: globe, content: content?.clone(recursive: true))
        context.coordinator.start(arView: arView, globe: globeEntity)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        private let controller: ARGlobeController
        private weak var arView: ARView?
        private var globe: Entity?
        private var anchor: AnchorEntity?
        private var placementGestures: [UIGestureRecognizer] = []
        private var snow: SnowController?
        private let rattle = GlobeRattlePlayer()
        private let tapFeedback = UIImpactFeedbackGenerator(style: .light)
        private var updateSubscription: (any Cancellable)?
        /// Height of the globe's centre above the table (globe units): the pedestal stands on the surface.
        private let lift = -GlobeMetrics.baseBottomY

        init(controller: ARGlobeController) {
            self.controller = controller
            super.init()
            controller.onPlaceAgain = { [weak self] in self?.removePlacedGlobe() }
            controller.onShake = { [weak self] in self?.shakeGlobe() }
        }

        func start(arView: ARView, globe: Entity) {
            self.arView = arView
            self.globe = globe
            addGroundingShadows(to: globe)
            snow = SnowController(globe: globe, startsSnowing: false)
            updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.step(deltaTime: Float(event.deltaTime))
                }
            }

            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = [.horizontal]
            configuration.environmentTexturing = .automatic // the glass reflects the real room
            arView.session.delegate = self
            arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

            let coaching = ARCoachingOverlayView()
            coaching.session = arView.session
            coaching.goal = .horizontalPlane
            coaching.activatesAutomatically = true
            coaching.frame = arView.bounds
            coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            arView.addSubview(coaching)

            arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        }

        func stop() {
            updateSubscription?.cancel()
            updateSubscription = nil
            snow?.stop()
            arView?.session.pause()
            if let anchor { arView?.scene.removeAnchor(anchor) }
        }

        // MARK: - Snow

        private func step(deltaTime: Float) {
            guard anchor != nil, let arView, let globe else { return }
            let pose = rattle.advance(by: deltaTime)
            globe.position = SIMD3(0, lift, 0) + pose.offset
            globe.orientation = simd_quatf(angle: pose.roll, axis: [0, 0, 1])
            snow?.update(deltaTime: deltaTime, camera: arView.cameraTransform)
        }

        /// The Shake button: the globe hops and rattles on the table, and its motion stirs the snow.
        private func shakeGlobe() {
            guard anchor != nil else { return }
            if UIAccessibility.isReduceMotionEnabled {
                snow?.shake()
                tapFeedback.impactOccurred()
            } else {
                rattle.start()
                snow?.shake(strength: 0.5)
            }
        }

        // MARK: - Placement

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView, let globe else { return }
            let point = gesture.location(in: arView)
            if anchor != nil {
                // Placed: tapping the globe flicks the snow inside.
                if let ray = arView.ray(through: point),
                   let target = snow?.tap(rayOrigin: ray.origin, direction: ray.direction) {
                    tapFeedback.impactOccurred(intensity: target == .glass ? 0.6 : 0.9)
                }
                return
            }
            guard let result = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first else {
                controller.hint = "Couldn't find a surface there. Keep moving your iPhone slowly and tap again."
                return
            }
            let column = result.worldTransform.columns.3
            place(globe, at: SIMD3(column.x, column.y, column.z), in: arView)
        }

        private func place(_ globe: Entity, at position: SIMD3<Float>, in arView: ARView) {
            let anchor = AnchorEntity(world: position)

            // The built-in gestures need an entity with collision shapes; it holds the globe,
            // raised so the bottom of the pedestal sits on the surface.
            let holder = ModelEntity()
            holder.name = "GlobeHolder"
            globe.position = [0, lift, 0]
            holder.addChild(globe)
            let baseWidth = (GlobeMetrics.baseRadius + 0.06) * 2
            let baseHeight = GlobeMetrics.groundY - GlobeMetrics.baseBottomY
            holder.collision = CollisionComponent(shapes: [
                .generateSphere(radius: GlobeMetrics.glassRadius).offsetBy(translation: [0, lift, 0]),
                .generateBox(width: baseWidth, height: baseHeight, depth: baseWidth).offsetBy(translation: [0, baseHeight / 2, 0]),
            ])

            // Turn the brass plaque toward the viewer.
            let camera = arView.cameraTransform.translation
            holder.orientation = simd_quatf(angle: atan2(camera.x - position.x, camera.z - position.z), axis: [0, 1, 0])

            // Pop in from nothing to real size (glass radius ≈ 9 cm, ~16 cm tall).
            let finalScale = SIMD3<Float>(repeating: GlobeMetrics.arGlassRadiusMeters)
            holder.scale = finalScale * 0.01
            anchor.addChild(holder)
            arView.scene.addAnchor(anchor)
            var target = holder.transform
            target.scale = finalScale
            holder.move(to: target, relativeTo: anchor, duration: 0.35, timingFunction: .easeOut)

            placementGestures = arView.installGestures([.translation, .rotation, .scale], for: holder)
                .map { $0 as UIGestureRecognizer }
            self.anchor = anchor
            controller.isPlaced = true
            controller.hint = ARGlobeController.placedHint
            // Like a globe just set down after being carried over: snow drifting down.
            if !UIAccessibility.isReduceMotionEnabled { snow?.scatter() }
        }

        private func removePlacedGlobe() {
            guard let anchor else { return }
            globe?.removeFromParent()
            arView?.scene.removeAnchor(anchor)
            placementGestures.forEach { arView?.removeGestureRecognizer($0) }
            placementGestures = []
            self.anchor = nil
            controller.isPlaced = false
            controller.hint = ARGlobeController.findSurfaceHint
        }

        /// The pedestal casts a soft shadow onto the real table.
        private func addGroundingShadows(to globe: Entity) {
            guard let pedestal = globe.findEntity(named: "Pedestal") else { return }
            for case let model as ModelEntity in pedestal.children {
                model.components.set(GroundingShadowComponent(castsShadow: true))
            }
        }

        // MARK: - ARSessionDelegate

        nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
            let cameraDenied = (error as? ARError)?.code == .cameraUnauthorized
            Task { @MainActor in
                self.controller.hint = cameraDenied
                    ? "Camera access is off. Turn it on in Settings ▸ Snowglobe to use AR."
                    : "AR stopped working (\(error.localizedDescription)). Close and try again."
            }
        }
    }
}
