//
//  FallingSnowView.swift
//  Snowglobe
//
//  Gentle 2D snowfall for backgrounds. Cheap: one Canvas redrawn at ~30 fps.
//

import SwiftUI

struct FallingSnowView: View {
    var flakeCount = 70

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                var rng = SeededRandom(seed: 42) // same flakes every frame; only time moves them
                for _ in 0..<flakeCount {
                    let startX = Double(rng.nextUnit())
                    let startY = Double(rng.nextUnit())
                    let speed = 10 + Double(rng.nextUnit()) * 26
                    let radius = 0.7 + Double(rng.nextUnit()) * 1.8
                    let phase = Double(rng.nextUnit()) * .pi * 2
                    let travel = size.height + 10
                    let y = (startY * travel + t * speed).truncatingRemainder(dividingBy: travel) - 5
                    let x = startX * size.width + sin(t * 0.5 + phase) * 14
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                             with: .color(.white.opacity(0.18 + radius * 0.12)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
