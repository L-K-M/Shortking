import Foundation

/// One observation linking a combination to an owner.
public struct AttributionObservation: Codable, Hashable, Sendable {

    public enum Kind: String, Codable, Hashable, Sendable {
        /// The combination became free when this app quit.
        case freedOnQuit
        /// The combination became claimed when this app launched.
        case claimedOnLaunch
        /// The combination did *not* change when this app did — evidence against.
        case unchanged
        /// A live systemDefined capture named this process directly.
        case liveCapture
        /// Side-channel correlation pointed here.
        case sideChannel
    }

    public var comboKey: String
    public var ownerIdentity: String
    public var ownerName: String
    public var kind: Kind
    /// True when more than one app changed state inside the observation window, so
    /// this observation cannot distinguish between them.
    public var ambiguous: Bool
    public var observedAt: Date

    public init(
        comboKey: String,
        ownerIdentity: String,
        ownerName: String,
        kind: Kind,
        ambiguous: Bool = false,
        observedAt: Date = Date()
    ) {
        self.comboKey = comboKey
        self.ownerIdentity = ownerIdentity
        self.ownerName = ownerName
        self.kind = kind
        self.ambiguous = ambiguous
        self.observedAt = observedAt
    }

    /// How much this observation counts toward (or against) an attribution.
    ///
    /// A live capture is near-proof. An ambiguous launch/quit observation counts
    /// half, because it could equally belong to whatever else changed in the window.
    public var weight: Double {
        let base: Double
        switch kind {
        case .liveCapture:      base = 4.0
        case .freedOnQuit:      base = 1.0
        case .claimedOnLaunch:  base = 1.0
        case .sideChannel:      base = 0.5
        case .unchanged:        base = -2.0
        }
        return ambiguous ? base / 2 : base
    }
}

/// The long-lived attribution ledger.
///
/// This is the file that makes Shortking more valuable the longer it is installed:
/// after a few days of ordinary use it holds a fully attributed map of the
/// WindowServer layer, built entirely from public API, with zero cooperation from
/// any app, covering apps nobody wrote an adapter for.
public final class AttributionStore: @unchecked Sendable {

    private struct Ledger: Codable {
        var observations: [AttributionObservation] = []
    }

    /// Keeps the ledger bounded. Old observations are dropped oldest-first once the
    /// cap is hit; the confidence curve saturates well before this many anyway.
    private let maxObservations = 20_000

    private var ledger = Ledger()
    private let lock = NSLock()
    private let persistence: JSONStore<[AttributionObservation]>?

    public init(persistent: Bool = true) {
        self.persistence = persistent ? JSONStore(filename: "attribution.json") : nil
        if let loaded = persistence?.load() {
            ledger.observations = loaded
        }
    }

    public var observations: [AttributionObservation] {
        lock.lock()
        defer { lock.unlock() }
        return ledger.observations
    }

    public func record(_ observations: [AttributionObservation]) {
        guard !observations.isEmpty else { return }
        lock.lock()
        ledger.observations.append(contentsOf: observations)
        if ledger.observations.count > maxObservations {
            ledger.observations.removeFirst(ledger.observations.count - maxObservations)
        }
        let snapshot = ledger.observations
        lock.unlock()
        persistence?.save(snapshot)
        Log.attribution.info("Recorded \(observations.count) attribution observation(s)")
    }

    public func reset() {
        lock.lock()
        ledger.observations = []
        lock.unlock()
        persistence?.save([])
    }

    // MARK: - Inference

    /// Confidence from accumulated evidence.
    ///
    /// Asymmetric on purpose: one contradiction costs twice what one confirmation
    /// gains, because a wrong name is worse than no name. Saturates at 0.95 and
    /// never reaches 1.0 — an inference is never a direct read, and the UI must
    /// never be able to render it as one.
    public static func confidence(supporting: Double, contradicting: Double) -> Double {
        let net = supporting - 2 * contradicting
        guard net > 0 else { return 0 }
        let curve = 1 - exp(-0.45 * net)
        return min(0.95, max(0.0, 0.3 + 0.65 * curve))
    }

    /// The best-supported owner for each combination, above a confidence floor.
    public func inferences(minimumConfidence: Double = 0.3) -> [Inference] {
        let all = observations

        // comboKey → ownerIdentity → running totals
        var totals: [String: [String: (support: Double, against: Double, name: String, count: Int, last: Date)]] = [:]

        for observation in all {
            var byOwner = totals[observation.comboKey] ?? [:]
            var entry = byOwner[observation.ownerIdentity]
                ?? (support: 0, against: 0, name: observation.ownerName, count: 0, last: observation.observedAt)

            let weight = observation.weight
            if weight >= 0 {
                entry.support += weight
            } else {
                entry.against += -weight
            }
            entry.count += 1
            entry.last = max(entry.last, observation.observedAt)
            byOwner[observation.ownerIdentity] = entry
            totals[observation.comboKey] = byOwner
        }

        var results: [Inference] = []
        for (comboKey, byOwner) in totals {
            let scored = byOwner.map { identity, entry -> Inference in
                Inference(
                    comboKey: comboKey,
                    ownerIdentity: identity,
                    ownerName: entry.name,
                    confidence: Self.confidence(supporting: entry.support, contradicting: entry.against),
                    observationCount: entry.count,
                    lastObserved: entry.last
                )
            }
            // One combination, one inferred owner: the best-supported candidate.
            // Reporting two competing guesses would be noise, not honesty.
            guard let best = scored.max(by: { $0.confidence < $1.confidence }) else { continue }
            guard best.confidence >= minimumConfidence else { continue }
            results.append(best)
        }

        return results
    }

    public struct Inference: Hashable, Sendable {
        public var comboKey: String
        public var ownerIdentity: String
        public var ownerName: String
        public var confidence: Double
        public var observationCount: Int
        public var lastObserved: Date
    }

    /// Turns inferences into claims, matched back to the combinations they describe.
    public func inferredClaims(for combos: [KeyCombo], minimumConfidence: Double = 0.3) -> [Claim] {
        let byKey = Dictionary(combos.map { ($0.groupingKey, $0) }, uniquingKeysWith: { first, _ in first })

        return inferences(minimumConfidence: minimumConfidence).compactMap { inference in
            guard let combo = byKey[inference.comboKey] else { return nil }
            return Claim(
                combo: combo,
                layer: .windowServer,
                status: .inferred,
                owner: Owner(
                    name: inference.ownerName,
                    bundleID: inference.ownerIdentity.contains(".") ? inference.ownerIdentity : nil,
                    kind: .application
                ),
                label: nil,
                evidence: [
                    Evidence(
                        kind: .differentialObservation,
                        summary: "\(inference.observationCount) consistent observation(s) across "
                            + "app launch and quit",
                        detail: [
                            "owner": inference.ownerName,
                            "observations": "\(inference.observationCount)",
                            "confidence": String(format: "%.2f", inference.confidence),
                            "lastObserved": ISO8601DateFormatter().string(from: inference.lastObserved),
                        ]
                    )
                ],
                confidence: inference.confidence,
                lastConfirmed: inference.lastObserved
            )
        }
    }
}
