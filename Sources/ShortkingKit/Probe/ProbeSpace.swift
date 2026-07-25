import Foundation

/// How much of the combination space to sweep.
public enum ProbeBreadth: String, Codable, Hashable, Sendable, CaseIterable {
    /// Letters, digits and the common named keys against the modifier sets people
    /// actually bind. A few hundred probes; effectively instant.
    case common
    /// Adds the function keys, punctuation and the fuller modifier space.
    case wide
    /// Every keycode we have a name for against every modifier set. ~2,000 probes.
    case exhaustive

    public var displayName: String {
        switch self {
        case .common:     return "Common (fast)"
        case .wide:       return "Wide"
        case .exhaustive: return "Exhaustive"
        }
    }
}

/// Builds the set of combinations to probe.
///
/// Two rules shape this list:
///
/// - **No bare keys.** A combination with no modifiers is a keystroke, not a
///   shortcut, and registering one would be hostile.
/// - **⌥-only sets are still probed**, because their `-9868` result is *itself* the
///   answer to "why did my ⌥ shortcut stop working after the upgrade" — but they are
///   classified as `restricted`, never as a conflict.
public enum ProbeSpace {

    /// The modifier sets worth asking about, ordered roughly by how often people
    /// bind them.
    public static let commonModifiers: [Modifiers] = [
        [.command, .shift],
        [.command, .option],
        [.command, .control],
        [.control, .option],
        [.control, .shift],
        [.command, .option, .shift],
        [.command, .control, .shift],
        [.command, .control, .option],
        [.control, .option, .shift],
        [.command, .control, .option, .shift],
    ]

    public static let wideModifiers: [Modifiers] = commonModifiers + [
        [.command],
        [.control],
        [.option],
        [.option, .shift],
    ]

    /// Letters and digits.
    public static var alphanumericKeyCodes: [UInt16] {
        let characters = "abcdefghijklmnopqrstuvwxyz0123456789"
        return characters.compactMap { KeyCodes.charToKeyCode[String($0)] }
    }

    /// The named keys people bind: Space, Return, Tab, Escape, arrows, Home/End.
    public static var commonNamedKeyCodes: [UInt16] {
        ["space", "return", "tab", "escape", "delete", "left", "right", "up", "down",
         "home", "end", "pageup", "pagedown"]
            .compactMap { KeyCodes.nameToKeyCode[$0] }
    }

    public static var functionKeyCodes: [UInt16] {
        (1...20).compactMap { KeyCodes.nameToKeyCode["f\($0)"] }
    }

    public static var punctuationKeyCodes: [UInt16] {
        ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
            .compactMap { KeyCodes.charToKeyCode[$0] }
    }

    public static func keyCodes(for breadth: ProbeBreadth) -> [UInt16] {
        switch breadth {
        case .common:
            return alphanumericKeyCodes + commonNamedKeyCodes
        case .wide:
            return alphanumericKeyCodes + commonNamedKeyCodes + functionKeyCodes
        case .exhaustive:
            return alphanumericKeyCodes + commonNamedKeyCodes + functionKeyCodes + punctuationKeyCodes
        }
    }

    public static func modifiers(for breadth: ProbeBreadth) -> [Modifiers] {
        switch breadth {
        case .common:
            return commonModifiers
        case .wide, .exhaustive:
            return wideModifiers
        }
    }

    /// The full probe list for a breadth.
    public static func combos(for breadth: ProbeBreadth) -> [KeyCombo] {
        var result: [KeyCombo] = []
        let codes = keyCodes(for: breadth)
        let modifierSets = modifiers(for: breadth)
        result.reserveCapacity(codes.count * modifierSets.count)

        for modifiers in modifierSets {
            guard !modifiers.isEmpty else { continue }
            for code in codes {
                result.append(KeyCombo(keyCode: code, modifiers: modifiers))
            }
        }
        return result
    }

    public static func estimatedProbeCount(for breadth: ProbeBreadth) -> Int {
        keyCodes(for: breadth).count * modifiers(for: breadth).count
    }
}
