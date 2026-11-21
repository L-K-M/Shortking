import Foundation

/// Correlates a physical key press (from the active sandwich capture) with a
/// subsequent system-defined hotkey delivery. Only one delivery is accepted per
/// matching press, within a 250 ms window.
struct LiveCaptureCorrelation {
    private var target: KeyCombo?
    private var pressAt: Date?
    private static let deliveryWindow: TimeInterval = 0.25

    mutating func reset(target: KeyCombo? = nil) {
        self.target = target
        pressAt = nil
    }

    mutating func recordPress(_ combo: KeyCombo, at: Date) {
        pressAt = combo == target ? at : nil
    }

    mutating func takeMatchingDelivery(at: Date) -> Bool {
        guard target != nil, let pressAt else { return false }
        let elapsed = at.timeIntervalSince(pressAt)
        guard elapsed >= 0 && elapsed <= Self.deliveryWindow else { return false }

        // One physical press can name one owner. Do not let several suspect taps
        // turn the same press into several persisted owners.
        self.pressAt = nil
        return true
    }
}
