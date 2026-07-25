import Foundation

/// User-assigned App Shortcuts — System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸
/// App Shortcuts.
///
/// These are written to `NSUserKeyEquivalents` in the *target app's* preference
/// domain (or `.GlobalPreferences` for "All Applications"). The on-disk location
/// differs for sandboxed apps, so we read through CFPreferences with the bundle ID
/// rather than guessing at paths.
public final class UserKeyEquivalentScanner: ClaimSource {

    public let identifier = "user-key-equivalents"
    public let displayName = "User-assigned App Shortcuts"
    public let requirement: ScanRequirement = .fileAccess

    private static let key = "NSUserKeyEquivalents" as CFString

    public init() {}

    public func isEnabled(for options: ScanOptions) -> Bool {
        options.includeUserKeyEquivalents
    }

    public func scan(context: ScanContext) async throws -> [Claim] {
        var claims: [Claim] = []

        // "All Applications" overrides — recorded once, against a single owner,
        // rather than duplicated across every app they happen to apply to.
        if let global = read(domain: kCFPreferencesAnyApplication) {
            claims.append(
                contentsOf: makeClaims(
                    from: global,
                    owner: Owner(name: "All Applications", bundleID: nil, kind: .system),
                    domain: ".GlobalPreferences"
                )
            )
        }

        // Per-app overrides. We look at every bundle ID we know about — running
        // apps plus installed ones — because an override can exist for an app that
        // is not running.
        var domains: [String: Owner] = [:]
        for app in context.runningApps {
            if let bundleID = app.bundleID { domains[bundleID] = app.owner }
        }
        for app in context.installedApps {
            if let bundleID = app.bundleID, domains[bundleID] == nil { domains[bundleID] = app.owner }
        }

        for (bundleID, owner) in domains {
            if Task.isCancelled { break }
            guard let values = read(domain: bundleID as CFString) else { continue }
            claims.append(contentsOf: makeClaims(from: values, owner: owner, domain: bundleID))
        }

        return claims
    }

    /// Reads `NSUserKeyEquivalents` from exactly one domain.
    ///
    /// **Not** `CFPreferencesCopyAppValue`, which is documented to fall back to the
    /// global domain when the key is absent from the application domain. Used here
    /// that meant a single "All Applications" shortcut was reported as a separate
    /// claim for every installed app on the machine — one shortcut turning into
    /// forty phantom claimants in the conflict list.
    private func read(domain: CFString) -> [String: String]? {
        let raw = CFPreferencesCopyValue(
            Self.key,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard let raw else { return nil }
        guard let dictionary = raw as? [String: String], !dictionary.isEmpty else { return nil }
        return dictionary
    }

    private func makeClaims(from values: [String: String], owner: Owner, domain: String) -> [Claim] {
        values.compactMap { menuTitle, equivalent in
            let (modifiers, key) = Modifiers.parseKeyEquivalent(equivalent)
            guard let combo = KeyCombo(token: key, modifiers: modifiers), !combo.isBare else {
                return nil
            }
            return Claim(
                combo: combo,
                layer: .appMenu,
                status: .known,
                owner: owner,
                label: menuTitle,
                evidence: [
                    Evidence(
                        kind: .userKeyEquivalent,
                        summary: "User shortcut for “\(menuTitle)” in \(domain)",
                        detail: [
                            "domain": domain,
                            "menuTitle": menuTitle,
                            "keyEquivalent": equivalent,
                        ]
                    )
                ]
            )
        }
    }
}
