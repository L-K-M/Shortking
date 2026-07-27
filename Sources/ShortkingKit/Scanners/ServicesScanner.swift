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
/// These live in symbolic hotkeys 59–61, which ``SymbolicHotKeyScanner`` already
/// sweeps. This source exists to add what that sweep cannot see: how many input
/// sources are actually enabled, and which kinds — because a switching binding that
/// does nothing is usually a machine with only one source installed, and that is a
/// genuinely confusing "my shortcut is broken" cause.
///
/// **It must not mint claims of its own.** It used to, at `layer: .inputSource` with
/// owner `com.apple.HIToolbox`, while the symbolic scanner emitted the same
/// combination at `layer: .symbolic` with owner `com.apple.symbolichotkeys`.
/// Different owner identity means a different ``Claim/identity``, so the merger kept
/// both, and `ConflictAnalyzer` — seeing two global claims at two different layers —
/// reported a `shadowed` conflict: *Input Sources holds ⌃Space at the Symbolic
/// layer … Input Sources claims it at the Input source layer, so it never fires.*
/// Every Mac with a second keyboard layout got one or two fabricated conflicts.
///
/// So the claims built here are deliberately identical to the symbolic scanner's —
/// same layer, same owner, same label, via ``SymbolicHotKeyCatalog`` — and carry only
/// the extra evidence. `ClaimMerger` folds the two into one record with both pieces
/// of evidence attached, which is what was wanted in the first place.
public final class InputSourceScanner: ClaimSource {

    public let identifier = "input-sources"
    public let displayName = "Input sources"
    public let requirement: ScanRequirement = .fileAccess

    /// The symbolic hotkey IDs that switch input sources.
    static let switchingHotKeyIDs: [Int32] = [59, 60, 61]

    public init() {}

    public func isEnabled(for options: ScanOptions) -> Bool {
        options.includeInputSources
    }

    public func scan(context: ScanContext) async throws -> [Claim] {
        let path = NSHomeDirectory() + "/Library/Preferences/com.apple.HIToolbox.plist"
        guard let root = NSDictionary(contentsOfFile: path) as? [String: Any] else { return [] }

        // The enabled input sources themselves are not shortcuts, but the count
        // matters: switching bindings only fire when more than one source exists.
        let sources = (root["AppleEnabledInputSources"] as? [[String: Any]]) ?? []
        guard sources.count > 1 else { return [] }

        // `KeyboardLayout Name` is the human-facing one ("German", "ABC"); the older
        // `InputSourceKind` only ever says "Keyboard Layout", which named nothing.
        let sourceNames = sources.compactMap { entry -> String? in
            (entry["KeyboardLayout Name"] as? String) ?? (entry["InputSourceKind"] as? String)
        }

        var claims: [Claim] = []
        for id in Self.switchingHotKeyIDs {
            guard let value = SkyLight.shared.symbolicHotKey(id: id) else { continue }
            guard value.virtualKeyCode != 0xFFFF else { continue }
            let combo = KeyCombo(
                keyCode: value.virtualKeyCode,
                modifiers: Modifiers(cocoa: value.modifiers)
            )
            guard !combo.isBare else { continue }

            claims.append(
                Self.enrichment(
                    id: id,
                    combo: combo,
                    enabled: value.enabled,
                    sourceCount: sources.count,
                    sourceNames: sourceNames,
                    path: path
                )
            )
        }

        return claims
    }

    /// A claim shaped to merge into the symbolic scanner's, carrying the input-source
    /// names as extra evidence.
    ///
    /// Layer, owner and label all come from ``SymbolicHotKeyCatalog`` so that this
    /// and ``SymbolicHotKeyScanner`` produce the same ``Claim/identity``. If they
    /// ever diverge, one shortcut becomes two claimants and the analyzer reports a
    /// conflict that does not exist — see the type documentation.
    static func enrichment(
        id: Int32,
        combo: KeyCombo,
        enabled: Bool,
        sourceCount: Int,
        sourceNames: [String],
        path: String
    ) -> Claim {
        Claim(
            combo: combo,
            layer: .symbolic,
            status: .known,
            owner: SymbolicHotKeyCatalog.owner(for: id),
            label: SymbolicHotKeyCatalog.label(for: id),
            enabled: enabled,
            evidence: [
                Evidence(
                    kind: .inputSource,
                    summary: sourceCount == 1
                        ? "1 input source enabled"
                        : "\(sourceCount) input sources enabled",
                    detail: [
                        "path": path,
                        "symbolicHotKeyID": "\(id)",
                        "inputSources": sourceNames.joined(separator: ", "),
                    ]
                )
            ]
        )
    }
}
