import Foundation

/// The best effort-to-coverage ratio in the whole tool.
///
/// Most apps that offer a global hotkey do not roll their own storage — they use
/// one of three widely adopted libraries, each with a recognisable signature in the
/// app's preference domain:
///
/// - **`KeyboardShortcuts`** (Sindre Sorhus) — key `KeyboardShortcuts_<name>`,
///   value a JSON string `{"carbonKeyCode":5,"carbonModifiers":768}`.
/// - **ShortcutRecorder** — value a dict with `keyCode` and `modifierFlags`.
/// - **MASShortcut** — value an `NSKeyedArchiver` blob whose `$objects` contain
///   `keyCode` and `modifierFlags`.
///
/// Scanning every preference domain for these three signatures yields hotkeys from
/// hundreds of apps nobody wrote an adapter for.
public final class GenericPreferenceScanner: ClaimSource {

    public let identifier = "generic-preferences"
    public let displayName = "App preference sniffing"
    public let requirement: ScanRequirement = .fileAccess

    /// Bound on how many domains we will open in one scan, so a machine with a
    /// pathological number of preference files still finishes.
    private let maxDomains = 1_500

    public init() {}

    public func isEnabled(for options: ScanOptions) -> Bool {
        options.includeGenericPreferences
    }

    public func scan(context: ScanContext) async throws -> [Claim] {
        var ownersByBundleID: [String: Owner] = [:]
        for app in context.runningApps {
            if let bundleID = app.bundleID { ownersByBundleID[bundleID] = app.owner }
        }
        for app in context.installedApps {
            if let bundleID = app.bundleID, ownersByBundleID[bundleID] == nil {
                ownersByBundleID[bundleID] = app.owner
            }
        }

        var claims: [Claim] = []
        var examined = 0

        for path in Self.preferenceFiles() {
            if Task.isCancelled { break }
            examined += 1
            if examined > maxDomains { break }

            let bundleID = (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".plist", with: "")
            guard let root = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }

            let owner = ownersByBundleID[bundleID]
                ?? Owner(name: bundleID, bundleID: bundleID, kind: .application)

            for (key, value) in root {
                guard let found = Self.extract(key: key, value: value) else { continue }
                claims.append(
                    Claim(
                        combo: found.combo,
                        // Libraries of this kind register with WindowServer, which
                        // is why they work in full screen and why they turn up in
                        // the probe map.
                        layer: .windowServer,
                        status: .known,
                        owner: owner,
                        label: found.label,
                        evidence: [
                            Evidence(
                                kind: .genericPreference,
                                summary: "\(found.library) key “\(key)” in \(bundleID)",
                                detail: [
                                    "domain": bundleID,
                                    "path": path,
                                    "key": key,
                                    "library": found.library,
                                ]
                            )
                        ]
                    )
                )
            }
        }

        return claims
    }

    // MARK: - Domain enumeration

    static func preferenceFiles() -> [String] {
        let fm = FileManager.default
        var paths: [String] = []

        let global = NSHomeDirectory() + "/Library/Preferences"
        if let entries = try? fm.contentsOfDirectory(atPath: global) {
            paths.append(contentsOf: entries.filter { $0.hasSuffix(".plist") }.map { global + "/" + $0 })
        }

        // Sandboxed apps keep their preferences inside their container.
        let containers = NSHomeDirectory() + "/Library/Containers"
        if let bundles = try? fm.contentsOfDirectory(atPath: containers) {
            for bundle in bundles {
                let directory = "\(containers)/\(bundle)/Data/Library/Preferences"
                guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
                paths.append(
                    contentsOf: entries.filter { $0.hasSuffix(".plist") }.map { directory + "/" + $0 }
                )
            }
        }

        return paths
    }

    // MARK: - Signature matching

    struct Found {
        var combo: KeyCombo
        var label: String
        var library: String
    }

    static func extract(key: String, value: Any) -> Found? {
        if key.hasPrefix("KeyboardShortcuts_"), let string = value as? String {
            guard let combo = parseKeyboardShortcuts(json: string) else { return nil }
            let name = String(key.dropFirst("KeyboardShortcuts_".count))
            return Found(combo: combo, label: name, library: "KeyboardShortcuts")
        }

        if let dictionary = value as? [String: Any],
           let combo = parseShortcutRecorder(dictionary) {
            return Found(combo: combo, label: humanize(key), library: "ShortcutRecorder")
        }

        if let data = value as? Data, looksLikeShortcutKey(key),
           let combo = parseArchivedShortcut(data) {
            return Found(combo: combo, label: humanize(key), library: "MASShortcut")
        }

        return nil
    }

    /// `{"carbonKeyCode":5,"carbonModifiers":768}`
    static func parseKeyboardShortcuts(json: String) -> KeyCombo? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keyCode = (object["carbonKeyCode"] as? NSNumber)?.uint16Value,
              let carbonModifiers = (object["carbonModifiers"] as? NSNumber)?.uint32Value else {
            return nil
        }
        let combo = KeyCombo(keyCode: keyCode, modifiers: Modifiers(carbon: carbonModifiers))
        return combo.isBare ? nil : combo
    }

    /// `{ keyCode = 5; modifierFlags = 1179648; }`
    static func parseShortcutRecorder(_ dictionary: [String: Any]) -> KeyCombo? {
        guard let keyCode = (dictionary["keyCode"] as? NSNumber)?.uint16Value else { return nil }
        guard let flags = dictionary["modifierFlags"] as? NSNumber else { return nil }
        let combo = KeyCombo(
            keyCode: keyCode,
            modifiers: Modifiers(cocoa: flags.uint64Value)
        )
        return combo.isBare ? nil : combo
    }

    static func looksLikeShortcutKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return lowered.contains("shortcut") || lowered.contains("hotkey") || lowered.contains("hot_key")
    }

    /// Reads `keyCode` / `modifierFlags` out of an `NSKeyedArchiver` blob without
    /// unarchiving it.
    ///
    /// Unarchiving would require the app's own classes, which we do not have. The
    /// archive is just a plist, though, so we walk `$objects` and take the first
    /// dictionary that carries both fields.
    static func parseArchivedShortcut(_ data: Data) -> KeyCombo? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else { return nil }
        guard let objects = plist["$objects"] as? [Any] else { return nil }

        for object in objects {
            guard let dictionary = object as? [String: Any] else { continue }
            guard let keyCode = (dictionary["keyCode"] as? NSNumber)?.uint16Value,
                  let flags = dictionary["modifierFlags"] as? NSNumber else { continue }
            let combo = KeyCombo(keyCode: keyCode, modifiers: Modifiers(cocoa: flags.uint64Value))
            if !combo.isBare { return combo }
        }
        return nil
    }

    /// `globalSearchHotKey` → `Global Search Hot Key`.
    static func humanize(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        for character in key {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character)
            } else if character == "_" || character == "-" {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return key }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }
}
