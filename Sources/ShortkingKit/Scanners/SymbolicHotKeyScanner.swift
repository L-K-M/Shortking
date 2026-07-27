import Foundation

/// macOS's own named hotkey set — Spotlight, Mission Control, Spaces, screenshots.
///
/// Read two ways, because neither is complete on its own:
///
/// - **Static**: `com.apple.symbolichotkeys.plist` → `AppleSymbolicHotKeys`, which
///   carries the `enabled` flag but only reflects values that have been written.
/// - **Live**: `CGSGetSymbolicHotKeyValue` over IDs `0…300`, which catches defaults
///   that were never written out and MDM-managed values the plist doesn't show.
///
/// Live results win where the two disagree, because the live path is what
/// WindowServer will actually match against.
public final class SymbolicHotKeyScanner: ClaimSource {

    public let identifier = "symbolic"
    public let displayName = "macOS system shortcuts"

    /// The live sweep range. Apple's assigned IDs are sparse and well under 300.
    private let liveIDRange: ClosedRange<Int32> = 0...300

    public init() {}

    public func isEnabled(for options: ScanOptions) -> Bool {
        options.includeSymbolicHotKeys
    }

    public func scan(context: ScanContext) async throws -> [Claim] {
        var byID: [Int32: Claim] = [:]

        for claim in scanPlist() {
            if let id = claim.symbolicID { byID[id] = claim }
        }

        // Live values override the plist: they are what actually matches.
        for claim in scanLive() {
            guard let id = claim.symbolicID else { continue }
            if var existing = byID[id] {
                existing.merge(claim)
                // The live combo is authoritative even when the plist disagrees.
                existing.combo = claim.combo
                byID[id] = existing
            } else {
                byID[id] = claim
            }
        }

        return Array(byID.values)
    }

    // MARK: - Static plist

    private func scanPlist() -> [Claim] {
        let path = NSHomeDirectory() + "/Library/Preferences/com.apple.symbolichotkeys.plist"
        guard let root = NSDictionary(contentsOfFile: path) as? [String: Any],
              let hotkeys = root["AppleSymbolicHotKeys"] as? [String: Any] else {
            return []
        }

        var claims: [Claim] = []
        for (key, raw) in hotkeys {
            guard let id = Int32(key),
                  let entry = raw as? [String: Any] else { continue }

            let enabled = (entry["enabled"] as? Bool) ?? true
            guard let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any],
                  parameters.count >= 3 else { continue }

            // parameters = [asciiCharacter, virtualKeyCode, cocoaModifierMask]
            let asciiValue = numeric(parameters[0])
            let keyCodeValue = numeric(parameters[1])
            let modifierValue = numeric(parameters[2])

            guard let modifierValue else { continue }
            let modifiers = Modifiers(cocoa: UInt64(bitPattern: Int64(modifierValue)))

            var keyCode: UInt16?
            if let keyCodeValue, keyCodeValue >= 0, keyCodeValue != 65535 {
                keyCode = UInt16(truncatingIfNeeded: keyCodeValue)
            }
            var character: String?
            if let asciiValue, asciiValue > 0, asciiValue != 65535,
               let scalar = Unicode.Scalar(UInt32(asciiValue)) {
                character = String(Character(scalar))
            }
            guard keyCode != nil || character != nil else { continue }

            let combo = KeyCombo(keyCode: keyCode, character: character, modifiers: modifiers)
            claims.append(makeClaim(id: id, combo: combo, enabled: enabled, source: .plist, path: path))
        }
        return claims
    }

    private func numeric(_ any: Any) -> Int? {
        if let number = any as? NSNumber { return number.intValue }
        if let int = any as? Int { return int }
        if let double = any as? Double { return Int(double) }
        return nil
    }

    // MARK: - Live CGS

    private func scanLive() -> [Claim] {
        let skylight = SkyLight.shared
        guard skylight.supportsSymbolicHotKeys else { return [] }

        var claims: [Claim] = []
        for id in liveIDRange {
            guard let value = skylight.symbolicHotKey(id: id) else { continue }

            var keyCode: UInt16?
            if value.virtualKeyCode != 0xFFFF { keyCode = value.virtualKeyCode }
            var character: String?
            if value.keyEquivalent != 0xFFFF, value.keyEquivalent > 0,
               let scalar = Unicode.Scalar(UInt32(value.keyEquivalent)) {
                character = String(Character(scalar))
            }
            guard keyCode != nil || character != nil else { continue }

            let combo = KeyCombo(
                keyCode: keyCode,
                character: character,
                modifiers: Modifiers(cocoa: value.modifiers)
            )
            guard !combo.isBare else { continue }

            claims.append(
                makeClaim(id: id, combo: combo, enabled: value.enabled, source: .live, path: nil)
            )
        }
        return claims
    }

    // MARK: - Claim construction

    private enum SourceKind: String {
        case plist
        case live
    }

    private func makeClaim(
        id: Int32,
        combo: KeyCombo,
        enabled: Bool,
        source: SourceKind,
        path: String?
    ) -> Claim {
        var detail: [String: String] = [
            "symbolicHotKeyID": "\(id)",
            "source": source.rawValue,
        ]
        if let path { detail["path"] = path }

        var claim = Claim(
            combo: combo,
            layer: .symbolic,
            status: .known,
            owner: SymbolicHotKeyCatalog.owner(for: id),
            label: SymbolicHotKeyCatalog.label(for: id),
            enabled: enabled,
            evidence: [
                Evidence(
                    kind: .symbolicHotKey,
                    summary: "Symbolic hotkey \(id) — \(SymbolicHotKeyCatalog.label(for: id))",
                    detail: detail
                )
            ]
        )
        claim.symbolicID = id
        return claim
    }
}

