import Foundation

/// Folds claims from every source into one deduplicated set.
public enum ClaimMerger {

    /// Merges by ``Claim/identity``, preserving `firstSeen` and unioning evidence.
    public static func merge(_ claims: [Claim]) -> [Claim] {
        var byIdentity: [String: Claim] = [:]
        var order: [String] = []

        for claim in claims {
            let key = claim.identity
            if var existing = byIdentity[key] {
                existing.merge(claim)
                byIdentity[key] = existing
            } else {
                byIdentity[key] = claim
                order.append(key)
            }
        }

        return order.compactMap { byIdentity[$0] }
    }

    /// Carries `firstSeen` and accumulated evidence forward from the previous scan.
    ///
    /// Without this, every rescan would reset the age of every claim and the
    /// attribution ledger would never accumulate anything.
    public static func reconcile(new: [Claim], previous: [Claim]) -> [Claim] {
        var previousByIdentity: [String: Claim] = [:]
        for claim in previous { previousByIdentity[claim.identity] = claim }

        return new.map { claim in
            guard let old = previousByIdentity[claim.identity] else { return claim }
            var merged = claim
            merged.id = old.id
            merged.firstSeen = min(old.firstSeen, claim.firstSeen)
            // Keep historical evidence that this scan happened not to re-observe —
            // a config file that was temporarily unreadable should not erase what we
            // learned from it last week.
            var seen = Set(merged.evidence.map(\.factKey))
            for item in old.evidence where !seen.contains(item.factKey) {
                merged.evidence.append(item)
                seen.insert(item.factKey)
            }
            return merged
        }
    }

    /// Folds probe results into the claim set.
    ///
    /// A `claimed` probe result on a combination that already has a named
    /// WindowServer-level claim is not a second claim — it is corroboration, and
    /// attaching it that way is what keeps the "unknown owner" set honest. Only
    /// results with nobody to attribute them to become standalone `probedClaimed`
    /// claims.
    public static func applyProbeReport(_ report: ProbeReport, to claims: [Claim]) -> [Claim] {
        guard report.probingVerified else { return claims }

        var result = claims
        var indicesByCombo: [KeyCombo: [Int]] = [:]
        for (index, claim) in result.enumerated() where claim.isBinding {
            indicesByCombo[claim.combo, default: []].append(index)
        }

        for probeResult in report.claimed {
            let candidates = Self.registeringClaimIndices(
                on: probeResult.combo,
                in: result,
                indicesByCombo: indicesByCombo
            )

            let evidence = Evidence(
                kind: .probeExclusionFailure,
                summary: "Registration refused (\(probeResult.status))",
                detail: [
                    "status": "\(probeResult.status)",
                    "meaning": probeResult.status == CarbonHotKey.hotKeyExistsErr
                        ? "eventHotKeyExistsErr — this combination is held at the WindowServer layer"
                        : "unrecognised failure",
                ]
            )

            if candidates.isEmpty {
                result.append(
                    Claim(
                        combo: probeResult.combo,
                        layer: .windowServer,
                        status: .probedClaimed,
                        owner: nil,
                        evidence: [evidence]
                    )
                )
            } else {
                for index in candidates {
                    let key = evidence.factKey
                    if !result[index].evidence.contains(where: { $0.factKey == key }) {
                        result[index].evidence.append(evidence)
                    }
                }
            }
        }

        // Restricted results are not conflicts, but they *are* answers: "my ⌥⇧O
        // shortcut stopped working after I upgraded" is explained entirely by this.
        // So the refusal is attached to whatever already claims the combination —
        // the app believes it holds the shortcut, macOS refuses to give it — without
        // ever becoming a claim of its own, because nobody holds a restricted combo.
        for probeResult in report.restricted {
            let evidence = Evidence(
                kind: .probeExclusionFailure,
                summary: "Refused by the macOS Option-key restriction (\(probeResult.status))",
                detail: [
                    "status": "\(probeResult.status)",
                    "meaning": "Since macOS 15, shortcuts whose only modifiers are ⌥ or ⌥⇧ are "
                        + "refused system-wide as an anti-keylogging measure. No app can register "
                        + "this combination, so this is not a conflict — and rebinding the other "
                        + "claimant will not help.",
                ]
            )
            let key = evidence.factKey
            let candidates = Self.registeringClaimIndices(
                on: probeResult.combo,
                in: result,
                indicesByCombo: indicesByCombo
            )

            for index in candidates
            where !result[index].evidence.contains(where: { $0.factKey == key }) {
                result[index].evidence.append(evidence)
            }
        }

        return result
    }

    /// Claims on `combo` that could plausibly have caused — or been affected by — a
    /// registration outcome.
    ///
    /// Only layers that actually register with WindowServer qualify. A skhd binding
    /// at the session-tap layer registers nothing, so it can neither cause a refusal
    /// nor be explained by one, and must not absorb the evidence.
    private static func registeringClaimIndices(
        on combo: KeyCombo,
        in claims: [Claim],
        indicesByCombo: [KeyCombo: [Int]]
    ) -> [Int] {
        (indicesByCombo[combo] ?? []).filter { index in
            let layer = claims[index].layer
            return layer == .windowServer || layer == .symbolic
        }
    }

    /// Groups claims by combination, discarding capability records (which have no
    /// combination) and bare keys.
    public static func group(_ claims: [Claim]) -> [ComboGroup] {
        var byCombo: [KeyCombo: [Claim]] = [:]
        for claim in claims where claim.isBinding && !claim.combo.isBare {
            byCombo[claim.combo, default: []].append(claim)
        }

        return byCombo.map { combo, claims in
            ComboGroup(combo: combo, claims: claims.sorted { $0.layer < $1.layer })
        }
        .sorted { lhs, rhs in
            lhs.combo.displayString.localizedStandardCompare(rhs.combo.displayString) == .orderedAscending
        }
    }
}
