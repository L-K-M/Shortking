import Foundation

/// Services with a key equivalent — a frequently forgotten source of ⌘⇧ collisions.
///
/// `~/Library/Preferences/pbs.plist` → `NSServicesStatus`, keyed by a string of the
/// form `"(bundleID, service name)"`, each value optionally carrying a
/// `key_equivalent`.
public final class ServicesScanner: ClaimSource {

    public let identifier = "services"
    public let displayName = "Services"
    public let requirement: ScanRequirement = .fileAccess

    public init() {}

    public func isEnabled(for options: ScanOptions) -> Bool {
        options.includeServices
    }

    public func scan(context: ScanContext) async throws -> [Claim] {
        let path = NSHomeDirectory() + "/Library/Preferences/pbs.plist"
        guard let root = NSDictionary(contentsOfFile: path) as? [String: Any],
              let status = root["NSServicesStatus"] as? [String: Any] else {
            return []
        }

        var claims: [Claim] = []
        for (rawKey, rawValue) in status {
            guard let entry = rawValue as? [String: Any] else { continue }
            guard let equivalent = entry["key_equivalent"] as? String, !equivalent.isEmpty else {
                continue
            }

            let (bundleID, serviceName) = Self.parseServiceKey(rawKey)
            let (modifiers, key) = Modifiers.parseKeyEquivalent(equivalent)
            guard let combo = KeyCombo(token: key, modifiers: modifiers), !combo.isBare else {
                continue
            }

            // `enabled_services_menu` absent means the service is on by default.
            let enabled = (entry["enabled_services_menu"] as? Bool) ?? true

            let ownerName = context.installedApps.first { $0.bundleID == bundleID }?.name
                ?? bundleID.map(Owner.displayName(forBundleID:))
                ?? "Services"

            claims.append(
                Claim(
                    combo: combo,
                    layer: .service,
                    status: .known,
                    owner: Owner(name: ownerName, bundleID: bundleID, kind: .service),
                    label: serviceName,
                    enabled: enabled,
                    evidence: [
                        Evidence(
                            kind: .servicesPlist,
                            summary: "Service “\(serviceName)”",
                            detail: [
                                "path": path,
                                "serviceKey": rawKey,
                                "keyEquivalent": equivalent,
                            ]
                        )
                    ]
                )
            )
        }
        return claims
    }

    /// Splits `"(com.apple.Finder, Open)"` into its bundle ID and service name.
    static func parseServiceKey(_ raw: String) -> (bundleID: String?, name: String) {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        let parts = trimmed.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return (nil, trimmed) }

        // Some entries carry a suffix on the identifier, e.g.
        // `(org.pqrs.Karabiner-Elements(null), Save Current Form)`. Everything from
        // the first bracket on is noise, and leaving it in leaks "(null" into the
        // owner name shown in the conflict list.
        var bundleID = parts[0]
        if let bracket = bundleID.firstIndex(of: "(") {
            bundleID = String(bundleID[bundleID.startIndex..<bracket])
        }
        bundleID = bundleID.trimmingCharacters(in: .whitespaces)

        return (bundleID.isEmpty ? nil : bundleID, parts[1])
    }
}

/// Input source switching bindings.
///
/// Also mirrored in symbolic hotkeys 59–61; we read the HIToolbox domain as well
/// because the two can disagree, and because it names the input sources involved.
public final class InputSourceScanner: ClaimSource {

    public let identifier = "input-sources"
    public let displayName = "Input sources"
    public let requirement: ScanRequirement = .fileAccess

    public init() {}

    public func isEnabled(for options: ScanOptions) -> Bool {
        options.includeInputSources
    }

    public func scan(context: ScanContext) async throws -> [Claim] {
        let path = NSHomeDirectory() + "/Library/Preferences/com.apple.HIToolbox.plist"
        guard let root = NSDictionary(contentsOfFile: path) as? [String: Any] else { return [] }

        var claims: [Claim] = []

        // The enabled input sources themselves are not shortcuts, but the count
        // matters: switching bindings only fire when more than one source exists,
        // which is a real and confusing "my shortcut does nothing" cause.
        let sources = (root["AppleEnabledInputSources"] as? [[String: Any]]) ?? []
        let sourceNames = sources.compactMap { $0["InputSourceKind"] as? String }

        guard sources.count > 1 else { return [] }

        // Symbolic hotkeys 60/61 carry the actual bindings; we attach the names
        // here so the inventory can say *what* it switches between.
        for id in Int32(60)...Int32(61) {
            guard let value = SkyLight.shared.symbolicHotKey(id: id) else { continue }
            guard value.virtualKeyCode != 0xFFFF else { continue }
            let combo = KeyCombo(
                keyCode: value.virtualKeyCode,
                modifiers: Modifiers(cocoa: value.modifiers)
            )
            guard !combo.isBare else { continue }

            claims.append(
                Claim(
                    combo: combo,
                    layer: .inputSource,
                    status: .known,
                    owner: Owner(name: "Input Sources", bundleID: "com.apple.HIToolbox", kind: .inputMethod),
                    label: id == 60 ? "Select the previous input source" : "Select the next input source",
                    enabled: value.enabled,
                    evidence: [
                        Evidence(
                            kind: .inputSource,
                            summary: "\(sources.count) input sources enabled",
                            detail: [
                                "path": path,
                                "symbolicHotKeyID": "\(id)",
                                "inputSourceKinds": sourceNames.joined(separator: ", "),
                            ]
                        )
                    ]
                )
            )
        }

        return claims
    }
}