// MARK: - Symbolic ID carried alongside the claim

extension Claim {
    /// The symbolic hotkey ID, when this claim came from the symbolic layer.
    ///
    /// Stored in the evidence detail rather than as a stored property so that
    /// `Claim` stays a single flat, persistable shape regardless of layer.
    var symbolicID: Int32? {
        get {
            for item in evidence where item.kind == .symbolicHotKey {
                if let raw = item.detail["symbolicHotKeyID"], let id = Int32(raw) { return id }
            }
            return nil
        }
        set {
            guard let newValue else { return }
            for index in evidence.indices where evidence[index].kind == .symbolicHotKey {
                evidence[index].detail["symbolicHotKeyID"] = "\(newValue)"
            }
        }
    }
}

/// Human labels for the symbolic hotkey IDs worth naming.
///
/// Apple ships no public list. These are the well-established ones; anything else
/// is reported honestly as "System shortcut <id>" rather than guessed at.
public enum SymbolicHotKeyCatalog {

    public static let labels: [Int32: String] = [
        1: "Move focus to the next application (⌘Tab)",
        2: "Move focus to the previous application",
        3: "Move focus to the next window in the application",
        4: "Move focus to the previous window",
        5: "Turn keyboard access on or off",
        6: "Change the way Tab moves focus",
        7: "Move focus to the menu bar",
        8: "Move focus to the Dock",
        9: "Move focus to the active or next window",
        10: "Move focus to the window toolbar",
        11: "Move focus to the floating window",
        12: "Move focus to the next window",
        13: "Move focus to the status menus",
        15: "Turn zoom on or off",
        17: "Zoom in",
        19: "Zoom out",
        21: "Reverse black and white",
        23: "Turn image smoothing on or off",
        25: "Increase contrast",
        26: "Decrease contrast",
        27: "Move focus to the next window",
        28: "Save picture of screen as a file",
        29: "Copy picture of screen to the clipboard",
        30: "Save picture of selected area as a file",
        31: "Copy picture of selected area to the clipboard",
        32: "Mission Control",
        33: "Application windows",
        34: "Show Desktop",
        35: "Show Dashboard",
        36: "Show Notification Center",
        37: "Show Launchpad",
        50: "Show the character palette",
        51: "Show the emoji picker",
        52: "Turn VoiceOver on or off",
        59: "Select the previous input source",
        60: "Select the next source in the input menu",
        61: "Select the next input source",
        62: "Show Spotlight (legacy)",
        64: "Show Spotlight search",
        65: "Show Spotlight Finder search window",
        70: "Look up in Dictionary",
        73: "Show Help menu",
        79: "Move left a space",
        80: "Move right a space",
        81: "Move left a space (alternate)",
        82: "Move right a space (alternate)",
        83: "Switch to Desktop 1",
        84: "Switch to Desktop 2",
        85: "Switch to Desktop 3",
        86: "Switch to Desktop 4",
        98: "Show Help menu",
        118: "Switch to Desktop 1",
        119: "Switch to Desktop 2",
        120: "Switch to Desktop 3",
        121: "Switch to Desktop 4",
        160: "Show Launchpad",
        162: "Show Notification Center",
        163: "Show Do Not Disturb",
        164: "Show Quick Note",
        175: "Show Stage Manager",
        179: "Show Focus",
        184: "Save picture of screen to the clipboard",
        190: "Screenshot and recording options",
    ]

    /// The preference domain every symbolic hotkey belongs to.
    ///
    /// Shared rather than spelled out at each site, because it is half of a symbolic
    /// claim's ``Claim/identity``: any source describing the same hotkey has to
    /// produce the same owner identity or the merger sees two claimants where there
    /// is one. See ``owner(for:)``.
    public static let bundleID = "com.apple.symbolichotkeys"

    public static func label(for id: Int32) -> String {
        labels[id] ?? "System shortcut \(id)"
    }

    /// Which part of macOS owns an ID, where it is meaningful to distinguish.
    public static func ownerName(for id: Int32) -> String {
        switch id {
        case 64, 65: return "Spotlight"
        case 32, 33, 34, 36, 37, 79...86, 118...121: return "Mission Control"
        case 28...31, 184, 190: return "Screenshot"
        case 50, 51: return "Character Palette"
        case 59...61: return "Input Sources"
        default: return "macOS"
        }
    }

    /// The canonical owner for a symbolic hotkey ID.
    ///
    /// Every source that describes a symbolic hotkey must build its claim through
    /// this, so that two sources describing the same hotkey produce the same
    /// ``Claim/identity`` and merge into one record. `InputSourceScanner` used to
    /// mint its own owner at a different layer, and the analyzer duly reported
    /// ⌃Space as shadowing itself on every Mac with two input sources.
    public static func owner(for id: Int32) -> Owner {
        Owner(name: ownerName(for: id), bundleID: bundleID, kind: .system)
    }
}
