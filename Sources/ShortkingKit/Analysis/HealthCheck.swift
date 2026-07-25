import AppKit
import CoreGraphics
import Foundation

/// A single diagnostic about the machine or about Shortking's own ability to see it.
public struct HealthCheck: Identifiable, Sendable {

    public enum Status: String, Sendable {
        case ok
        case warning
        case failing
        case unknown

        public var displayName: String {
            switch self {
            case .ok:      return "OK"
            case .warning: return "Warning"
            case .failing: return "Problem"
            case .unknown: return "Unknown"
            }
        }
    }

    /// What the user can do about it.
    public enum Action: Sendable {
        case openSettings(pane: String)
        case requestAccessibility
        case revealPath(String)
        case rescan
        /// Quit and reopen — the fix for a permission that needs a fresh process.
        case relaunch
        /// Deliberately not spelled `none`, which would read ambiguously against
        /// `Optional.none` at every call site.
        case noAction
    }

    public var id: String
    public var title: String
    public var status: Status
    public var message: String
    public var detail: String?
    public var action: Action

    public init(
        id: String,
        title: String,
        status: Status,
        message: String,
        detail: String? = nil,
        action: Action = .noAction
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.message = message
        self.detail = detail
        self.action = action
    }
}

/// Runs the non-conflict diagnostics.
///
/// A large share of "my shortcut broke" is not a conflict at all — it is secure
/// input stuck on, a tap that silently died after an app was re-signed, or the
/// macOS 15 ⌥-hardening. Detecting these is what makes Shortking useful on the
/// first launch, before any inventory has accumulated.
///
/// Permission checks here verify *functionally* rather than by asking:
/// `AXIsProcessTrusted()` returns `true` for a binary launched from a terminal that
/// itself holds Accessibility, and an event tap can be created successfully and then
/// never fire after a code-signature change. Asking the system is not the same as
/// knowing.
public struct HealthReport: Sendable {
    public var checks: [HealthCheck]
    public var generatedAt: Date

    public init(checks: [HealthCheck], generatedAt: Date = Date()) {
        self.checks = checks
        self.generatedAt = generatedAt
    }

    public var worstStatus: HealthCheck.Status {
        if checks.contains(where: { $0.status == .failing }) { return .failing }
        if checks.contains(where: { $0.status == .warning }) { return .warning }
        if checks.contains(where: { $0.status == .unknown }) { return .unknown }
        return .ok
    }

    public var problems: [HealthCheck] {
        checks.filter { $0.status == .failing || $0.status == .warning }
    }
}

public enum HealthChecker {

    public static func run(
        eventTaps: [EventTapInfo],
        probeReport: ProbeReport?,
        previouslyEnabledTapIDs: Set<UInt32> = []
    ) -> HealthReport {
        var checks: [HealthCheck] = []

        checks.append(accessibilityCheck())
        checks.append(inputMonitoringCheck())
        checks.append(secureInputCheck())
        checks.append(privateSymbolCheck())
        if let probeReport {
            checks.append(probingCheck(probeReport))
            checks.append(optionHardeningCheck(probeReport))
        }
        checks.append(deadTapCheck(eventTaps: eventTaps, previouslyEnabled: previouslyEnabledTapIDs))
        checks.append(bundleCheck())

        return HealthReport(checks: checks)
    }

    // MARK: - Permissions

    static func accessibilityCheck() -> HealthCheck {
        guard AXBridge.isTrusted else {
            return HealthCheck(
                id: "accessibility",
                title: "Accessibility",
                status: .failing,
                message: "Not granted. Menu bar shortcuts cannot be read.",
                detail: "System Settings ▸ Privacy & Security ▸ Accessibility",
                action: .requestAccessibility
            )
        }

        // Functional verification: walk our own menu bar. If the grant was only just
        // ticked, or lapsed after a re-sign, this fails while `AXIsProcessTrusted()`
        // still says yes.
        if !AXBridge.canReadOwnMenuBar() {
            return HealthCheck(
                id: "accessibility",
                title: "Accessibility",
                status: .warning,
                message: "Granted, but a test menu read returned nothing.",
                detail: "If you just granted it, relaunch Shortking — macOS caches the decision "
                    + "for the life of the process. Otherwise the grant has lapsed, which happens "
                    + "when the app is updated or re-signed; remove Shortking from the "
                    + "Accessibility list and add it again.",
                action: .relaunch
            )
        }

        return HealthCheck(
            id: "accessibility",
            title: "Accessibility",
            status: .ok,
            message: "Granted and working."
        )
    }

