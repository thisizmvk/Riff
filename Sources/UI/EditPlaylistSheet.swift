import SwiftUI

/// Edit-or-delete sheet for user-owned playlists. Reachable from the
/// "•••" menu next to Play / Shuffle on a playlist's detail header,
/// shown only when the open playlist actually belongs to the
/// signed-in user (matched by id against `env.userPlaylists`).
///
/// Mirrors YT Music web's playlist edit panel: rename, change
/// privacy, optional description, with a separate Delete action
/// gated behind a confirmation.
struct EditPlaylistSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let playlistId: String
    let initialTitle: String

    @State private var title: String
    @State private var privacy: InnerTubeClient.PlaylistPrivacy = .private
    @State private var description: String = ""
    @State private var saving = false
    @State private var error: String?
    @State private var showingDeleteConfirm = false
    @State private var deleted = false   // suppresses save-on-dismiss after Delete

    /// Closure fired after a destructive Delete completes — lets the
    /// detail page pop the navigation stack since the underlying
    /// content is gone. Save / cancel don't trigger it.
    var onDeleted: () -> Void = {}

    init(playlistId: String, initialTitle: String, onDeleted: @escaping () -> Void = {}) {
        self.playlistId = playlistId
        self.initialTitle = initialTitle
        self._title = State(initialValue: initialTitle)
        self.onDeleted = onDeleted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Playlist")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.Theme.Text.secondary)
                    .textCase(.uppercase)
                    .tracking(1.2)
                TextField("Playlist name", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.Theme.Text.secondary)
                    .textCase(.uppercase)
                    .tracking(1.2)
                TextField("Optional", text: $description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Privacy")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.Theme.Text.secondary)
                    .textCase(.uppercase)
                    .tracking(1.2)
                Picker("Privacy", selection: $privacy) {
                    Text("Private").tag(InnerTubeClient.PlaylistPrivacy.private)
                    Text("Unlisted").tag(InnerTubeClient.PlaylistPrivacy.unlisted)
                    Text("Public").tag(InnerTubeClient.PlaylistPrivacy.public)
                }
                .pickerStyle(.segmented)
            }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Theme.Fill.medium)

            HStack {
                Button("Delete Playlist") {
                    showingDeleteConfirm = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(saving)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .confirmationDialog(
            "Delete \"\(initialTitle)\"?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the playlist from your YouTube Music library. This cannot be undone.")
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        saving = true
        error = nil
        Task {
            do {
                // Fire updates only when the field changed — avoids
                // unnecessary round-trips and reduces blast radius if
                // any single endpoint hits a 4xx.
                if trimmedTitle != initialTitle {
                    try await env.innerTube.renamePlaylist(playlistId: playlistId, title: trimmedTitle)
                }
                // Description always sent — we don't track its
                // initial value because the detail() response doesn't
                // surface it; an empty string clears, a populated
                // string sets. User intent matches sent state.
                try await env.innerTube.setPlaylistDescription(playlistId: playlistId, description: trimmedDesc)
                try await env.innerTube.setPlaylistPrivacy(playlistId: playlistId, privacy: privacy)
                env.reloadUserPlaylists()
                await MainActor.run {
                    saving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = "Couldn't save changes: \(error.localizedDescription)"
                    saving = false
                }
            }
        }
    }

    private func delete() {
        saving = true
        error = nil
        Task {
            do {
                try await env.innerTube.deletePlaylist(playlistId: playlistId)
                env.reloadUserPlaylists()
                deleted = true
                await MainActor.run {
                    saving = false
                    onDeleted()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = "Couldn't delete: \(error.localizedDescription)"
                    saving = false
                }
            }
        }
    }
}
