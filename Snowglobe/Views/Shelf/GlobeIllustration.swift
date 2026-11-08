//
//  GlobeIllustration.swift
//  Snowglobe
//
//  A 2D drawing of a snowglobe for the shelf. Each globe gets its own little skyline
//  (seeded by its coordinate), or mountains for big "landscape" globes.
//

import SwiftUI

struct GlobeIllustration: View {
    let globe: SnowGlobe

    /// width / height of the drawing.
    static let aspectRatio: CGFloat = 1.08

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let r = w * 0.45
            let center = CGPoint(x: w / 2, y: r + w * 0.02)
            let sphereRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            let sphere = Path(ellipseIn: sphereRect)
            let baseTop = center.y + r * 0.7

            // 1. Inside the glass: sky + miniature scene.
            ctx.drawLayer { layer in
                layer.clip(to: sphere)
                layer.fill(sphere, with: .linearGradient(
                    Gradient(colors: [Color(red: 0.30, green: 0.42, blue: 0.72), Color(red: 0.72, green: 0.83, blue: 0.97)]),
                    startPoint: CGPoint(x: center.x, y: sphereRect.minY),
                    endPoint: CGPoint(x: center.x, y: baseTop)))
                var rng = SeededRandom(coordinate: globe.coordinate)
                MiniatureSketch.draw(in: &layer, rng: &rng, center: center, radius: r,
                                     groundY: baseTop - r * 0.2,
                                     isLandscape: globe.radiusMeters >= RadiusPreset.landscape.rawValue)
            }

            // 2. Glass: rim and highlights.
            ctx.stroke(sphere, with: .color(.white.opacity(0.4)), lineWidth: max(1, w * 0.008))
            var arc = Path()
            arc.addArc(center: center, radius: r * 0.8, startAngle: .degrees(198), endAngle: .degrees(248), clockwise: false)
            ctx.stroke(arc, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: r * 0.07, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: center.x + r * 0.45, y: center.y - r * 0.55, width: r * 0.1, height: r * 0.1)),
                     with: .color(.white.opacity(0.5)))

            // 3. Pedestal: brass band + wooden trapezoid + plaque.
            let baseBottom = size.height
            var pedestal = Path()
            pedestal.move(to: CGPoint(x: center.x - r * 0.72, y: baseTop))
            pedestal.addLine(to: CGPoint(x: center.x + r * 0.72, y: baseTop))
            pedestal.addLine(to: CGPoint(x: center.x + r * 0.8, y: baseBottom))
            pedestal.addLine(to: CGPoint(x: center.x - r * 0.8, y: baseBottom))
            pedestal.closeSubpath()
            ctx.fill(pedestal, with: .linearGradient(
                Gradient(colors: [Theme.wood, Theme.woodDark]),
                startPoint: CGPoint(x: center.x - r, y: baseTop),
                endPoint: CGPoint(x: center.x + r, y: baseBottom)))

            let band = CGRect(x: center.x - r * 0.74, y: baseTop - r * 0.02, width: r * 1.48, height: r * 0.08)
            ctx.fill(Path(roundedRect: band, cornerRadius: r * 0.03), with: .linearGradient(
                Gradient(colors: [Theme.brass, Theme.brass.opacity(0.6)]),
                startPoint: CGPoint(x: band.minX, y: band.minY), endPoint: CGPoint(x: band.maxX, y: band.maxY)))

            let plaque = CGRect(x: center.x - r * 0.3, y: baseTop + (baseBottom - baseTop) * 0.38,
                                width: r * 0.6, height: (baseBottom - baseTop) * 0.34)
            ctx.fill(Path(roundedRect: plaque, cornerRadius: r * 0.03), with: .color(Theme.brass.opacity(0.85)))
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
    }
}

