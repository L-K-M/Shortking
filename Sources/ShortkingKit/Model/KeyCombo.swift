import Foundation

/// A normalized key combination.
///
/// Sources supply different halves of the picture — a character, a virtual keycode,
/// or a Carbon menu glyph — so `KeyCombo` fills in whichever half it can at
/// construction and hashes on a ``groupingKey`` that prefers the keycode. That is
/// what makes "⌘⇧G from Raycast's config" and "⌘⇧G from Finder's menu bar" land in
/// the same row.
public struct KeyCombo: Codable, Hashable, Sendable, CustomStringConvertible {

    /// The device-independent virtual keycode, when known.
    public var keyCode: UInt16?

    /// The character this combination is written with, when known. Layout-dependent
    /// and for display only — never the basis of equality when a keycode exists.
    public var character: String?

    public var modifiers: Modifiers

    // MARK: - Construction

    public init(keyCode: UInt16?, character: String?, modifiers: Modifiers) {
        var code = keyCode
        var char = character.flatMap { $0.isEmpty ? nil : $0 }

        if code == nil, let c = char, c.count == 1 {
            code = KeyCodes.charToKeyCode[c.lowercased()]
        }
        if char == nil, let c = code {
            char = KeyCodes.character(keyCode: c)
        }

        self.keyCode = code
        self.character = char.map { $0.count == 1 ? $0.uppercased() : $0 }
        self.modifiers = modifiers
    }

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.init(keyCode: keyCode, character: nil, modifiers: modifiers)
    }

    public init(character: String, modifiers: Modifiers) {
        self.init(keyCode: nil, character: character, modifiers: modifiers)
    }

    /// Builds a combo from a key token (`"g"`, `"space"`, `"f12"`, `"left"`).
    /// Returns `nil` only when the token is empty.
    public init?(token: String, modifiers: Modifiers) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let code = KeyCodes.keyCode(forToken: trimmed) {
            self.init(keyCode: code, character: trimmed.count == 1 ? trimmed : nil, modifiers: modifiers)
        } else {
            self.init(keyCode: nil, character: trimmed, modifiers: modifiers)
        }
    }

    // MARK: - Identity

    /// The stable string that defines equality and grouping.
    ///
    /// Prefers the keycode; falls back to the uppercased character so that combos
    /// we only ever saw as text still group with each other.
    public var groupingKey: String {
        if let code = keyCode {
            return "k\(code)|m\(modifiers.rawValue)"
        }
        return "c\(character?.uppercased() ?? "?")|m\(modifiers.rawValue)"
    }

    public static func == (lhs: KeyCombo, rhs: KeyCombo) -> Bool {
        lhs.groupingKey == rhs.groupingKey
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(groupingKey)
    }

    // MARK: - Display

    /// The key portion alone, e.g. `"G"`, `"Space"`, `"↩"`.
    public var keyDisplay: String {
        if let code = keyCode {
            return KeyCodes.display(keyCode: code)
        }
        if let char = character {
            return char.count == 1 ? char.uppercased() : char
        }
        return "?"
    }

    /// The full combination, e.g. `"⌃⌥⌘G"`.
    public var displayString: String {
        modifiers.displayString + keyDisplay
    }

    /// Modifier glyphs and the key, as separate keycaps for rendering.
    public var keycaps: [String] {
        modifiers.glyphs + [keyDisplay]
    }

    public var description: String { displayString }

    /// Free-text searchability: display form, key name, and modifier words.
    public var searchTokens: [String] {
        var tokens = [displayString.lowercased(), keyDisplay.lowercased()]
        if let code = keyCode, let name = KeyCodes.name(keyCode: code) {
            tokens.append(name)
        }
        if modifiers.contains(.command) { tokens.append(contentsOf: ["cmd", "command"]) }
        if modifiers.contains(.shift)   { tokens.append("shift") }
        if modifiers.contains(.option)  { tokens.append(contentsOf: ["opt", "option", "alt"]) }
        if modifiers.contains(.control) { tokens.append(contentsOf: ["ctrl", "control"]) }
        if modifiers.contains(.function) { tokens.append("fn") }
        return tokens
    }

    /// True when this combination cannot be registered as a Carbon hotkey on
    /// macOS 15+ regardless of who else wants it. Used to keep the Sequoia
    /// ⌥-hardening (`-9868`) out of the conflict list.
    public var isRestrictedByOptionHardening: Bool {
        modifiers.isOptionOnlyRestricted
    }

    /// A combination with no modifiers at all is a plain keystroke, not a shortcut,
    /// and should not be probed or reported as claimed.
    public var isBare: Bool {
        modifiers.isEmpty
    }
}
