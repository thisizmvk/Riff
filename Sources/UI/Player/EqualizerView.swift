import SwiftUI

/// 10-band equalizer sheet. Changes apply live (the page's Web Audio
/// graph smooths each step), and persist across launches. Off or Flat
/// sends nothing to the page — no audio graph is built until it's used.
struct EqualizerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var gains: [Double] = Equalizer.flat.gains
    @State private var enabled = false

    private var presetName: String {
        Equalizer.matchingPreset(gains)?.name ?? "Custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Equalizer")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                Toggle("On", isOn: $enabled)
                    .toggleStyle(.switch)
                    .tint(Theme.red)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 10) {
                Menu {
                    ForEach(Equalizer.presets) { preset in
                        Button(preset.name) {
                            gains = preset.gains
                            enabled = true
                        }
                    }
                } label: {
                    Text(presetName)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 140, alignment: .leading)
                }
                .fixedSize()
                Spacer()
                Button("Reset") { gains = Equalizer.flat.gains }
                    .disabled(gains == Equalizer.flat.gains)
            }

            HStack(alignment: .bottom, spacing: 0) {
                // dB scale
                VStack(alignment: .trailing) {
                    Text("+12"); Spacer(); Text("0"); Spacer(); Text("−12")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.Text.tertiary)
                .frame(height: 160)
                .padding(.bottom, 22)
                .padding(.trailing, 6)

                ForEach(Equalizer.frequencies.indices, id: \.self) { i in
                    VStack(spacing: 6) {
                        EQBandSlider(value: $gains[i], enabled: enabled,
                                     label: "\(Equalizer.label(for: Equalizer.frequencies[i])) Hz")
                            .frame(height: 160)
                        Text(Equalizer.label(for: Equalizer.frequencies[i]))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .opacity(enabled ? 1 : 0.45)

            Text("Changes apply instantly. Boosts are balanced automatically so loud bands don't distort. Double-click a band to reset it.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.Bg.base)
        .onAppear {
            gains = env.player.eqGains
            enabled = env.player.eqEnabled
        }
        .onChange(of: gains) { _, new in push(enabled: enabled, gains: new) }
        .onChange(of: enabled) { _, on in push(enabled: on, gains: gains) }
    }

    private func push(enabled: Bool, gains: [Double]) {
        Task { await env.player.setEqualizer(enabled: enabled, gains: gains) }
    }
}

/// Vertical dB slider (−12…+12, 0.5 dB steps). Drag to set, double-click
/// to reset; VoiceOver adjusts it in 1 dB steps.
private struct EQBandSlider: View {
    @Binding var value: Double
    let enabled: Bool
    let label: String

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = Equalizer.range.upperBound - Equalizer.range.lowerBound
            let y = h * (1 - (value - Equalizer.range.lowerBound) / span)
            let zeroY = h / 2
            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.10))
                    .frame(width: 4)
                    .frame(maxWidth: .infinity)
                // Fill from 0 dB to the value.
                Rectangle()
                    .fill(enabled ? Theme.red : Color.white.opacity(0.3))
                    .frame(width: 4, height: abs(y - zeroY))
                    .offset(y: min(y, zeroY))
                    .frame(maxWidth: .infinity)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(y: y - 7)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let frac = 1 - min(max(g.location.y / h, 0), 1)
                        let raw = Equalizer.range.lowerBound + frac * span
                        value = (raw * 2).rounded() / 2
                    }
            )
            .onTapGesture(count: 2) { value = 0 }
        }
        .help("\(label): \(String(format: "%+.1f", value)) dB")
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%+.1f decibels", value))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(value + 1, Equalizer.range.upperBound)
            case .decrement: value = max(value - 1, Equalizer.range.lowerBound)
            @unknown default: break
            }
        }
    }
}
