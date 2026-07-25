import AppKit
import Foundation

/// A running application, snapshotted once per scan so every source sees the same
/// world (and so no source has to touch `NSWorkspace` off the main thread).
public struct RunningApp: Hashable, Sendable {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    public var bundlePath: String?
    public var version: String?
    public var isActive: Bool
    /// `.regular` apps own a menu bar; `.accessory` and `.prohibited` do not.
    public var hasMenuBar: Bool

    public init(
        pid: Int32,
        name: String,
        bundleID: String?,
        bundlePath: String?,
        version: String?,
        isActive: Bool,
        hasMenuBar: Bool
    ) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.version = version
        self.isActive = isActive
        self.hasMenuBar = hasMenuBar
    }

    public var owner: Owner {
        Owner(
            name: name,
            bundleID: bundleID,
            path: bundlePath,
            pid: pid,
            kind: bundleID?.hasPrefix("com.apple.") == true ? .system : .application
        )
    }

    /// Cache key for the menu walk — invalidated automatically on app update.
    public var cacheKey: String {
        "\(bundleID ?? bundlePath ?? name)@\(version ?? "?")"
    }
}

/// An installed application bundle, whether or not it is running.
public struct InstalledApp: Hashable, Sendable {
    public var name: String
    public var bundleID: String?
    public var bundlePath: String
    public var executablePath: String?
    public var version: String?

    public init(
        name: String,
        bundleID: String?,
        bundlePath: String,
        executablePath: String?,
        version: String?
    ) {
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.version = version
    }

    public var owner: Owner {
        Owner(
            name: name,
            bundleID: bundleID,
            path: bundlePath,
            pid: nil,
            kind: bundleID?.hasPrefix("com.apple.") == true ? .system : .application
        )
    }
}

/// Which sources a scan should run, and how hard it should work.
public struct ScanOptions: Codable, Hashable, Sendable {
    public var includeMenus: Bool
    /// Walk menus only for the frontmost app — the fast mode, for machines with a
    /// lot of running apps.
    public var menusForFrontmostOnly: Bool
    public var includeSymbolicHotKeys: Bool
    public var includeUserKeyEquivalents: Bool
    public var includeServices: Bool
    public var includeInputSources: Bool
    public var includeEventTaps: Bool
    public var includeConfigAdapters: Bool
    public var includeGenericPreferences: Bool
    public var includeBinaryTriage: Bool
    public var includeProbe: Bool
    public var probeBreadth: ProbeBreadth

    public init(
        includeMenus: Bool = true,
        menusForFrontmostOnly: Bool = false,
        includeSymbolicHotKeys: Bool = true,
        includeUserKeyEquivalents: Bool = true,
        includeServices: Bool = true,
        includeInputSources: Bool = true,
        includeEventTaps: Bool = true,
        includeConfigAdapters: Bool = true,
        includeGenericPreferences: Bool = true,
        includeBinaryTriage: Bool = false,
        includeProbe: Bool = true,
        probeBreadth: ProbeBreadth = .common
    ) {
        self.includeMenus = includeMenus
        self.menusForFrontmostOnly = menusForFrontmostOnly
        self.includeSymbolicHotKeys = includeSymbolicHotKeys
        self.includeUserKeyEquivalents = includeUserKeyEquivalents
        self.includeServices = includeServices
        self.includeInputSources = includeInputSources
        self.includeEventTaps = includeEventTaps
        self.includeConfigAdapters = includeConfigAdapters
        self.includeGenericPreferences = includeGenericPreferences
        self.includeBinaryTriage = includeBinaryTriage
        self.includeProbe = includeProbe
        self.probeBreadth = probeBreadth
    }

    public static let `default` = ScanOptions()

    /// Everything that needs no TCC grant, for a first run before onboarding.
    public static let unprivileged = ScanOptions(
        includeMenus: false,
        includeUserKeyEquivalents: false,
        includeGenericPreferences: false
    )
}

/// The world as it was when a scan started.
public struct ScanContext: @unchecked Sendable {
    public var runningApps: [RunningApp]
    public var installedApps: [InstalledApp]
    public var options: ScanOptions
    public var startedAt: Date

    public init(
        runningApps: [RunningApp],
        installedApps: [InstalledApp],
        options: ScanOptions,
        startedAt: Date = Date()
    ) {
        self.runningApps = runningApps
        self.installedApps = installedApps
        self.options = options
        self.startedAt = startedAt
    }

    public var frontmostApp: RunningApp? {
        runningApps.first { $0.isActive }
    }

    /// Snapshots the current system state.
    @MainActor
    public static func capture(options: ScanOptions = .default) -> ScanContext {
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard app.processIdentifier > 0 else { return nil }
            let bundle = app.bundleURL.flatMap { Bundle(url: $0) }
            let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
            let build = bundle?.infoDictionary?["CFBundleVersion"] as? String
            return RunningApp(
                pid: app.processIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                bundleID: app.bundleIdentifier,
                bundlePath: app.bundleURL?.path,
                version: [version, build].compactMap { $0 }.joined(separator: "-"),
                isActive: app.isActive,
                hasMenuBar: app.activationPolicy == .regular
            )
        }
        return ScanContext(
            runningApps: running,
            installedApps: options.includeBinaryTriage || options.includeGenericPreferences
                ? InstalledAppScanner.enumerate()
                : [],
            options: options
        )
    }
}

/// Finds installed application bundles in the usual places.
public enum InstalledAppScanner {

    public static let searchPaths: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    public static func enumerate() -> [InstalledApp] {
        var results: [InstalledApp] = []
        var seenPaths = Set<String>()
        let fm = FileManager.default

        for directory in searchPaths {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = directory + "/" + entry
                guard seenPaths.insert(path).inserted else { continue }
                guard let bundle = Bundle(path: path) else { continue }
                let info = bundle.infoDictionary
                results.append(
                    InstalledApp(
                        name: (info?["CFBundleName"] as? String)
                            ?? (entry as NSString).deletingPathExtension,
                        bundleID: bundle.bundleIdentifier,
                        bundlePath: path,
                        executablePath: bundle.executableURL?.path,
                        version: info?["CFBundleShortVersionString"] as? String
                    )
                )
            }
        }
        return results
    }
}
