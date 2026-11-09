//
//  ShakeToRevealCover.swift
//  Snowglobe
//
//  Hides a new globe once its size is locked in, until the user shakes it: the snowy night sky
//  from the shelf, with a big "Shake to Reveal". GlobeDetailView lifts it on the first shake (or a
//  press of its Shake button, for anyone who can't shake the iPhone), and the globe appears in the
//  snowstorm that shake made.
//

import SwiftUI

struct ShakeToRevealCover: View {
    /// The globe's name: a hint of what's underneath.
    let title: String
    /// The Shake button, for when shaking the iPhone isn't an option.
    let onShake: () -> Void

    @AccessibilityFocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                ShakingPhone()
                    .padding(.bottom, 10)
                Text("Shake to Reveal")
                    .font(Theme.titleFont(60))
                    .foregroundStyle(Theme.snow)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHint("Shake your iPhone, or use the Shake button, to see your snowglobe.")
                    .accessibilityFocused($isPromptFocused)
                Text(title)
                    .font(Theme.font(.title3, weight: .semibold))
                    .foregroundStyle(Theme.ice)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            Spacer()
            Button(action: onShake) {
                Label("Shake", systemImage: "wind.snow")
                    .font(Theme.font(.headline, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glass)
            .accessibilityHint("Reveals your snowglobe.")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Theme.nightGradient
                FallingSnowView()
            }
            .ignoresSafeArea()
        }
        .onAppear { isPromptFocused = true }
    }
}

/// How the cover comes and goes: it frosts over the globe, and on the shake it swells, blurs and
/// melts away. Just a fade with Reduce Motion.
struct ShakeToRevealTransition: Transition {
    var reduceMotion = false

    func body(content: Content, phase: TransitionPhase) -> some View {
        let settled = phase.isIdentity || reduceMotion
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .scaleEffect(settled ? 1 : 1.2)
            .blur(radius: settled ? 0 : 24)
    }
}

/// An iPhone being shaken: three quick swings, then a rest. Holds still with Reduce Motion.
private struct ShakingPhone: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
            .font(.system(size: 64, weight: .light))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Theme.ice)
            .keyframeAnimator(initialValue: 0.0, repeating: !reduceMotion) { phone, swing in
                phone
                    .rotationEffect(.degrees(swing * 12))
                    .offset(x: swing * 10)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0, duration: 0.7) // rest
                    CubicKeyframe(1, duration: 0.07)
                    CubicKeyframe(-1, duration: 0.13)
                    CubicKeyframe(1, duration: 0.13)
                    CubicKeyframe(-1, duration: 0.13)
                    CubicKeyframe(0, duration: 0.07)
                }
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    ShakeToRevealCover(title: "Times Square") {}
        .preferredColorScheme(.dark)
}
