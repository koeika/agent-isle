import Foundation

/// Pointer state is independent of reminders and settings-window visibility.
/// Escape inhibits re-entry until the pointer actually exits the island.
struct InteractionPolicy {
    static func stableOrder(current: [String], held: [String]) -> [String] {
        guard !held.isEmpty else { return current }
        let present = Set(current), previous = Set(held)
        return held.filter { present.contains($0) } + current.filter { !previous.contains($0) }
    }
    var enteredAt: TimeInterval?
    var leftAt: TimeInterval?
    var suppressedUntilExit = false
    mutating func dismiss() { suppressedUntilExit = true; enteredAt = nil }
    mutating func update(inside: Bool, expanded: Bool, locked: Bool, hover: Bool,
                         autoCollapse: Bool, delay: Double, now: TimeInterval) -> Bool? {
        if inside {
            leftAt = nil
            if enteredAt == nil { enteredAt = now }
            if !expanded && hover && !suppressedUntilExit && now - enteredAt! >= delay { return true }
        } else {
            enteredAt = nil
            suppressedUntilExit = false
            if leftAt == nil { leftAt = now }
            if expanded && autoCollapse && !locked && now - leftAt! >= 0.28 { return false }
        }
        return nil
    }
}
