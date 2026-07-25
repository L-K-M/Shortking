import Foundation

/// User preferences. Persisted as JSON alongside the rest of the store rather than
/// in `UserDefaults`, so that "reveal my data" shows the user everything in one
/// folder.
public struct Settings: Codable, Hashable, Sendable {
    public var scanOptions: ScanOptions
    /// Background differential learning across app launch/quit.
    public var differentialLearningEnabled: Bool
    /// Rescan automatically when apps launch or quit.
    public var rescanOnAppLifecycle: Bool
    /// Adapters the user has switched off, by identifier.
    public var disabledAdapters: Set<String>
    public var hasCompletedOnboarding: Bool
    /// Result of Experiment A, measured on this machine.
    public var probingVerified: Bool?
    public var probingVerifiedAt: Date?

    public init(
        scanOptions: ScanOptions = .default,
        differentialLearningEnabled: Bool = true,
        rescanOnAppLifecycle: Bool = true,
        disabledAdapters: Set<String> = [],
        hasCompletedOnboarding: Bool = false,
        probingVerified: Bool? = nil,
        probingVerifiedAt: Date? = nil
    ) {
        self.scanOptions = scanOptions
        self.differentialLearningEnabled = differentialLearningEnabled
        self.rescanOnAppLifecycle = rescanOnAppLifecycle
        self.disabledAdapters = disabledAdapters
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.probingVerified = probingVerified
        self.probingVerifiedAt = probingVerifiedAt
    }
}

/// Loads and saves ``Settings``.
public final class SettingsStore: @unchecked Sendable {

    public static let shared = SettingsStore()

    private let store = JSONStore<Settings>(filename: "settings.json")
    private let lock = NSLock()
    private var cached: Settings

    public init() {
        cached = store.load() ?? Settings()
    }

    public var current: Settings {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    public func update(_ transform: (inout Settings) -> Void) {
        lock.lock()
        var settings = cached
        transform(&settings)
        cached = settings
        lock.unlock()
        store.save(settings)
    }
}
