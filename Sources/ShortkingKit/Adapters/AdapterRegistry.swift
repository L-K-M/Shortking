import Foundation

/// One binding read out of a third-party config file.
public struct ParsedBinding: Hashable, Sendable {
    public var combo: KeyCombo
    public var label: String
    public var enabled: Bool
    /// 1-based line number, when the format has meaningful lines.
    public var line: Int?
    /// Extra facts worth showing in the evidence trail.
    public var detail: [String: String]

    public init(
        combo: KeyCombo,
        label: String,
        enabled: Bool = true,
        line: Int? = nil,
        detail: [String: String] = [:]
    ) {
        self.combo = combo
        self.label = label
        self.enabled = enabled
        self.line = line
        self.detail = detail
    }
}

/// A parser for one tool's configuration format.
///
/// Adapters are deliberately small and independent: the long tail of real-world
/// conflicts lives in third-party configs, so this is a filter-list model where a
/// new adapter is a pull request rather than a release.
public protocol ConfigAdapter: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    /// The layer this tool claims at — Karabiner remaps below everything, skhd taps
    /// the session, VS Code registers with WindowServer.
    var layer: ClaimLayer { get }
    var ownerName: String { get }
    var ownerBundleID: String? { get }
    /// Config files that exist on this machine.
    func detectedPaths() -> [String]
    func parse(path: String) throws -> [ParsedBinding]
}

public extension ConfigAdapter {
    var owner: Owner {
        Owner(name: ownerName, bundleID: ownerBundleID, kind: .configTool)
    }

    /// Filters a candidate list down to the paths that actually exist.
    func existing(_ candidates: [String]) -> [String] {
        candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func home(_ suffix: String) -> String {
        NSHomeDirectory() + "/" + suffix
    }
}

/// Runs every enabled config adapter.
public final class AdapterRegistry: ClaimSource {

    public let identifier = "config-adapters"
    public let displayName = "Third-party configs"
    public let requirement: ScanRequirement = .fileAccess

    public let adapters: [ConfigAdapter]

    /// Adapters the user has switched off, by identifier.
    public var disabled: Set<String> = []

    public init(adapters: [ConfigAdapter] = AdapterRegistry.defaultAdapters()) {
        self.adapters = adapters
    }

    public static func defaultAdapters() -> [ConfigAdapter] {
        [
            KarabinerAdapter(),
            SkhdAdapter(),
            HammerspoonAdapter(),
            VSCodeAdapter(),
            JetBrainsAdapter(),
        ]
    }

    public func isEnabled(for options: ScanOptions) -> Bool {
        options.includeConfigAdapters
    }

    public func scan(context: ScanContext) async throws -> [Claim] {
        var claims: [Claim] = []

        for adapter in adapters where !disabled.contains(adapter.identifier) {
            if Task.isCancelled { break }
            for path in adapter.detectedPaths() {
                do {
                    let bindings = try adapter.parse(path: path)
                    claims.append(contentsOf: bindings.map { binding in
                        makeClaim(binding: binding, adapter: adapter, path: path)
                    })
                } catch {
                    // A malformed config is the user's problem to fix, not a reason
                    // to fail the scan. Log it and move on.
                    Log.scan.warning(
                        "Adapter \(adapter.identifier) failed on \(path): \(error.localizedDescription)"
                    )
                }
            }
        }

        return claims
    }

    private func makeClaim(binding: ParsedBinding, adapter: ConfigAdapter, path: String) -> Claim {
        var detail = binding.detail
        detail["path"] = path
        detail["adapter"] = adapter.identifier
        if let line = binding.line { detail["line"] = "\(line)" }

        let location = binding.line.map { "\(abbreviate(path)) line \($0)" } ?? abbreviate(path)

        return Claim(
            combo: binding.combo,
            layer: adapter.layer,
            status: .known,
            owner: adapter.owner,
            label: binding.label,
            enabled: binding.enabled,
            evidence: [
                Evidence(kind: .configFile, summary: location, detail: detail)
            ]
        )
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Adapter status for the Settings screen: which tools are installed and how
    /// many bindings each contributes.
    public struct AdapterStatus: Identifiable, Sendable {
        public var id: String
        public var displayName: String
        public var paths: [String]
        public var enabled: Bool

        public var isDetected: Bool { !paths.isEmpty }
    }

    public func statuses() -> [AdapterStatus] {
        adapters.map { adapter in
            AdapterStatus(
                id: adapter.identifier,
                displayName: adapter.displayName,
                paths: adapter.detectedPaths(),
                enabled: !disabled.contains(adapter.identifier)
            )
        }
    }
}
