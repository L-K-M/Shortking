import ApplicationServices
import Foundation

/// Reads the menu key equivalents of every running app via the Accessibility API.
///
/// This is the slow part of any scan, so results are cached per
/// `(bundleID, version)` — a cache key that invalidates itself when the app
/// updates. Menus are never expanded, only read: pressing them makes dynamic items
/// (Recent Files, Window lists) churn and would make the cache worthless.
///
/// Coverage caveat, surfaced honestly in the UI: this only sees *running* apps, and
/// Electron/Qt/Java hosts expose menus inconsistently.
public final class MenuBarScanner: ClaimSource {

    public let identifier = "menus"
    public let displayName = "Menu bar shortcuts"
    public let requirement: ScanRequirement = .accessibility

    /// How deep to recurse. Real menu bars are 3–4 deep; the bound exists so a
    /// pathological (or hostile) menu tree cannot spin the scan.
    private let maxDepth = 6

    /// Per-app item budget, for the same reason.
    private let maxItemsPerApp = 4_000

    private let cache: MenuCache

    public init(cache: MenuCache = MenuCache()) {
        self.cache = cache
    }

    public func isEnabled(for options: ScanOptions) -> Bool {
        options.includeMenus
    }

    public func scan(context: ScanContext) async throws -> [Claim] {
        guard AXBridge.isTrusted else {
            throw ScanError.missingPermission(.accessibility)
        }

        var targets = context.runningApps.filter(\.hasMenuBar)
        if context.options.menusForFrontmostOnly {
            targets = targets.filter(\.isActive)
        }

        var claims: [Claim] = []
        for app in targets {
            if Task.isCancelled { break }
            claims.append(contentsOf: claims(for: app))
        }
        return claims
    }

    private func claims(for app: RunningApp) -> [Claim] {
        let entries: [MenuEntry]
        if let cached = cache.entries(forKey: app.cacheKey) {
            entries = cached
        } else {
            entries = walk(app: app)
            cache.store(entries, forKey: app.cacheKey)
        }

        let owner = app.owner
        return entries.map { entry in
            Claim(
                combo: entry.combo,
                layer: .appMenu,
                status: .known,
                owner: owner,
                label: entry.title,
                enabled: entry.enabled,
                evidence: [
                    Evidence(
                        kind: .accessibilityMenu,
                        summary: entry.menuPath.joined(separator: " ▸ "),
                        detail: [
                            "bundleID": owner.bundleID ?? "—",
                            "menuPath": entry.menuPath.joined(separator: " ▸ "),
                        ]
                    )
                ]
            )
        }
    }

    private func walk(app: RunningApp) -> [MenuEntry] {
        let element = AXBridge.application(pid: pid_t(app.pid), timeout: 0.25)
        guard let menuBar = AXBridge.menuBar(of: element) else { return [] }

        var entries: [MenuEntry] = []
        var budget = maxItemsPerApp
        for child in AXBridge.children(menuBar) {
            recurse(element: child, path: [], depth: 0, entries: &entries, budget: &budget)
            if budget <= 0 { break }
        }
        return entries
    }

    private func recurse(
        element: AXUIElement,
        path: [String],
        depth: Int,
        entries: inout [MenuEntry],
        budget: inout Int
    ) {
        guard depth <= maxDepth, budget > 0 else { return }
        budget -= 1

        let title = AXBridge.title(of: element)
        let currentPath = title.map { path + [$0] } ?? path

        if let combo = AXBridge.shortcut(of: element), !combo.isBare {
            let enabled = AXBridge.int(element, AXBridge.MenuAttribute.enabled).map { $0 != 0 } ?? true
            entries.append(
                MenuEntry(
                    combo: combo,
                    title: title ?? currentPath.last ?? "Menu item",
                    menuPath: currentPath,
                    enabled: enabled
                )
            )
        }

        for child in AXBridge.children(element) {
            recurse(element: child, path: currentPath, depth: depth + 1, entries: &entries, budget: &budget)
            if budget <= 0 { return }
        }
    }
}

/// One menu item that carries a key equivalent.
public struct MenuEntry: Codable, Hashable, Sendable {
    public var combo: KeyCombo
    public var title: String
    public var menuPath: [String]
    public var enabled: Bool

    public init(combo: KeyCombo, title: String, menuPath: [String], enabled: Bool) {
        self.combo = combo
        self.title = title
        self.menuPath = menuPath
        self.enabled = enabled
    }
}

/// Menu results keyed by `(bundleID, version)` with a TTL.
public final class MenuCache: @unchecked Sendable {

    private struct Entry: Codable {
        var entries: [MenuEntry]
        var storedAt: Date
    }

    private var storage: [String: Entry] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval
    private let persistence: JSONStore<[String: Entry]>?

    public init(ttl: TimeInterval = 60 * 60 * 24, persistent: Bool = true) {
        self.ttl = ttl
        self.persistence = persistent ? JSONStore(filename: "menu-cache.json") : nil
        if let loaded = persistence?.load() {
            storage = loaded
        }
    }

    public func entries(forKey key: String) -> [MenuEntry]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < ttl else {
            storage[key] = nil
            return nil
        }
        return entry.entries
    }

    public func store(_ entries: [MenuEntry], forKey key: String) {
        lock.lock()
        storage[key] = Entry(entries: entries, storedAt: Date())
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
