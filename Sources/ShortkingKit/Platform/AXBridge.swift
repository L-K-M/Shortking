import ApplicationServices
import Foundation

/// Accessibility helpers for the menu-bar walk.
///
/// Two rules govern everything here:
///
/// 1. **Never expand a menu.** Reading attributes is enough; pressing menus makes
///    dynamic items (Recent Files, Window lists) churn and pollutes the cache.
/// 2. **Always bound the wait.** A beachballed app must degrade to "no menus from
///    this app", never to a stalled scan.
public enum AXBridge {

    /// Whether this process currently holds the Accessibility grant.
    ///
    /// Note that this can lie: launched from a terminal that itself holds
    /// Accessibility, it returns `true` for a binary that has no grant of its own.
    /// `HealthCheck` therefore verifies functionally as well as asking.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks the system to show the Accessibility prompt, if it hasn't already.
    @discardableResult
    public static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Functional check: can this process actually read a menu bar right now?
    ///
    /// `isTrusted` answers "does TCC have a record for us", which is not the same
    /// question. The grant can read as `true` while the process still cannot see
    /// anything — most often just after the user ticks the checkbox, because macOS
    /// caches the decision for the lifetime of the process. Onboarding and Health
    /// both gate on this rather than on the permission bit.
    public static func canReadOwnMenuBar() -> Bool {
        guard isTrusted else { return false }
        let element = application(pid: ProcessInfo.processInfo.processIdentifier, timeout: 1.0)
        return menuBar(of: element) != nil
    }

    /// An application element with a bounded messaging timeout.
    public static func application(pid: pid_t, timeout: Float = 0.25) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    // MARK: - Attribute reads

    public static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    public static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        guard let number = copyAttribute(element, attribute) as? NSNumber else { return nil }
        return number.intValue
    }

    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(element, kAXChildrenAttribute as String) else { return [] }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    /// The application's menu bar element, or `nil` if it has none (agents,
    /// background-only apps, and some Electron/Qt/Java hosts).
    public static func menuBar(of application: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(application, kAXMenuBarAttribute as String) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)  // checked by type ID immediately above
    }

    // MARK: - Menu item shortcuts

    /// The attribute names for menu item key equivalents. Declared as strings
    /// because the `kAXMenuItem*` constants are not exposed uniformly across SDKs.
    public enum MenuAttribute {
        public static let cmdChar = "AXMenuItemCmdChar"
        public static let cmdVirtualKey = "AXMenuItemCmdVirtualKey"
        public static let cmdGlyph = "AXMenuItemCmdGlyph"
        public static let cmdModifiers = "AXMenuItemCmdModifiers"
        public static let markChar = "AXMenuItemMarkChar"
        public static let enabled = "AXEnabled"
    }

    /// Extracts the key equivalent of a single menu item, if it has one.
    ///
    /// Prefers, in order: the literal character, the virtual keycode, then the
    /// Carbon glyph code — the three ways AX can describe a shortcut, only one of
    /// which any given item populates.
    public static func shortcut(of menuItem: AXUIElement) -> KeyCombo? {
        let rawModifiers = int(menuItem, MenuAttribute.cmdModifiers)
        let modifiers = Modifiers(axMenuItemModifiers: rawModifiers ?? 0)

        if let char = string(menuItem, MenuAttribute.cmdChar), !char.isEmpty {
            // AX reports the *unshifted* character; a shift in the modifier mask is
            // authoritative, so we do not re-derive it from letter case here.
            return KeyCombo(keyCode: nil, character: char, modifiers: modifiers)
        }

        if let virtualKey = int(menuItem, MenuAttribute.cmdVirtualKey), virtualKey != 0xFFFF {
            return KeyCombo(keyCode: UInt16(truncatingIfNeeded: virtualKey), modifiers: modifiers)
        }

        if let glyph = int(menuItem, MenuAttribute.cmdGlyph),
           let keyCode = KeyCodes.glyphToKeyCode[glyph] {
            return KeyCombo(keyCode: keyCode, modifiers: modifiers)
        }

        return nil
    }

    public static func title(of element: AXUIElement) -> String? {
        string(element, kAXTitleAttribute as String)
    }
}
