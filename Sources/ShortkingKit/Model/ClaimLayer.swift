import Foundation

/// Where in the dispatch chain a claim sits.
///
/// A physical key press flows from layer 0 downward; anything earlier can swallow
/// it before anything later ever sees it. Lower raw value therefore means "wins".
public enum ClaimLayer: Int, Codable, Hashable, Sendable, CaseIterable, Comparable {
    /// Kernel / DriverKit virtual keyboard remapping — Karabiner-Elements.
    case virtualHID = 0
    /// `CGEventTapCreate(kCGHIDEventTap, …)` — root only.
    case hidTap = 1
    /// `CGEventTapCreate(kCGSessionEventTap, …)` — Keyboard Maestro, BTT, Hammerspoon, skhd.
    case sessionTap = 2
    /// `RegisterEventHotKey` → `CGSSetHotKeyWithExclusion`, matched inside WindowServer.
    case windowServer = 3
    /// WindowServer's own named set — Spotlight, Mission Control, Spaces.
    case symbolic = 4
    /// `NSMenu.performKeyEquivalent:` — only while that app is frontmost.
    case appMenu = 5
    /// Services with a `key_equivalent`.
    case service = 6
    /// Input source switching and the character palette.
    case inputSource = 7

    public static func < (lhs: ClaimLayer, rhs: ClaimLayer) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .virtualHID:   return "Virtual HID"
        case .hidTap:       return "HID tap"
        case .sessionTap:   return "Session tap"
        case .windowServer: return "WindowServer"
        case .symbolic:     return "Symbolic"
        case .appMenu:      return "App menu"
        case .service:      return "Service"
        case .inputSource:  return "Input source"
        }
    }

    /// One line explaining what this layer is, shown in the layer badge's tooltip.
    public var explanation: String {
        switch self {
        case .virtualHID:
            return "Remapped by a virtual keyboard driver before the event reaches macOS."
        case .hidTap:
            return "Intercepted by a root-level HID event tap, ahead of everything else."
        case .sessionTap:
            return "Intercepted by a session event tap. The binding lives in that app's own code."
        case .windowServer:
            return "Matched inside WindowServer before any app sees the key. Works in full screen."
        case .symbolic:
            return "One of macOS's own named system hotkeys."
        case .appMenu:
            return "A menu key equivalent. Only applies while this app is frontmost."
        case .service:
            return "A Services menu key equivalent."
        case .inputSource:
            return "Input source switching, handled by the text input system."
        }
    }

    /// True when this claim applies system-wide rather than only in one app.
    ///
    /// Menu equivalents are the only context-dependent layer; everything else fires
    /// regardless of what is frontmost.
    public var isGlobal: Bool {
        self != .appMenu
    }
}

/// How much Shortking actually knows about a claim.
///
/// The whole point of the tool is that these are distinct and visible. An inference
/// is never rendered as a fact.
public enum ClaimStatus: String, Codable, Hashable, Sendable, CaseIterable {
    /// Read directly from a config file, plist, or the Accessibility API.
    case known
    /// A probe was refused — someone holds this combination, owner unknown.
    case probedClaimed
    /// Attributed by differential or side-channel evidence, with a confidence score.
    case inferred
    /// This process *could* intercept keystrokes, but no specific binding is known.
    case capability

    public var displayName: String {
        switch self {
        case .known:         return "Known"
        case .probedClaimed: return "Unknown owner"
        case .inferred:      return "Inferred"
        case .capability:    return "Capability"
        }
    }

    /// The confidence a freshly created claim of this status starts at.
    public var baselineConfidence: Double {
        switch self {
        case .known:         return 1.0
        case .probedClaimed: return 0.5
        case .inferred:      return 0.3
        case .capability:    return 0.1
        }
    }
}

/// What kind of thing owns a claim.
public enum OwnerKind: String, Codable, Hashable, Sendable {
    case application
    case system
    case configTool
    case service
    case inputMethod
    case unknown
}

/// The claimant of a key combination.
public struct Owner: Codable, Hashable, Sendable {
    public var name: String
    public var bundleID: String?
    public var path: String?
    public var pid: Int32?
    public var kind: OwnerKind

    public init(
        name: String,
        bundleID: String? = nil,
        path: String? = nil,
        pid: Int32? = nil,
        kind: OwnerKind = .application
    ) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.pid = pid
        self.kind = kind
    }

    /// Stable identity across launches — a pid is not identity, a bundle ID is.
    public var identity: String {
        bundleID ?? path ?? name
    }

    /// A readable name for an app we only know by bundle ID.
    ///
    /// `co.podzim.BoltGPT` → `BoltGPT`. Showing the raw identifier in the conflict
    /// list is technically accurate and useless — the user has to recognise the app
    /// to act on the conflict.
    public static func displayName(forBundleID bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? ""
        return last.isEmpty ? bundleID : last
    }

    public static let macOS = Owner(name: "macOS", bundleID: "com.apple.systemuiserver", kind: .system)
}
