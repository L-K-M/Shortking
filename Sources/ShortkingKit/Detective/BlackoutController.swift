import AppKit
import Foundation

/// Instant triage: turn every WindowServer hotkey off, ask the user to retry.
///
/// - **Works now** → a layer-3 Carbon hotkey was eating it. Go find the name.
/// - **Still broken** → an event tap, a Karabiner remap, secure input, or the app
///   itself.
///
/// Leaving a user's hotkeys globally disabled is a catastrophic bug, so restoration
/// is guaranteed four independent ways: a `defer` on the normal path, an app
/// termination observer, a `deinit`, and a watchdog timer that fires even if the UI
/// is wedged. Any one of them is sufficient.
@MainActor
public final class BlackoutController {

    public enum BlackoutError: LocalizedError {
        case unsupported
        case failedToRead
        case failedToSet

        public var errorDescription: String? {
            switch self {
            case .unsupported:
                return "Blackout needs SkyLight symbols that are not available on this macOS version."
            case .failedToRead:
                return "Could not read the current global hotkey mode, so Shortking will not change it."
            case .failedToSet:
                return "Could not change the global hotkey mode."
            }
        }
    }

    /// Hard ceiling on how long hotkeys may stay disabled, whatever the UI does.
    public static let maximumDuration: TimeInterval = 30

    public private(set) var isActive = false
    public private(set) var expiresAt: Date?

    private var previousMode: SkyLight.GlobalHotKeyMode?
    private var watchdog: Timer?
    private var terminationObserver: NSObjectProtocol?

    /// Called when the blackout ends, for any reason.
    public var onEnd: (() -> Void)?

    public init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restore() }
        }
    }

    deinit {
        // `restore()` is main-actor isolated and `deinit` is not, so the restore is
        // done inline here. This is the last-resort path: if we get here still
        // active, every other guarantee has already failed.
        if isActive, let previousMode {
            SkyLight.shared.setGlobalHotKeyMode(previousMode)
        }
        watchdog?.invalidate()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    public var isSupported: Bool {
        SkyLight.shared.supportsBlackout
    }

    /// Disables global hotkeys for `duration` (capped at ``maximumDuration``).
    public func begin(duration: TimeInterval = 10) throws {
        guard isSupported else { throw BlackoutError.unsupported }
        guard !isActive else { return }

        guard let current = SkyLight.shared.globalHotKeyMode() else {
            throw BlackoutError.failedToRead
        }
        previousMode = current

        // Universal Access shortcuts stay live: disabling a user's accessibility
        // shortcuts, even for ten seconds, is not an acceptable diagnostic.
        guard SkyLight.shared.setGlobalHotKeyMode(.disabledExceptUniversalAccess) else {
            previousMode = nil
            throw BlackoutError.failedToSet
        }

        let capped = min(duration, Self.maximumDuration)
        isActive = true
        expiresAt = Date().addingTimeInterval(capped)

        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: capped, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.restore() }
        }
        // Fire even while a modal panel or menu tracking loop owns the run loop.
        if let watchdog {
            RunLoop.main.add(watchdog, forMode: .common)
        }

        Log.detective.notice("Blackout engaged for \(capped, privacy: .public)s")
    }

    /// Restores the previous mode. Safe to call repeatedly.
    public func restore() {
        guard isActive else { return }
        if let previousMode {
            let restored = SkyLight.shared.setGlobalHotKeyMode(previousMode)
            if !restored {
                // Last-ditch: if we cannot restore the exact previous mode, force
                // hotkeys back on. A wrong-but-enabled state beats a disabled one.
                SkyLight.shared.setGlobalHotKeyMode(.enabled)
                Log.detective.error("Could not restore the previous hotkey mode; forced enabled")
            }
        }
        previousMode = nil
        isActive = false
        expiresAt = nil
        watchdog?.invalidate()
        watchdog = nil
        Log.detective.notice("Blackout restored")
        onEnd?()
    }

    /// Seconds left, for the countdown in the blackout banner.
    public var remainingSeconds: Int {
        guard let expiresAt else { return 0 }
        return max(0, Int(expiresAt.timeIntervalSinceNow.rounded(.up)))
    }

    /// The conclusion to draw from what the user reports.
    public static func interpret(shortcutWorkedDuringBlackout: Bool, combo: KeyCombo) -> String {
        if shortcutWorkedDuringBlackout {
            return "\(combo.displayString) worked with global hotkeys disabled, so a hotkey "
                + "registered with WindowServer was consuming it. That narrows it to the "
                + "WindowServer layer — run a live capture, or let Shortking identify the owner "
                + "across app restarts."
        }
        return "\(combo.displayString) still did not work with global hotkeys disabled, so no "
            + "WindowServer hotkey is responsible. That leaves a filtering event tap (Keyboard "
            + "Maestro, BetterTouchTool, Hammerspoon, skhd), a Karabiner-Elements remap above the "
            + "event chain, secure input mode, or the frontmost app's own handling. Check the "
            + "Suspects list and the Health screen."
    }
}
