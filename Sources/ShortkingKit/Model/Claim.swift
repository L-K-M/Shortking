import Foundation

/// One party's claim on one key combination, at one layer.
public struct Claim: Codable, Hashable, Sendable, Identifiable {

    public var id: UUID
    public var combo: KeyCombo
    public var layer: ClaimLayer
    public var status: ClaimStatus
    /// `nil` means claimed but unattributed — a first-class state, not missing data.
    public var owner: Owner?
    /// What the shortcut does: `"Search Snippets"`, `"Go to Folder…"`.
    public var label: String?
    public var enabled: Bool
    public var evidence: [Evidence]
    /// `1.0` = read directly. Anything lower is an inference and is rendered as one.
    public var confidence: Double
    public var firstSeen: Date
    public var lastConfirmed: Date

    public init(
        id: UUID = UUID(),
        combo: KeyCombo,
        layer: ClaimLayer,
        status: ClaimStatus,
        owner: Owner? = nil,
        label: String? = nil,
        enabled: Bool = true,
        evidence: [Evidence] = [],
        confidence: Double? = nil,
        firstSeen: Date = Date(),
        lastConfirmed: Date = Date()
    ) {
        self.id = id
        self.combo = combo
        self.layer = layer
        self.status = status
        self.owner = owner
        self.label = label
        self.enabled = enabled
        self.evidence = evidence
        self.confidence = confidence ?? status.baselineConfidence
        self.firstSeen = firstSeen
        self.lastConfirmed = lastConfirmed
    }

    /// Stable identity across scans.
    ///
    /// This is what lets a rescan *update* a record — refreshing `lastConfirmed`,
    /// merging new evidence — instead of duplicating it, which is in turn what lets
    /// differential confidence accumulate across sessions.
    public var identity: String {
        let ownerPart = owner?.identity ?? "unattributed"
        let labelPart = label ?? ""
        return "\(layer.rawValue)|\(ownerPart)|\(combo.groupingKey)|\(labelPart)"
    }

    public var ownerName: String {
        owner?.name ?? "Unknown owner"
    }

    /// Free-text search surface for the inventory search field.
    public var searchTokens: [String] {
        var tokens = combo.searchTokens
        if let owner {
            tokens.append(owner.name.lowercased())
            if let bundleID = owner.bundleID { tokens.append(bundleID.lowercased()) }
        }
        if let label { tokens.append(label.lowercased()) }
        tokens.append(layer.displayName.lowercased())
        tokens.append(status.displayName.lowercased())
        return tokens
    }

    /// Folds another observation of the same claim into this one.
    ///
    /// Keeps the earliest `firstSeen`, the latest `lastConfirmed`, the highest
    /// confidence, and the union of evidence deduplicated by fact.
    public mutating func merge(_ other: Claim) {
        firstSeen = min(firstSeen, other.firstSeen)
        lastConfirmed = max(lastConfirmed, other.lastConfirmed)
        confidence = max(confidence, other.confidence)

        // A direct read always outranks an inference about the same claim.
        if other.status == .known && status != .known {
            status = .known
        }
        if label == nil { label = other.label }
        if owner == nil { owner = other.owner }
        if combo.keyCode == nil { combo.keyCode = other.combo.keyCode }
        if combo.character == nil { combo.character = other.combo.character }
        // Disabled anywhere means disabled: a source that can see the enabled flag
        // is more informative than one that assumes true.
        enabled = enabled && other.enabled

        var seen = Set(evidence.map(\.factKey))
        for item in other.evidence where !seen.contains(item.factKey) {
            evidence.append(item)
            seen.insert(item.factKey)
        }
    }

    /// True when this claim is a real binding rather than a mere capability.
    public var isBinding: Bool {
        status != .capability
    }
}

/// All claims on one key combination, plus the resolved outcome.
public struct ComboGroup: Identifiable, Sendable {
    public var combo: KeyCombo
    public var claims: [Claim]
    public var conflict: Conflict?

    public var id: String { combo.groupingKey }

    public init(combo: KeyCombo, claims: [Claim], conflict: Conflict? = nil) {
        self.combo = combo
        self.claims = claims
        self.conflict = conflict
    }

    var enabledBindings: [Claim] {
        claims.filter { $0.enabled && $0.isBinding }
    }

    /// Without a global binding, each menu command only applies in its own app.
    public var menuOnlyBindings: [Claim] {
        let active = enabledBindings
        return active.allSatisfy { $0.layer == .appMenu } ? active : []
    }

    /// The unique earliest global binding in the inventory. Confidence describes
    /// the evidence for a claim, not the dispatch order of peers at the same layer.
    public var winner: Claim? {
        let globals = enabledBindings.filter { $0.layer.isGlobal }
        let leading = Self.earliestLayerBindings(in: globals)
        return leading.count == 1 ? leading[0] : nil
    }

    static func earliestLayerBindings(in globals: [Claim]) -> [Claim] {
        guard let layer = globals.map(\.layer).min() else { return [] }
        return globals.filter { $0.layer == layer }
    }

    public var losers: [Claim] {
        guard let winner else { return [] }
        return claims.filter { $0.id != winner.id && $0.enabled && $0.isBinding }
    }

    public var hasConflict: Bool { conflict != nil }
}
