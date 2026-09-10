import SwiftUI

/// Shared visual for "there's nothing here yet" screens. One SF Symbol
/// puck, a title, a subtitle, and an optional CTA. Sized to feel
/// intentional in the empty half of a pane, not to fill the whole
/// window — bigger illustrations tend to feel patronizing when the
/// user knows why the surface is empty (they just signed in, they
/// haven't played anything, they searched for a nonsense string).
struct EmptyState: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var cta: CTA? = nil

    /// Primary call-to-action. Optional because some empty states
    /// are "wait a moment" rather than "here's what to do next".
    struct CTA {
        let label: String
        let systemImage: String?
        let action: () -> Void

        init(_ label: String, systemImage: String? = nil, action: @escaping () -> Void) {
            self.label = label
            self.systemImage = systemImage
            self.action = action
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.Fill.soft)
                    .frame(width: 88, height: 88)
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Theme.Text.tertiary)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Text.secondary)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            if let cta {
                Button {
                    cta.action()
                } label: {
                    HStack(spacing: 6) {
                        if let icon = cta.systemImage {
                            Image(systemName: icon)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(cta.label)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.red)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: 320)
        .padding(24)
    }
}