    static func inputMonitoringCheck() -> HealthCheck {
        // Creating a listen-only tap is the only reliable probe: the TCC API for
        // Input Monitoring reports intent, not capability.
        let mask = (UInt64(1) << UInt64(CGEventType.keyDown.rawValue))
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )

        guard let tap else {
            return HealthCheck(
                id: "input-monitoring",
                title: "Input Monitoring",
                status: .warning,
                message: "Not granted. Detective Mode's live capture is unavailable.",
                detail: "System Settings ▸ Privacy & Security ▸ Input Monitoring. "
                    + "The inventory works without this; only live attribution needs it.",
                action: .openSettings(pane: "Privacy_ListenEvent")
            )
        }

        CGEvent.tapEnable(tap: tap, enable: false)

        return HealthCheck(
            id: "input-monitoring",
            title: "Input Monitoring",
            status: .ok,
            message: "Granted. Detective Mode is available."
        )
    }

    // MARK: - System state

    static func secureInputCheck() -> HealthCheck {
        let state = SecureInput.currentState()
        guard state.isEnabled else {
            return HealthCheck(
                id: "secure-input",
                title: "Secure input",
                status: .ok,
                message: "Off. Event taps receive keystrokes normally."
            )
        }

        let holder = state.suspectedHolder.map { " Held by \($0)." } ?? ""
        return HealthCheck(
            id: "secure-input",
            title: "Secure input",
            status: .warning,
            message: "Secure event input is on.\(holder)",
            detail: "While secure input is active, event taps stop receiving keys — so shortcuts "
                + "from tap-based tools (Keyboard Maestro, BetterTouchTool, Hammerspoon, skhd) will "
                + "not fire. This is normal while a password field is focused, but apps sometimes "
                + "leave it stuck on after quitting. If no password field is focused, quitting the "
                + "app named above usually clears it.",
            action: .noAction
        )
    }

    static func privateSymbolCheck() -> HealthCheck {
        let skylight = SkyLight.shared
        guard skylight.isAvailable else {
            return HealthCheck(
                id: "private-symbols",
                title: "SkyLight symbols",
                status: .warning,
                message: "SkyLight could not be opened. Live system shortcuts and Blackout are off.",
                detail: "Shortking falls back to reading com.apple.symbolichotkeys.plist, which is "
                    + "usually complete but can miss unwritten defaults and MDM-managed values."
            )
        }

        let missing = skylight.resolvedSymbols.filter { !$0.value }.keys.sorted()
        let haveEverything = skylight.supportsSymbolicHotKeys && skylight.supportsBlackout

        if haveEverything {
            return HealthCheck(
                id: "private-symbols",
                title: "SkyLight symbols",
                status: .ok,
                message: "All required symbols resolved on this macOS build."
            )
        }

        var disabled: [String] = []
        if !skylight.supportsSymbolicHotKeys { disabled.append("live system shortcut reads") }
        if !skylight.supportsBlackout { disabled.append("Blackout bisection") }

        return HealthCheck(
            id: "private-symbols",
            title: "SkyLight symbols",
            status: .warning,
            message: "Some private symbols are missing. Disabled: \(disabled.joined(separator: ", ")).",
            detail: missing.isEmpty ? nil : "Unresolved: \(missing.joined(separator: ", "))"
        )
    }

    // MARK: - Probe-derived

    static func probingCheck(_ report: ProbeReport) -> HealthCheck {
        guard report.probingVerified else {
            return HealthCheck(
                id: "probing",
                title: "Hotkey probing",
                status: .warning,
                message: "This macOS build permits duplicate hotkey registration.",
                detail: "Shortking verifies on every launch that registering an already-taken "
                    + "combination is refused. On this machine it was not, so probe results cannot "
                    + "distinguish taken from free. The claimed-combination map is hidden rather "
                    + "than shown wrongly; Detective Mode's live capture still works."
            )
        }

        var detail = "\(report.claimed.count) of \(report.results.count) probed combinations are "
            + "held by someone at the WindowServer layer."
        if !report.unknownStatusCodes.isEmpty {
            let codes = report.unknownStatusCodes.map(String.init).joined(separator: ", ")
            detail += " Unrecognised status codes seen: \(codes)."
        }

        return HealthCheck(
            id: "probing",
            title: "Hotkey probing",
            status: report.unknownStatusCodes.isEmpty ? .ok : .warning,
            message: "Working. Duplicate registration is correctly refused.",
            detail: detail
        )
    }

    static func optionHardeningCheck(_ report: ProbeReport) -> HealthCheck {
        let restricted = report.restricted
        guard !restricted.isEmpty else {
            return HealthCheck(
                id: "option-hardening",
                title: "Option-key restriction",
                status: .ok,
                message: "No combinations were refused by the macOS Option-key restriction."
            )
        }

        let examples = restricted.prefix(4).map { $0.combo.displayString }.joined(separator: ", ")
        return HealthCheck(
            id: "option-hardening",
            title: "Option-key restriction",
            status: .warning,
            message: "\(restricted.count) Option-only combinations cannot be registered by any app.",
            detail: "Since macOS 15, shortcuts whose only modifiers are ⌥ or ⌥⇧ are refused with "
                + "error -9868 as an anti-keylogging measure — ⌥⇧ produces alternate characters used "
                + "in passwords. Apple's own shortcuts are exempt. If one of your ⌥ shortcuts stopped "
                + "working after upgrading, this is why, and it is not a conflict. Examples: \(examples)."
        )
    }

    // MARK: - Taps

    static func deadTapCheck(eventTaps: [EventTapInfo], previouslyEnabled: Set<UInt32>) -> HealthCheck {
        let dead = eventTaps.filter { !$0.enabled }
        let regressed = dead.filter { previouslyEnabled.contains($0.tapID) }

        if !regressed.isEmpty {
            let names = Array(Set(regressed.map(\.owner.name))).sorted().joined(separator: ", ")
            return HealthCheck(
                id: "dead-taps",
                title: "Event taps",
                status: .failing,
                message: "\(regressed.count) event tap(s) stopped working: \(names).",
                detail: "A tap that was enabled and now is not has usually been disabled by a "
                    + "timeout, by user input during a slow callback, or by a code-signature change "
                    + "after an app update. Restarting the app named above normally fixes it.",
                action: .noAction
            )
        }

        if !dead.isEmpty {
            let names = Array(Set(dead.map(\.owner.name))).sorted().joined(separator: ", ")
            return HealthCheck(
                id: "dead-taps",
                title: "Event taps",
                status: .warning,
                message: "\(dead.count) installed event tap(s) are disabled: \(names).",
                detail: "These processes registered a tap but it is not currently receiving events. "
                    + "Their keyboard shortcuts will not fire."
            )
        }

        return HealthCheck(
            id: "dead-taps",
            title: "Event taps",
            status: .ok,
            message: "\(eventTaps.count) event tap(s) installed, all enabled."
        )
    }

    // MARK: - Our own packaging

    static func bundleCheck() -> HealthCheck {
        // TCC identity is bundle- and signature-based. Running the bare SPM binary
        // gets grants attributed to the *terminal*, which makes every permission
        // check lie — worth saying out loud rather than debugging twice.
        let isBundled = Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundlePath.hasSuffix(".app")

        guard isBundled else {
            return HealthCheck(
                id: "bundle",
                title: "App bundle",
                status: .warning,
                message: "Running as a bare executable, not from an app bundle.",
                detail: "Permission grants are attributed to whatever launched this process, so "
                    + "Accessibility and Input Monitoring checks may report the wrong thing. Build "
                    + "the bundle with `make app` and launch it from /Applications before trusting "
                    + "any permission result."
            )
        }

        return HealthCheck(
            id: "bundle",
            title: "App bundle",
            status: .ok,
            message: "Running from \(Bundle.main.bundlePath)."
        )
    }
}
