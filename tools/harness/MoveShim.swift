import Foundation

// Harness-only shim for SwiftUI's MutableCollection.move(fromOffsets:toOffset:)
// (not available without linking SwiftUI). Same semantics: `destination`
// is expressed in pre-removal coordinates — the moved elements end up
// immediately before the element that was originally at `destination`.
extension Array {
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.compactMap { $0 >= 0 && $0 < count ? self[$0] : nil }
        let removedBefore = source.filter { $0 < destination }.count
        var remaining: [Element] = []
        remaining.reserveCapacity(count)
        for (offset, element) in enumerated() where !source.contains(offset) {
            remaining.append(element)
        }
        let insertAt = Swift.min(Swift.max(destination - removedBefore, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertAt)
        self = remaining
    }
}
