import Foundation

/// A normalized, device-independent modifier set.
///
/// Every source in Shortking speaks a different modifier dialect — Carbon bit masks,
/// Cocoa `NSEvent.ModifierFlags`, the Accessibility API's *inverted* mask, and the
/// `@$~^` string convention used by `NSUserKeyEquivalents`. `Modifiers` is the single
/// normalized representation everything converts into.
public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command  = Modifiers(rawValue: 1 << 0)
    public static let shift    = Modifiers(rawValue: 1 << 1)
    public static let option   = Modifiers(rawValue: 1 << 2)
    public static let control  = Modifiers(rawValue: 1 << 3)
    public static let function = Modifiers(rawValue: 1 << 4)

    public static let none: Modifiers = []

    // MARK: - Carbon

    /// Carbon `EventHotKey` modifier bits, from `Events.h`.
    public enum Carbon {
        public static let command: UInt32 = 0x0100  // cmdKey
        public static let shift: UInt32   = 0x0200  // shiftKey
        public static let option: UInt32  = 0x0800  // optionKey
        public static let control: UInt32 = 0x1000  // controlKey
    }

    public init(carbon mask: UInt32) {
        var result: Modifiers = []
        if mask & Carbon.command != 0 { result.insert(.command) }
        if mask & Carbon.shift   != 0 { result.insert(.shift) }
        if mask & Carbon.option  != 0 { result.insert(.option) }
        if mask & Carbon.control != 0 { result.insert(.control) }
        self = result
    }

    public var carbonMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= Carbon.command }
        if contains(.shift)   { mask |= Carbon.shift }
        if contains(.option)  { mask |= Carbon.option }
        if contains(.control) { mask |= Carbon.control }
        return mask
    }

    // MARK: - Cocoa / CoreGraphics

    /// `NSEvent.ModifierFlags` / `CGEventFlags` device-independent bits.
    public enum Cocoa {
        public static let shift: UInt64    = 1 << 17
        public static let control: UInt64  = 1 << 18
        public static let option: UInt64   = 1 << 19
        public static let command: UInt64  = 1 << 20
        public static let function: UInt64 = 1 << 23
    }

    public init(cocoa flags: UInt64) {
        var result: Modifiers = []
        if flags & Cocoa.command  != 0 { result.insert(.command) }
        if flags & Cocoa.shift    != 0 { result.insert(.shift) }
        if flags & Cocoa.option   != 0 { result.insert(.option) }
        if flags & Cocoa.control  != 0 { result.insert(.control) }
        if flags & Cocoa.function != 0 { result.insert(.function) }
        self = result
    }

    public var cocoaFlags: UInt64 {
        var flags: UInt64 = 0
        if contains(.command)  { flags |= Cocoa.command }
        if contains(.shift)    { flags |= Cocoa.shift }
        if contains(.option)   { flags |= Cocoa.option }
        if contains(.control)  { flags |= Cocoa.control }
        if contains(.function) { flags |= Cocoa.function }
        return flags
    }

    // MARK: - Accessibility (inverted Command bit)

    /// `kAXMenuItemCmdModifiersAttribute` uses an inverted convention where bit 3
    /// *clears* Command: `0` means plain ⌘ and `8` means no modifier at all.
    ///
    /// - `1` → ⇧
    /// - `2` → ⌥
    /// - `4` → ⌃
    /// - `8` → suppress the implicit ⌘
    public init(axMenuItemModifiers mask: Int) {
        var result: Modifiers = []
        if mask & 1 != 0 { result.insert(.shift) }
        if mask & 2 != 0 { result.insert(.option) }
        if mask & 4 != 0 { result.insert(.control) }
        if mask & 8 == 0 { result.insert(.command) }
        self = result
    }

    public var axMenuItemModifiers: Int {
        var mask = 0
        if contains(.shift)   { mask |= 1 }
        if contains(.option)  { mask |= 2 }
        if contains(.control) { mask |= 4 }
        if !contains(.command) { mask |= 8 }
        return mask
    }

    // MARK: - Cocoa key-equivalent strings (`NSUserKeyEquivalents`)

    /// Parses the leading modifier sigils of a Cocoa key-equivalent string.
    ///
    /// `@` = ⌘, `$` = ⇧, `~` = ⌥, `^` = ⌃. Returns the modifiers and the remaining
    /// key portion of the string. An uppercase ASCII letter in the key portion
    /// additionally implies ⇧, matching AppKit's behaviour.
    public static func parseKeyEquivalent(_ string: String) -> (modifiers: Modifiers, key: String) {
        var result: Modifiers = []
        var remainder = Substring(string)

        loop: while let first = remainder.first {
            switch first {
            case "@": result.insert(.command)
            case "$": result.insert(.shift)
            case "~": result.insert(.option)
            case "^": result.insert(.control)
            default: break loop
            }
            remainder = remainder.dropFirst()
        }

        let key = String(remainder)
        if key.count == 1, let scalar = key.unicodeScalars.first,
           CharacterSet.uppercaseLetters.contains(scalar) {
            result.insert(.shift)
        }
        return (result, key)
    }

    /// The inverse of ``parseKeyEquivalent(_:)``, in AppKit's canonical sigil order.
    public func keyEquivalentPrefix() -> String {
        var prefix = ""
        if contains(.control) { prefix += "^" }
        if contains(.option)  { prefix += "~" }
        if contains(.shift)   { prefix += "$" }
        if contains(.command) { prefix += "@" }
        return prefix
    }

    // MARK: - Display

    /// Modifier glyphs in the canonical macOS order: ⌃⌥⇧⌘ (fn first when present).
    public var displayString: String {
        var out = ""
        if contains(.function) { out += "fn" }
        if contains(.control)  { out += "⌃" }
        if contains(.option)   { out += "⌥" }
        if contains(.shift)    { out += "⇧" }
        if contains(.command)  { out += "⌘" }
        return out
    }

    /// Individual glyphs, for rendering each modifier as its own keycap.
    public var glyphs: [String] {
        var out: [String] = []
        if contains(.function) { out.append("fn") }
        if contains(.control)  { out.append("⌃") }
        if contains(.option)   { out.append("⌥") }
        if contains(.shift)    { out.append("⇧") }
        if contains(.command)  { out.append("⌘") }
        return out
    }

    /// True when the only modifiers are ⌥ or ⌥⇧.
    ///
    /// Since macOS 15 these fail `RegisterEventHotKey` with `-9868` as an
    /// anti-keylogging measure. Probe results for these combos must never be
    /// reported as conflicts.
    public var isOptionOnlyRestricted: Bool {
        guard contains(.option) else { return false }
        return !contains(.command) && !contains(.control)
    }

    /// Parses a human/config-style modifier token such as `cmd`, `ctrl`, `alt`.
    public static func token(_ raw: String) -> Modifiers? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "cmd", "command", "meta", "super", "⌘", "left_command", "right_command":
            return .command
        case "shift", "⇧", "left_shift", "right_shift":
            return .shift
        case "alt", "opt", "option", "⌥", "left_option", "right_option", "left_alt", "right_alt":
            return .option
        case "ctrl", "control", "⌃", "left_control", "right_control":
            return .control
        case "fn", "function":
            return .function
        default:
            return nil
        }
    }

    /// Parses a separated modifier list such as `cmd + shift` or `shift meta`.
    public static func parseTokens<S: StringProtocol>(_ tokens: [S]) -> Modifiers {
        var result: Modifiers = []
        for raw in tokens {
            if let mod = token(String(raw)) { result.insert(mod) }
        }
        return result
    }
}
