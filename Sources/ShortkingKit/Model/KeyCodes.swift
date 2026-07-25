import Foundation

/// Virtual keycode ↔ name/character tables.
///
/// Sources disagree about what they can tell us: the Accessibility API supplies a
/// literal character *or* a virtual keycode *or* a Carbon menu glyph; symbolic
/// hotkeys supply a keycode; text configs supply a name. `KeyCodes` normalizes
/// between all of them so that grouping by combination actually groups.
public enum KeyCodes {

    /// ANSI virtual keycodes from `Carbon/Events.h` (`kVK_*`).
    public static let charToKeyCode: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D,
        "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
        "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A,
        ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
    ]

    /// Named (non-character) keys, keyed by the lowercase name Shortking uses
    /// internally. Config adapters map their own vocabulary onto these names.
    public static let nameToKeyCode: [String: UInt16] = [
        "return": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "escape": 0x35,
        "capslock": 0x39, "help": 0x72, "home": 0x73, "pageup": 0x74,
        "forwarddelete": 0x75, "end": 0x77, "pagedown": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "f13": 0x69, "f14": 0x6B, "f15": 0x71, "f16": 0x6A, "f17": 0x40,
        "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
        "keypad0": 0x52, "keypad1": 0x53, "keypad2": 0x54, "keypad3": 0x55,
        "keypad4": 0x56, "keypad5": 0x57, "keypad6": 0x58, "keypad7": 0x59,
        "keypad8": 0x5B, "keypad9": 0x5C, "keypaddecimal": 0x41,
        "keypadmultiply": 0x43, "keypadplus": 0x45, "keypadclear": 0x47,
        "keypaddivide": 0x4B, "keypadenter": 0x4C, "keypadminus": 0x4E,
        "keypadequals": 0x51,
    ]

    /// Display labels for named keys, using the glyphs macOS itself renders.
    public static let keyCodeToDisplay: [UInt16: String] = [
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋",
        0x39: "⇪", 0x72: "?⃝", 0x73: "↖", 0x74: "⇞", 0x75: "⌦",
        0x77: "↘", 0x79: "⇟", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17",
        0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x4C: "⌤", 0x47: "⌧",
    ]

    /// Carbon menu glyph codes (`kMenu*Glyph` in `Menus.h`) mapped to virtual keycodes.
    ///
    /// Read from `kAXMenuItemCmdGlyphAttribute` when a menu item's shortcut has no
    /// character representation — arrows, Return, Tab, the F-keys and friends.
    public static let glyphToKeyCode: [Int: UInt16] = [
        0x02: 0x30,  // tab right
        0x03: 0x30,  // tab left
        0x04: 0x4C,  // enter
        0x09: 0x31,  // space
        0x0A: 0x75,  // delete right (forward delete)
        0x0B: 0x24,  // return
        0x0D: 0x24,  // nonmarking return
        0x17: 0x33,  // delete left (backspace)
        0x1B: 0x35,  // escape
        0x1C: 0x47,  // clear
        0x62: 0x74,  // page up
        0x63: 0x39,  // caps lock
        0x64: 0x7B,  // left arrow
        0x65: 0x7C,  // right arrow
        0x67: 0x72,  // help
        0x68: 0x7E,  // up arrow
        0x6A: 0x7D,  // down arrow
        0x6B: 0x79,  // page down
        0x6F: 0x7A,  // F1
        0x70: 0x78,  // F2
        0x71: 0x63,  // F3
        0x72: 0x76,  // F4
        0x73: 0x60,  // F5
        0x74: 0x61,  // F6
        0x75: 0x62,  // F7
        0x76: 0x64,  // F8
        0x77: 0x65,  // F9
        0x78: 0x6D,  // F10
        0x79: 0x67,  // F11
        0x7A: 0x6F,  // F12
        0x7B: 0x69,  // F13
        0x7C: 0x6B,  // F14
        0x7D: 0x71,  // F15
    ]

    private static let keyCodeToChar: [UInt16: String] = {
        var out: [UInt16: String] = [:]
        for (char, code) in charToKeyCode { out[code] = char }
        return out
    }()

    private static let keyCodeToName: [UInt16: String] = {
        var out: [UInt16: String] = [:]
        for (name, code) in nameToKeyCode {
            // Prefer the first (canonical) spelling for codes with aliases.
            if out[code] == nil { out[code] = name }
        }
        return out
    }()

    /// Resolves a keycode from a single character, a key name, or an alternate
    /// spelling used by a third-party config.
    public static func keyCode(forToken token: String) -> UInt16? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if let code = nameToKeyCode[lower] { return code }
        if let code = charToKeyCode[lower] { return code }
        if let canonical = aliases[lower] {
            if let code = nameToKeyCode[canonical] { return code }
            if let code = charToKeyCode[canonical] { return code }
        }
        return nil
    }

    /// Alternate spellings used by third-party configs (skhd, VS Code, JetBrains…).
    public static let aliases: [String: String] = [
        "enter": "return", "cr": "return", "ret": "return",
        "esc": "escape",
        "backspace": "delete", "bs": "delete", "back_space": "delete",
        "del": "forwarddelete", "forward_delete": "forwarddelete",
        "spacebar": "space", "spc": "space",
        "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
        "left_arrow": "left", "right_arrow": "right", "up_arrow": "up", "down_arrow": "down",
        "pgup": "pageup", "page_up": "pageup", "pgdn": "pagedown", "page_down": "pagedown",
        "caps_lock": "capslock",
        "grave_accent_and_tilde": "`", "hyphen": "-", "equal_sign": "=",
        "open_bracket": "[", "close_bracket": "]", "backslash": "\\",
        "semicolon": ";", "quote": "'", "comma": ",", "period": ".", "slash": "/",
    ]

    /// A human-facing label for a keycode, preferring glyphs where macOS uses them.
    public static func display(keyCode: UInt16) -> String {
        if let named = keyCodeToDisplay[keyCode] { return named }
        if let char = keyCodeToChar[keyCode] { return char.uppercased() }
        return String(format: "key 0x%02X", keyCode)
    }

    /// The stable internal name for a keycode, for serialization and search.
    public static func name(keyCode: UInt16) -> String? {
        if let named = keyCodeToName[keyCode] { return named }
        return keyCodeToChar[keyCode]
    }

    /// The character a keycode produces on an ANSI layout, if any.
    public static func character(keyCode: UInt16) -> String? {
        keyCodeToChar[keyCode]
    }
}
