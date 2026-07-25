import Foundation

/// The one and only place Shortking touches private API.
///
/// Every symbol is resolved with `dlsym`, trying the modern `SLS*` name first and
/// falling back to the legacy `CGS*` alias (the symbols moved from CoreGraphics to
/// SkyLight around macOS 12). Every symbol is optional and every call site degrades
/// gracefully — a missing symbol on a future macOS disables one feature and raises a
/// Health warning naming it. It must never crash the app.
public final class SkyLight: @unchecked Sendable {

    public static let shared = SkyLight()

    private let handle: UnsafeMutableRawPointer?

    /// Which symbols resolved on this OS build. Surfaced in Health so a bug report
    /// says exactly what this machine has. Written once during `init` and read-only
    /// thereafter, which is what makes the `@unchecked Sendable` honest.
    public let resolvedSymbols: [String: Bool]

    // MARK: - C function types

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias GetSymbolicHotKeyValueFn = @convention(c) (
        Int32,
        UnsafeMutablePointer<UInt16>,
        UnsafeMutablePointer<UInt16>,
        UnsafeMutablePointer<UInt64>
    ) -> Int32
    private typealias IsSymbolicHotKeyEnabledFn = @convention(c) (Int32) -> Bool
    private typealias SetSymbolicHotKeyEnabledFn = @convention(c) (Int32, Bool) -> Int32
    private typealias GetGlobalHotKeyOperatingModeFn = @convention(c) (
        Int32, UnsafeMutablePointer<Int32>
    ) -> Int32
    private typealias SetGlobalHotKeyOperatingModeFn = @convention(c) (Int32, Int32) -> Int32

    // Resolved eagerly in `init` rather than lazily: `SkyLight.shared` is reached
    // from several threads, and a lazy var is not thread-safe.
    private let mainConnectionIDFn: MainConnectionIDFn?
    private let getSymbolicHotKeyValueFn: GetSymbolicHotKeyValueFn?
    private let isSymbolicHotKeyEnabledFn: IsSymbolicHotKeyEnabledFn?
    private let setSymbolicHotKeyEnabledFn: SetSymbolicHotKeyEnabledFn?
    private let getGlobalModeFn: GetGlobalHotKeyOperatingModeFn?
    private let setGlobalModeFn: SetGlobalHotKeyOperatingModeFn?

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        )
        self.handle = handle
        if handle == nil {
            Log.platform.warning("SkyLight.framework could not be opened; private paths disabled")
        }

        var resolved: [String: Bool] = [:]

        func lookup<T>(_ names: [String]) -> T? {
            guard let handle else {
                for name in names where resolved[name] != true { resolved[name] = false }
                return nil
            }
            for name in names {
                if let symbol = dlsym(handle, name) {
                    resolved[name] = true
                    return unsafeBitCast(symbol, to: T.self)
                }
                if resolved[name] != true { resolved[name] = false }
            }
            let joined = names.joined(separator: " / ")
            Log.platform.warning("SkyLight symbol unavailable: \(joined, privacy: .public)")
            return nil
        }

        // The symbols moved from CoreGraphics to SkyLight around macOS 12 and
        // picked up SLS* aliases, so the modern name is tried first.
        mainConnectionIDFn = lookup(["SLSMainConnectionID", "CGSMainConnectionID"])
        getSymbolicHotKeyValueFn = lookup(
            ["SLSGetSymbolicHotKeyValue", "CGSGetSymbolicHotKeyValue"]
        )
        isSymbolicHotKeyEnabledFn = lookup(
            ["SLSIsSymbolicHotKeyEnabled", "CGSIsSymbolicHotKeyEnabled"]
        )
        setSymbolicHotKeyEnabledFn = lookup(
            ["SLSSetSymbolicHotKeyEnabled", "CGSSetSymbolicHotKeyEnabled"]
        )
        getGlobalModeFn = lookup(
            ["SLSGetGlobalHotKeyOperatingMode", "CGSGetGlobalHotKeyOperatingMode"]
        )
        setGlobalModeFn = lookup(
            ["SLSSetGlobalHotKeyOperatingMode", "CGSSetGlobalHotKeyOperatingMode"]
        )

        resolvedSymbols = resolved
    }

    // MARK: - Availability

    public var isAvailable: Bool { handle != nil }

    /// Live symbolic hotkey enumeration is possible on this OS build.
    public var supportsSymbolicHotKeys: Bool {
        getSymbolicHotKeyValueFn != nil && mainConnectionIDFn != nil
    }

    /// Blackout bisection is possible on this OS build.
    public var supportsBlackout: Bool {
        getGlobalModeFn != nil && setGlobalModeFn != nil && mainConnectionIDFn != nil
    }

    // MARK: - Connection

    public var mainConnectionID: Int32? {
        mainConnectionIDFn?()
    }

    // MARK: - Symbolic hotkeys

    public struct SymbolicHotKeyValue: Sendable {
        public var hotKeyID: Int32
        public var keyEquivalent: UInt16
        public var virtualKeyCode: UInt16
        public var modifiers: UInt64
        public var enabled: Bool
    }

    /// Reads one symbolic hotkey's live value.
    ///
    /// Returns `nil` when the symbol is unavailable or the hotkey ID is unassigned.
    public func symbolicHotKey(id: Int32) -> SymbolicHotKeyValue? {
        guard let fn = getSymbolicHotKeyValueFn else { return nil }

        var keyEquivalent: UInt16 = 0
        var virtualKeyCode: UInt16 = 0
        var modifiers: UInt64 = 0

        let status = fn(id, &keyEquivalent, &virtualKeyCode, &modifiers)
        guard status == 0 else { return nil }

        // 0xFFFF in both slots means "no binding assigned to this ID".
        if virtualKeyCode == 0xFFFF && keyEquivalent == 0xFFFF { return nil }

        return SymbolicHotKeyValue(
            hotKeyID: id,
            keyEquivalent: keyEquivalent,
            virtualKeyCode: virtualKeyCode,
            modifiers: modifiers,
            enabled: isSymbolicHotKeyEnabled(id: id) ?? true
        )
    }

    public func isSymbolicHotKeyEnabled(id: Int32) -> Bool? {
        isSymbolicHotKeyEnabledFn?(id)
    }

    // MARK: - Global hotkey operating mode (Blackout)

    public enum GlobalHotKeyMode: Int32, Sendable {
        case enabled = 0
        case disabled = 1
        case disabledExceptUniversalAccess = 2
    }

    public func globalHotKeyMode() -> GlobalHotKeyMode? {
        guard let fn = getGlobalModeFn, let cid = mainConnectionID else { return nil }
        var raw: Int32 = 0
        guard fn(cid, &raw) == 0 else { return nil }
        return GlobalHotKeyMode(rawValue: raw)
    }

    /// Sets the global hotkey operating mode.
    ///
    /// Callers **must** guarantee restoration — see `BlackoutController`, which owns
    /// every use of this in the app and wraps it in `defer`, signal handlers and an
    /// independent watchdog. Leaving a user's hotkeys globally disabled is a
    /// catastrophic bug.
    @discardableResult
    public func setGlobalHotKeyMode(_ mode: GlobalHotKeyMode) -> Bool {
        guard let fn = setGlobalModeFn, let cid = mainConnectionID else { return false }
        return fn(cid, mode.rawValue) == 0
    }
}
