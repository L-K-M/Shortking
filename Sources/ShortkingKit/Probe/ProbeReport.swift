import Foundation

/// The result of one probe sweep.
public struct ProbeReport: Codable, Hashable, Sendable {
    public var results: [CarbonHotKey.ProbeResult]
    public var breadth: ProbeBreadth
    public var startedAt: Date
    public var finishedAt: Date
    /// Whether the probe refused a key held exclusively by a separate process.
    public var probingVerified: Bool {
        // Older helpers used a same-process collision as their positive control.
        get { verifiedByHelper && detectsSharedRegistrations != nil }
        set { verifiedByHelper = newValue }
    }
    private var verifiedByHelper: Bool
    /// Nil in reports from helpers that did not check shared registrations.
    public var detectsSharedRegistrations: Bool?
    /// Any status codes we could not classify, recorded raw for triage.
    public var unknownStatusCodes: [Int32]

    private enum CodingKeys: String, CodingKey {
        case results, breadth, startedAt, finishedAt, unknownStatusCodes, detectsSharedRegistrations
        case verifiedByHelper = "probingVerified"
    }

    public init(
        results: [CarbonHotKey.ProbeResult],
        breadth: ProbeBreadth,
        startedAt: Date,
        finishedAt: Date,
        probingVerified: Bool,
        detectsSharedRegistrations: Bool? = false,
        unknownStatusCodes: [Int32] = []
    ) {
        self.results = results
        self.breadth = breadth
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.verifiedByHelper = probingVerified
        self.detectsSharedRegistrations = detectsSharedRegistrations
        self.unknownStatusCodes = unknownStatusCodes
    }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    public var claimed: [CarbonHotKey.ProbeResult] {
        guard probingVerified else { return [] }
        return results.filter { $0.outcome == .claimed }
    }

    public var restricted: [CarbonHotKey.ProbeResult] {
        results.filter { $0.outcome == .restricted }
    }

    public var free: [CarbonHotKey.ProbeResult] {
        guard probingVerified && detectsSharedRegistrations == true else { return [] }
        return results.filter { $0.outcome == .free }
    }

    public var unknown: [CarbonHotKey.ProbeResult] {
        results.filter { $0.outcome == .unknown }
    }

    public func outcome(for combo: KeyCombo) -> CarbonHotKey.ProbeOutcome? {
        guard let outcome = results.first(where: { $0.combo == combo })?.outcome else { return nil }
        switch outcome {
        case .free where detectsSharedRegistrations != true || !probingVerified: return .accepted
        case .claimed where !probingVerified: return nil
        default: return outcome
        }
    }

    /// Accepted probes can be compared with explicit collisions, even on systems
    /// where a success cannot rule out a shared registration.
    var acceptedCombos: Set<KeyCombo> {
        Set(results.filter { $0.outcome == .free || $0.outcome == .accepted }.map(\.combo))
    }

    /// The set of combinations someone holds, as a lookup set.
    public var claimedCombos: Set<KeyCombo> {
        Set(claimed.map(\.combo))
    }
}

/// Runs a probe sweep in-process.
///
/// **Prefer ``ProbeRunner``**, which drives this same code in a short-lived helper
/// process. A crash partway through an in-process sweep would leave the user's
/// keyboard partially hijacked until Shortking quits; a helper process gets
/// guaranteed cleanup from the OS.
public enum ProbeSweep {

    /// Performs the sweep, releasing every successful registration immediately.
    public static func run(
        breadth: ProbeBreadth,
        combos: [KeyCombo]? = nil,
        verification: ProbeCoverage = .unverified,
        progress: ((Int, Int) -> Void)? = nil
    ) -> ProbeReport {
        let startedAt = Date()

        let targets = combos ?? ProbeSpace.combos(for: breadth)
        var results: [CarbonHotKey.ProbeResult] = []
        results.reserveCapacity(targets.count)
        var unknownCodes = Set<Int32>()

        for (index, combo) in targets.enumerated() {
            var result = CarbonHotKey.probe(combo, id: UInt32(index % 0xFFFF) + 1)
            if result.outcome == .unknown { unknownCodes.insert(result.status) }
            if result.outcome == .accepted && verification == .sharedAndExclusive { result.outcome = .free }
            if result.outcome == .claimed && verification == .unverified { result.outcome = .unknown }
            results.append(result)
            progress?(index + 1, targets.count)
        }

        return ProbeReport(
            results: results,
            breadth: breadth,
            startedAt: startedAt,
            finishedAt: Date(),
            probingVerified: verification != .unverified,
            detectsSharedRegistrations: verification == .sharedAndExclusive,
            unknownStatusCodes: Array(unknownCodes).sorted()
        )
    }

    /// Turns a report into claims.
    ///
    /// Only combinations that came back `claimed` produce anything, and what they
    /// produce is an *unattributed* claim — a first-class state, not a gap. The
    /// merger later downgrades these to corroborating evidence wherever a named
    /// claim already exists.
    public static func claims(from report: ProbeReport) -> [Claim] {
        guard report.probingVerified else { return [] }

        return report.claimed.map { result in
            Claim(
                combo: result.combo,
                layer: .windowServer,
                status: .probedClaimed,
                owner: nil,
                label: nil,
                evidence: [
                    Evidence(
                        kind: .probeExclusionFailure,
                        summary: "Registration refused (\(result.status))",
                        detail: [
                            "status": "\(result.status)",
                            "meaning": result.status == CarbonHotKey.hotKeyExistsErr
                                ? "eventHotKeyExistsErr — another process holds this combination"
                                : "unrecognised failure",
                        ]
                    )
                ]
            )
        }
    }
}
