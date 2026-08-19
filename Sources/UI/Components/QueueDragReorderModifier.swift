import SwiftUI
import UniformTypeIdentifiers

/// Applies drag-and-drop reorder affordances to a row inside the Up
/// Next list. Wrapped in a `ViewModifier` (instead of inlining the
/// `.draggable` / `.dropDestination` chain) so the queueList code
/// stays readable and so the "reorderable=false" case is a
/// zero-overhead no-op via `if enabled { … }`.
///
/// Payload is the videoId as a plain `String` because the row's
/// identity is that string and SwiftUI's `.draggable(String)` +
/// `.dropDestination(for: String.self)` round-trip it cleanly
/// through the pasteboard. UTType.text handles the pasteboard side
/// on macOS.
struct QueueDragReorderModifier: ViewModifier {
    let enabled: Bool
    let itemId: String
    @Binding var hoverTargetId: String?
    /// @MainActor because the drop handler typically calls into
    /// PlayerBridge (MainActor-isolated) and mutates SwiftUI state.
    /// Swift 6 strict concurrency rejects a plain `(String) -> Void`
    /// being called from the MainActor-inferred dropDestination
    /// closure if the callee touches MainActor properties.
    let onDrop: @MainActor (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(itemId) {
                    // Minimal drag preview — a small pill with a
                    // grip icon. Full-row previews felt too heavy in
                    // testing; a small floating chip reads as "I am
                    // moving this row" without occluding the drop
                    // target underneath.
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal")
                        Text("Move")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .dropDestination(for: String.self) { droppedIds, _ in
                    guard let dropped = droppedIds.first else { return false }
                    hoverTargetId = nil
                    onDrop(dropped)
                    return true
                } isTargeted: { over in
                    hoverTargetId = over ? itemId : (hoverTargetId == itemId ? nil : hoverTargetId)
                }
        } else {
            content
        }
    }
}