/// Draws a tiny snowy skyline (or mountains) inside the glass.
private enum MiniatureSketch {
    static func draw(in ctx: inout GraphicsContext, rng: inout SeededRandom,
                     center: CGPoint, radius r: CGFloat, groundY: CGFloat, isLandscape: Bool) {
        let left = center.x - r
        let right = center.x + r

        if isLandscape {
            // Mountains with snow caps.
            for i in 0..<3 {
                let peakX = center.x + CGFloat(rng.nextFloat(in: -0.55...0.55)) * r
                let peakY = groundY - r * CGFloat(rng.nextFloat(in: 0.45...0.85)) + CGFloat(i) * r * 0.08
                let halfWidth = r * CGFloat(rng.nextFloat(in: 0.45...0.75))
                var mountain = Path()
                mountain.move(to: CGPoint(x: peakX - halfWidth, y: groundY + 2))
                mountain.addLine(to: CGPoint(x: peakX, y: peakY))
                mountain.addLine(to: CGPoint(x: peakX + halfWidth, y: groundY + 2))
                mountain.closeSubpath()
                ctx.fill(mountain, with: .color(Color(red: 0.35 + Double(i) * 0.08, green: 0.40 + Double(i) * 0.08, blue: 0.55 + Double(i) * 0.06)))
                let capHeight = (groundY - peakY) * 0.35
                var cap = Path()
                cap.move(to: CGPoint(x: peakX - halfWidth * 0.35, y: peakY + capHeight))
                cap.addLine(to: CGPoint(x: peakX, y: peakY))
                cap.addLine(to: CGPoint(x: peakX + halfWidth * 0.35, y: peakY + capHeight))
                cap.closeSubpath()
                ctx.fill(cap, with: .color(.white.opacity(0.95)))
            }
        } else {
            // Buildings with lit windows and snowy roofs.
            let palette: [Color] = [
                Color(red: 0.93, green: 0.88, blue: 0.78), Color(red: 0.78, green: 0.42, blue: 0.36),
                Color(red: 0.62, green: 0.68, blue: 0.78), Color(red: 0.85, green: 0.72, blue: 0.55),
            ]
            var x = left + r * 0.22
            while x < right - r * 0.3 {
                let width = r * CGFloat(rng.nextFloat(in: 0.13...0.24))
                let height = r * CGFloat(rng.nextFloat(in: 0.18...0.62))
                let rect = CGRect(x: x, y: groundY - height, width: width, height: height + 2)
                ctx.fill(Path(rect), with: .color(palette[Int(rng.nextUnit() * Float(palette.count)) % palette.count]))
                // windows
                let windowSize = max(1.5, r * 0.035)
                var wy = rect.minY + windowSize
                while wy < groundY - windowSize * 1.5 {
                    var wx = rect.minX + windowSize * 0.8
                    while wx < rect.maxX - windowSize * 1.2 {
                        let lit = rng.nextUnit() < 0.45
                        ctx.fill(Path(CGRect(x: wx, y: wy, width: windowSize, height: windowSize)),
                                 with: .color(lit ? Color(red: 1, green: 0.85, blue: 0.45) : Color.black.opacity(0.25)))
                        wx += windowSize * 2
                    }
                    wy += windowSize * 2.2
                }
                // snow on the roof
                ctx.fill(Path(roundedRect: CGRect(x: rect.minX - 1, y: rect.minY - r * 0.025, width: width + 2, height: r * 0.04),
                              cornerRadius: r * 0.02), with: .color(.white))
                x += width + r * CGFloat(rng.nextFloat(in: 0.01...0.06))
            }
        }

        // Snowy ground (covers the bottom of the buildings / mountains).
        var ground = Path()
        ground.move(to: CGPoint(x: left, y: groundY + r * 0.02))
        ground.addQuadCurve(to: CGPoint(x: right, y: groundY + r * 0.02), control: CGPoint(x: center.x, y: groundY - r * 0.08))
        ground.addLine(to: CGPoint(x: right, y: center.y + r))
        ground.addLine(to: CGPoint(x: left, y: center.y + r))
        ground.closeSubpath()
        ctx.fill(ground, with: .linearGradient(Gradient(colors: [.white, Color(red: 0.80, green: 0.87, blue: 0.97)]),
                                               startPoint: CGPoint(x: center.x, y: groundY - r * 0.08),
                                               endPoint: CGPoint(x: center.x, y: center.y + r)))

        // Pine trees.
        for _ in 0..<4 {
            let tx = center.x + CGFloat(rng.nextFloat(in: -0.62...0.62)) * r
            let ty = groundY + r * CGFloat(rng.nextFloat(in: 0.02...0.12))
            let th = r * CGFloat(rng.nextFloat(in: 0.16...0.26))
            var tree = Path()
            tree.move(to: CGPoint(x: tx, y: ty - th))
            tree.addLine(to: CGPoint(x: tx + th * 0.32, y: ty))
            tree.addLine(to: CGPoint(x: tx - th * 0.32, y: ty))
            tree.closeSubpath()
            ctx.fill(tree, with: .color(Color(red: 0.12, green: 0.36, blue: 0.26)))
            ctx.fill(Path(ellipseIn: CGRect(x: tx - th * 0.08, y: ty - th - th * 0.04, width: th * 0.16, height: th * 0.14)), with: .color(.white))
        }

        // Falling snow.
        for _ in 0..<26 {
            let fx = center.x + CGFloat(rng.nextFloat(in: -0.85...0.85)) * r
            let fy = center.y + CGFloat(rng.nextFloat(in: -0.85...0.6)) * r
            let fs = r * CGFloat(rng.nextFloat(in: 0.015...0.035))
            ctx.fill(Path(ellipseIn: CGRect(x: fx, y: fy, width: fs, height: fs)), with: .color(.white.opacity(0.9)))
        }
    }
}

#Preview {
    GlobeIllustration(globe: SampleGlobes.all[0])
        .padding(60)
        .background(Theme.nightGradient)
}
