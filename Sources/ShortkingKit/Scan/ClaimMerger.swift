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
            let candidates = (indicesByCombo[probeResult.combo] ?? []).filter { index in
                // Only layers that actually register with WindowServer can cause a
                // registration to be refused. A skhd binding at the session-tap
                // layer does not, so it must not absorb this evidence.
                let layer = result[index].layer
                return layer == .windowServer || layer == .symbolic
            }

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

        // Restricted results are not conflicts, but they *are* answers: a shortcut
        // that stopped working after the upgrade is explained by this, so it is
        // recorded against the combination without ever becoming a claim.
        return result
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
