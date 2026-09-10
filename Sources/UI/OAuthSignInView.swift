import SwiftUI
import AppKit

/// Device-flow sign-in. Shows a 6-character code that the user enters at
/// google.com/device in their everyday browser; we poll Google's token
/// endpoint until they confirm. No embedded webview, so Google's anti-
/// account-takeover detection doesn't trigger.
struct OAuthSignInView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var flow = OAuthDeviceFlow()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to YouTube Music")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Close") {
                    flow.cancel()
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            content
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 460, minHeight: 480)
        .task {
            if case .idle = flow.state { await flow.start() }
        }
        .onChange(of: flow.state) { _, newState in
            if newState == .success {
                env.refreshSignedInState()
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.state {
        case .idle, .requesting:
            VStack(spacing: 16) {
                ProgressView()
                Text("Requesting code…")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

        case let .awaitingUser(userCode, verificationURL):
            awaitingUser(code: userCode, url: verificationURL)

        case .success:
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("Signed in").font(.system(size: 20, weight: .semibold))
            }

        case let .failure(message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("Couldn't sign you in")
                    .font(.system(size: 18, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await flow.start() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.top, 4)
            }
        }
    }

    private func awaitingUser(code: String, url: URL) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Step 1")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("Open google.com/device")
                    .font(.system(size: 16, weight: .semibold))
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in browser", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Divider().padding(.horizontal, 24)

            VStack(spacing: 8) {
                Text("Step 2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("Enter this code")
                    .font(.system(size: 16, weight: .semibold))
                Text(code)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Theme.Fill.medium)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label("Copy code", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for confirmation…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }
}
