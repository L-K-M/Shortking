import Foundation

/// Turns groups of claims into conflicts, with an explanation a human can act on.
///
/// The rule that decides everything: **lower layer wins**. A WindowServer hotkey
/// beats a menu equivalent because WindowServer matches before the event is
/// dispatched to any app at all. Karabiner beats everything because it rewrites the
/// event before macOS has finished making it.
public enum ConflictAnalyzer {

    public static func analyze(_ groups: [ComboGroup]) -> [ComboGroup] {
        groups.map { group in
            var updated = group
            updated.conflict = conflict(for: group)
            return updated
        }
    }

    public static func conflicts(in groups: [ComboGroup]) -> [Conflict] {
        groups.compactMap(\.conflict).sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.combo.displayString < rhs.combo.displayString
        }
    }

    // MARK: - Classification

    static func conflict(for group: ComboGroup) -> Conflict? {
        let active = group.claims.filter { $0.enabled && $0.isBinding }
        guard !active.isEmpty else { return nil }

        let globals = active.filter { $0.layer.isGlobal }
        let appLocals = active.filter { !$0.layer.isGlobal }

        // A single unattributed claim: somebody holds this and we cannot say who.
        // Reported as a first-class state, with the offer to find out.
        if active.count == 1, let only = active.first, only.status == .probedClaimed {
            return Conflict(
                combo: group.combo,
                kind: .unattributed,
                winner: only,
                losers: [],
                explanation: "\(group.combo.displayString) is claimed at the WindowServer layer by "
                    + "an application Shortking cannot name. Nothing in any config file, menu bar "
                    + "or preference domain accounts for it.",
                suggestion: "Run Detective Mode to identify the owner — live capture takes one "
                    + "key press, or Shortking can narrow it down across app restarts.",
                severity: .low
            )
        }

        guard active.count > 1 else { return nil }

        // Two or more claims at the *same* global layer: a genuine fight, and which
        // one wins is not predictable from the outside.
        if globals.count > 1 {
            let lowestLayer = globals.map(\.layer).min()!
            let atLowest = globals.filter { $0.layer == lowestLayer }

            if atLowest.count > 1 {
                // Described per claim rather than per owner: macOS routinely binds
                // one combination to several symbolic hotkeys, and "macOS and macOS
                // all claim ⌃↓" tells the user nothing about which two functions
                // are fighting.
                let described = describeAll(atLowest)

                // macOS ships several symbolic hotkeys bound to the same key by
                // default. Those collisions are real, but they are Apple's and there
                // are dozens of them — ranked alongside "two apps are fighting over
                // ⇧⌘P" they bury the conflicts the user can actually act on.
                let isSystemDefault = lowestLayer == .symbolic
                    && atLowest.allSatisfy { $0.owner?.kind == .system }

                return Conflict(
                    combo: group.combo,
                    kind: .definite,
                    winner: nil,
                    losers: atLowest,
                    explanation: "\(group.combo.displayString) is claimed \(atLowest.count) times "
                        + "at the \(lowestLayer.displayName) layer — \(list(described)). Which one "
                        + "wins depends on registration order, so the behaviour can change between "
                        + "reboots."
                        + (isSystemDefault
                            ? " These are all macOS's own shortcuts, so this is how the system "
                                + "shipped rather than something another app did."
                            : ""),
                    suggestion: isSystemDefault
                        ? "Change or turn off all but one in System Settings ▸ Keyboard ▸ "
                            + "Keyboard Shortcuts."
                        : "Rebind all but one of them.",
                    severity: isSystemDefault ? .low : .high
                )
            }

            // Different global layers: the lower one wins outright and the others
            // never fire at all.
            let winner = atLowest[0]
            let shadowed = globals.filter { $0.id != winner.id }
            return Conflict(
                combo: group.combo,
                kind: .shadowed,
                winner: winner,
                losers: shadowed + appLocals,
                explanation: shadowExplanation(combo: group.combo, winner: winner, losers: shadowed),
                suggestion: "Rebind \(names(shadowed)) or disable \(winner.ownerName)'s shortcut.",
                severity: .medium
            )
        }

        // Exactly one global claim plus app-local menu equivalents: the global wins,
        // but only while those apps are frontmost does anyone notice.
        if globals.count == 1, !appLocals.isEmpty {
            let winner = globals[0]
            return Conflict(
                combo: group.combo,
                kind: .contextual,
                winner: winner,
                losers: appLocals,
                explanation: "\(winner.ownerName) holds \(group.combo.displayString) at the "
                    + "\(winner.layer.displayName) layer, which matches before any app sees the key. "
                    + "\(names(appLocals)) will never receive it"
                    + (appLocals.count == 1 ? " even when it is frontmost." : " even when frontmost."),
                suggestion: "Rebind \(winner.ownerName)'s shortcut if you need "
                    + "\(names(appLocals)) to keep working.",
                severity: .medium
            )
        }

        // Several app-local claims in *different* apps is not a conflict at all —
        // ⌘S means Save everywhere and that is correct. Only two claims inside the
        // same app are a real problem.
        if globals.isEmpty, appLocals.count > 1 {
            var byOwner: [String: [Claim]] = [:]
            for claim in appLocals {
                byOwner[claim.owner?.identity ?? "unknown", default: []].append(claim)
            }
            guard let colliding = byOwner.values.first(where: { $0.count > 1 }) else { return nil }

            return Conflict(
                combo: group.combo,
                kind: .definite,
                winner: nil,
                losers: colliding,
                explanation: "\(colliding[0].ownerName) has \(colliding.count) menu items bound to "
                    + "\(group.combo.displayString): \(labels(colliding)). Only the first one the "
                    + "responder chain finds will fire.",
                suggestion: "Rebind one of them in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ "
                    + "App Shortcuts.",
                severity: .medium
            )
        }

        return nil
    }

    private static func shadowExplanation(combo: KeyCombo, winner: Claim, losers: [Claim]) -> String {
        let base = "\(winner.ownerName) holds \(combo.displayString) at the "
            + "\(winner.layer.displayName) layer. "

        guard let lowestLoser = losers.min(by: { $0.layer < $1.layer }) else { return base }

        let described = describeAll(losers)
        let singular = described.count == 1
        return base + "\(winner.layer.explanation) "
            + "\(list(described)) \(singular ? "claims" : "claim") it at the "
            + "\(lowestLoser.layer.displayName) layer or below, so "
            + "\(singular ? "it never fires" : "they never fire")."
    }

    /// Distinct owner names, in stable order.
    private static func names(_ claims: [Claim]) -> String {
        var seen = Set<String>()
        var unique: [String] = []
        for claim in claims where seen.insert(claim.ownerName).inserted {
            unique.append(claim.ownerName)
        }
        return list(unique)
    }

    /// One claim as `Owner “Label”`, or just the owner when it has no label.
    static func describe(_ claim: Claim) -> String {
        guard let label = claim.label, !label.isEmpty else { return claim.ownerName }
        return "\(claim.ownerName) “\(label)”"
    }

    /// Distinct claim descriptions, preserving order.
    static func describeAll(_ claims: [Claim]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for claim in claims {
            let description = describe(claim)
            if seen.insert(description).inserted { out.append(description) }
        }
        return out
    }

    /// Joins with an Oxford-free "a, b and c".
    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0:  return "nothing"
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    private static func labels(_ claims: [Claim]) -> String {
        let unique = claims.compactMap(\.label)
        guard !unique.isEmpty else { return "several items" }
        return unique.map { "“\($0)”" }.joined(separator: ", ")
    }
}
