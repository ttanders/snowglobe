//
//  GlobeOutlinePlaceholder.swift
//  Snowglobe
//
//  Stands in on the shelf while a globe's picture is being rendered: a softly pulsing outline
//  of the glass and pedestal, laid out like the rendered picture (GlobeThumbnailRenderer) so it
//  crossfades into it in place. Stops pulsing if the picture couldn't be made.
//

import SwiftUI

struct GlobeOutlinePlaceholder: View {
    /// True while the picture is still on its way (pulses); false once it has failed (static).
    var isLoading = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isLoading && !reduceMotion {
                outline
                    .phaseAnimator([0.35, 0.85]) { content, opacity in
                        content.opacity(opacity)
                    } animation: { _ in
                        .easeInOut(duration: 1.1)
                    }
            } else {
                outline.opacity(isLoading ? 0.6 : 0.35)
            }
        }
        .aspectRatio(GlobeIllustration.aspectRatio, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var outline: some View {
        ZStack {
            GlassShape()
                .fill(LinearGradient(colors: [Theme.ice.opacity(0.18), Theme.ice.opacity(0.04)],
                                     startPoint: .top, endPoint: .bottom))
            GlassShape()
                .stroke(Theme.ice, lineWidth: 1.5)
            PedestalShape()
                .fill(Theme.ice.opacity(0.10))
            PedestalShape()
                .stroke(Theme.ice, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

/// Proportions of the rendered picture, as fractions of its width (origin bottom-centre).
private enum OutlineLayout {
    static let glassRadius: CGFloat = 0.36
    static let glassCenterAboveBottom: CGFloat = 0.38
    static let pedestalHeight: CGFloat = 0.19
    static let pedestalHalfWidth: CGFloat = 0.37
    /// The octagon's slanted corners as seen from the front.
    static let pedestalChamfer: CGFloat = 0.05
}

/// The glass sphere, cut off where it meets the pedestal.
private struct GlassShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let center = CGPoint(x: rect.midX, y: rect.maxY - OutlineLayout.glassCenterAboveBottom * w)
        let radius = OutlineLayout.glassRadius * w
        let pedestalTop = rect.maxY - OutlineLayout.pedestalHeight * w
        // Angle (below the horizontal) where the circle crosses the pedestal top.
        let drop = min(max((pedestalTop - center.y) / radius, -1), 1)
        let cut = Angle(radians: asin(drop))
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: cut, endAngle: .degrees(180) - cut, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Front view of the octagonal pedestal: a wide band with chamfered corners.
private struct PedestalShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let half = OutlineLayout.pedestalHalfWidth * w
        let chamfer = OutlineLayout.pedestalChamfer * w
        let top = rect.maxY - OutlineLayout.pedestalHeight * w
        let bottom = rect.maxY - 1
        let left = rect.midX - half
        let right = rect.midX + half
        var path = Path()
        path.move(to: CGPoint(x: left + chamfer, y: top))
        path.addLine(to: CGPoint(x: right - chamfer, y: top))
        path.addLine(to: CGPoint(x: right, y: top + chamfer))
        path.addLine(to: CGPoint(x: right, y: bottom - chamfer))
        path.addLine(to: CGPoint(x: right - chamfer, y: bottom))
        path.addLine(to: CGPoint(x: left + chamfer, y: bottom))
        path.addLine(to: CGPoint(x: left, y: bottom - chamfer))
        path.addLine(to: CGPoint(x: left, y: top + chamfer))
        path.closeSubpath()
        return path
    }
}

#Preview {
    HStack(spacing: 18) {
        GlobeOutlinePlaceholder()
        GlobeOutlinePlaceholder(isLoading: false)
    }
    .padding(30)
    .background(Theme.nightGradient)
}
