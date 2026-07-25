import Foundation

/// Static binary triage: which installed apps can even claim a global hotkey?
///
/// `nm -u` on each app's main executable, looking for the three symbols that make a
/// process capable of taking a keystroke. This narrows ~300 installed apps to the
/// ~20 worth investigating, and — unlike everything else in the inventory — it works
/// on apps that are not running.
///
/// The output is `capability` claims only. A symbol import proves a process *can*
/// register a hotkey; it says nothing about which one, and the UI never pretends
/// otherwise.
public final class BinaryTriage: ClaimSource {

    public let identifier = "binary-triage"
    public let displayName = "Installed app capability"
    public let requirement: ScanRequirement = .fileAccess

    /// The symbols that matter, and what each one implies.
    public static let interestingSymbols: [(symbol: String, meaning: String, layer: ClaimLayer)] = [
        ("RegisterEventHotKey", "Can register a WindowServer hotkey", .windowServer),
        ("CGEventTapCreate", "Can install an event tap", .sessionTap),
        ("CGEventTapCreateForPid", "Can install a per-process event tap", .sessionTap),
        ("CGSSetHotKeyWithExclusion", "Registers hotkeys via the private CGS path", .windowServer),
        ("SLSSetHotKeyWithExclusion", "Registers hotkeys via the private SkyLight path", .windowServer),
    ]

    private let cache: TriageCache

    public init(cache: TriageCache = TriageCache()) {
        self.cache = cache
    }

    public func isEnabled(for options: ScanOptions) -> Bool {
        options.includeBinaryTriage
    }

    public func scan(context: ScanContext) async throws -> [Claim] {
        var claims: [Claim] = []

        for app in context.installedApps {
            if Task.isCancelled { break }
            guard let executable = app.executablePath else { continue }
            guard let found = symbols(inExecutable: executable), !found.isEmpty else { continue }

            let layer = found.compactMap { symbol in
                Self.interestingSymbols.first { $0.symbol == symbol }?.layer
            }.min() ?? .windowServer

            let meanings = found.compactMap { symbol in
                Self.interestingSymbols.first { $0.symbol == symbol }?.meaning
            }

            claims.append(
                Claim(
                    combo: KeyCombo(keyCode: nil, character: nil, modifiers: []),
                    layer: layer,
                    status: .capability,
                    owner: app.owner,
                    label: meanings.first ?? "Can claim keyboard shortcuts",
                    evidence: [
                        Evidence(
                            kind: .staticBinarySymbol,
                            summary: found.joined(separator: ", "),
                            detail: [
                                "executable": executable,
                                "symbols": found.joined(separator: ", "),
                            ]
                        )
                    ]
                )
            )
        }

        return claims
    }

    /// Undefined symbols of interest imported by an executable, cached by
    /// `(path, size, mtime)` so an unchanged binary is scanned once ever.
    func symbols(inExecutable path: String) -> [String]? {
        guard let fingerprint = TriageCache.fingerprint(path: path) else { return nil }
        if let cached = cache.symbols(forFingerprint: fingerprint) { return cached }

        guard let output = Shell.run("/usr/bin/nm", arguments: ["-u", path], timeout: 15) else {
            return nil
        }

        var found: [String] = []
        for (symbol, _, _) in Self.interestingSymbols where output.contains(symbol) {
            found.append(symbol)
        }
        cache.store(found, forFingerprint: fingerprint)
        return found
    }
}

/// `nm` results keyed by path, size and modification time.
public final class TriageCache: @unchecked Sendable {

    private var storage: [String: [String]] = [:]
    private let lock = NSLock()
    private let persistence: JSONStore<[String: [String]]>?

    public init(persistent: Bool = true) {
        self.persistence = persistent ? JSONStore(filename: "triage-cache.json") : nil
        if let loaded = persistence?.load() { storage = loaded }
    }

    public static func fingerprint(path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(size)|\(Int(modified))"
    }

    public func symbols(forFingerprint fingerprint: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return storage[fingerprint]
    }

    public func store(_ symbols: [String], forFingerprint fingerprint: String) {
        lock.lock()
        storage[fingerprint] = symbols
        let snapshot = storage
        lock.unlock()
        persistence?.save(snapshot)
    }

    public func clear() {
        lock.lock()
        storage = [:]
        lock.unlock()
        persistence?.save([:])
    }
}
