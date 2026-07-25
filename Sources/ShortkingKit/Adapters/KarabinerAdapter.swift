import Foundation

/// Karabiner-Elements — `~/.config/karabiner/karabiner.json`.
///
/// Karabiner sits at layer 0: it remaps keys in a virtual HID driver *before* the
/// event exists in its final form, so it beats every other claimant on the machine.
/// When a key never reaches any app at all, this is usually why.
public final class KarabinerAdapter: ConfigAdapter {

    public let identifier = "karabiner"
    public let displayName = "Karabiner-Elements"
    public let layer: ClaimLayer = .virtualHID
    public let ownerName = "Karabiner-Elements"
    public let ownerBundleID: String? = "org.pqrs.Karabiner-Elements.Settings"

    public init() {}

    public func detectedPaths() -> [String] {
        existing([Self.home(".config/karabiner/karabiner.json")])
    }

    public func parse(path: String) throws -> [ParsedBinding] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ScanError.parseFailure(path: path, reason: "unreadable")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScanError.parseFailure(path: path, reason: "not a JSON object")
        }
        guard let profiles = root["profiles"] as? [[String: Any]] else { return [] }

        var bindings: [ParsedBinding] = []

        for profile in profiles {
            let profileName = (profile["name"] as? String) ?? "Profile"
            // Only the selected profile is live; the others are inert and reporting
            // them as claims would be a lie.
            let selected = (profile["selected"] as? Bool) ?? false
            guard selected else { continue }

            bindings.append(contentsOf: parseSimpleModifications(profile, profileName: profileName))
            bindings.append(contentsOf: parseComplexModifications(profile, profileName: profileName))
        }

        return bindings
    }

    private func parseSimpleModifications(
        _ profile: [String: Any],
        profileName: String
    ) -> [ParsedBinding] {
        guard let simple = profile["simple_modifications"] as? [[String: Any]] else { return [] }

        return simple.compactMap { entry -> ParsedBinding? in
            guard let from = entry["from"] as? [String: Any],
                  let combo = Self.combo(fromDescriptor: from) else { return nil }

            let toDescription = (entry["to"] as? [[String: Any]])?
                .compactMap { $0["key_code"] as? String }
                .joined(separator: " ")

            return ParsedBinding(
                combo: combo,
                label: toDescription.map { "Remapped to \($0)" } ?? "Remapped",
                detail: ["profile": profileName, "kind": "simple_modification"]
            )
        }
    }

    private func parseComplexModifications(
        _ profile: [String: Any],
        profileName: String
    ) -> [ParsedBinding] {
        guard let complex = profile["complex_modifications"] as? [String: Any],
              let rules = complex["rules"] as? [[String: Any]] else { return [] }

        var bindings: [ParsedBinding] = []

        for rule in rules {
            let ruleName = (rule["description"] as? String) ?? "Complex modification"
            guard let manipulators = rule["manipulators"] as? [[String: Any]] else { continue }

            for manipulator in manipulators {
                guard let from = manipulator["from"] as? [String: Any],
                      let combo = Self.combo(fromDescriptor: from) else { continue }
                bindings.append(
                    ParsedBinding(
                        combo: combo,
                        label: ruleName,
                        detail: ["profile": profileName, "kind": "complex_modification"]
                    )
                )
            }
        }

        return bindings
    }

    /// Builds a combo from Karabiner's `from` descriptor.
    ///
    /// Only `mandatory` modifiers are part of the trigger — `optional` modifiers
    /// (commonly `any`) merely permit extra keys to be held, and treating them as
    /// part of the combination would invent bindings that do not exist.
    static func combo(fromDescriptor descriptor: [String: Any]) -> KeyCombo? {
        guard let keyCode = descriptor["key_code"] as? String else { return nil }

        var modifiers: Modifiers = []
        if let modifierSpec = descriptor["modifiers"] as? [String: Any],
           let mandatory = modifierSpec["mandatory"] as? [String] {
            modifiers = Modifiers.parseTokens(mandatory)
        }

        return KeyCombo(token: keyCode, modifiers: modifiers)
    }
}
