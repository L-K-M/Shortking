import Foundation

/// The result of one probe sweep.
public struct ProbeReport: Codable, Hashable, Sendable {
    public var results: [CarbonHotKey.ProbeResult]
    public var breadth: ProbeBreadth
    public var startedAt: Date
    public var finishedAt: Date
    /// Whether Experiment A passed on this machine. When `false`, the claimed set
    /// is not trustworthy and the UI says so instead of showing it.
    public var probingVerified: Bool
    /// Any status codes we could not classify, recorded raw for triage.
    public var unknownStatusCodes: [Int32]

    public init(
        results: [CarbonHotKey.ProbeResult],
        breadth: ProbeBreadth,
        startedAt: Date,
        finishedAt: Date,
        probingVerified: Bool,
        unknownStatusCodes: [Int32] = []
    ) {
        self.results = results
        self.breadth = breadth
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.probingVerified = probingVerified
        self.unknownStatusCodes = unknownStatusCodes
    }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    public var claimed: [CarbonHotKey.ProbeResult] {
        results.filter { $0.outcome == .claimed }
    }

    public var restricted: [CarbonHotKey.ProbeResult] {
        results.filter { $0.outcome == .restricted }
    }

    public var free: [CarbonHotKey.ProbeResult] {
        results.filter { $0.outcome == .free }
    }

    public var unknown: [CarbonHotKey.ProbeResult] {
        results.filter { $0.outcome == .unknown }
    }

    public func outcome(for combo: KeyCombo) -> CarbonHotKey.ProbeOutcome? {
        results.first { $0.combo == combo }?.outcome
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
        progress: ((Int, Int) -> Void)? = nil
    ) -> ProbeReport {
        let startedAt = Date()

        // Experiment A: measure on this machine whether a duplicate registration is
        // actually refused. If it is not, every "claimed" reading below is
        // meaningless and the report says so rather than lying quietly.
        let (verified, _) = CarbonHotKey.selfTestProbingWorks()

        let targets = combos ?? ProbeSpace.combos(for: breadth)
        var results: [CarbonHotKey.ProbeResult] = []
        results.reserveCapacity(targets.count)
        var unknownCodes = Set<Int32>()

        for (index, combo) in targets.enumerated() {
            let result = CarbonHotKey.probe(combo, id: UInt32(index % 0xFFFF) + 1)
            results.append(result)
            if result.outcome == .unknown { unknownCodes.insert(result.status) }
            progress?(index + 1, targets.count)
        }

        return ProbeReport(
            results: results,
            breadth: breadth,
            startedAt: startedAt,
            finishedAt: Date(),
            probingVerified: verified,
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
