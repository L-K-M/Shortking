import XCTest
@testable import ShortkingKit

final class ConflictAnalyzerTests: XCTestCase {

    private func claim(
        _ combo: KeyCombo,
        layer: ClaimLayer,
        owner: String,
        label: String? = nil,
        status: ClaimStatus = .known,
        enabled: Bool = true
    ) -> Claim {
        Claim(
            combo: combo,
            layer: layer,
            status: status,
            owner: Owner(name: owner, bundleID: "com.test.\(owner.lowercased())"),
            label: label,
            enabled: enabled
        )
    }

    private let combo = KeyCombo(character: "g", modifiers: [.command, .shift])

    func testTwoClaimsAtTheSameGlobalLayerIsDefinite() {
        let group = ComboGroup(combo: combo, claims: [
            claim(combo, layer: .windowServer, owner: "Raycast"),
            claim(combo, layer: .windowServer, owner: "Alfred"),
        ])

        let conflict = ConflictAnalyzer.conflict(for: group)
        XCTAssertEqual(conflict?.kind, .definite)
        XCTAssertEqual(conflict?.severity, .high)
        XCTAssertEqual(conflict?.losers.count, 2)
    }

    func testDifferentGlobalLayersShadow() {
        let group = ComboGroup(combo: combo, claims: [
            claim(combo, layer: .windowServer, owner: "Raycast"),
            claim(combo, layer: .symbolic, owner: "Spotlight"),
        ])

        let conflict = ConflictAnalyzer.conflict(for: group)
        XCTAssertEqual(conflict?.kind, .shadowed)
        XCTAssertEqual(conflict?.winner?.ownerName, "Raycast")
    }

    func testGlobalVersusMenuIsContextual() {
        let group = ComboGroup(combo: combo, claims: [
            claim(combo, layer: .windowServer, owner: "Raycast"),
            claim(combo, layer: .appMenu, owner: "Finder", label: "Go to Folder…"),
        ])

        let conflict = ConflictAnalyzer.conflict(for: group)
        XCTAssertEqual(conflict?.kind, .contextual)
        XCTAssertEqual(conflict?.winner?.ownerName, "Raycast")
        XCTAssertTrue(conflict?.explanation.contains("Finder") == true)
    }

    /// ⌘S means Save in every app. Two menu claims in *different* apps are correct
    /// behaviour, not a conflict, and reporting them would bury the real ones.
    func testMenuClaimsInDifferentAppsAreNotAConflict() {
        let save = KeyCombo(character: "s", modifiers: [.command])
        let group = ComboGroup(combo: save, claims: [
            claim(save, layer: .appMenu, owner: "Finder", label: "Save"),
            claim(save, layer: .appMenu, owner: "Safari", label: "Save"),
            claim(save, layer: .appMenu, owner: "Xcode", label: "Save"),
        ])

        XCTAssertNil(ConflictAnalyzer.conflict(for: group))
    }

    /// Two menu items in the *same* app bound to one combination is a real problem.
    func testTwoMenuClaimsInTheSameAppIsAConflict() {
        let group = ComboGroup(combo: combo, claims: [
            claim(combo, layer: .appMenu, owner: "Finder", label: "Go to Folder…"),
            claim(combo, layer: .appMenu, owner: "Finder", label: "Group By"),
        ])

        let conflict = ConflictAnalyzer.conflict(for: group)
        XCTAssertEqual(conflict?.kind, .definite)
    }

    func testUnattributedProbeResultIsItsOwnState() {
        let probed = Claim(combo: combo, layer: .windowServer, status: .probedClaimed, owner: nil)
        let group = ComboGroup(combo: combo, claims: [probed])

        let conflict = ConflictAnalyzer.conflict(for: group)
        XCTAssertEqual(conflict?.kind, .unattributed)
        XCTAssertNotNil(conflict?.suggestion)
    }

    func testDisabledClaimsDoNotConflict() {
        let group = ComboGroup(combo: combo, claims: [
            claim(combo, layer: .windowServer, owner: "Raycast"),
            claim(combo, layer: .windowServer, owner: "Alfred", enabled: false),
        ])

        XCTAssertNil(ConflictAnalyzer.conflict(for: group))
    }

    func testWinnerIsTheLowestEnabledLayer() {
        let group = ComboGroup(combo: combo, claims: [
            claim(combo, layer: .appMenu, owner: "Finder"),
            claim(combo, layer: .virtualHID, owner: "Karabiner-Elements"),
            claim(combo, layer: .windowServer, owner: "Raycast"),
        ])

        XCTAssertEqual(group.winner?.ownerName, "Karabiner-Elements")
    }

    /// Capability records describe what a process *could* do. They must never win a
    /// combination or be presented as an owner.
    func testCapabilityRecordsAreNotBindings() {
        var capability = claim(combo, layer: .sessionTap, owner: "Hammerspoon")
        capability.status = .capability

        let group = ComboGroup(combo: combo, claims: [
            capability,
            claim(combo, layer: .appMenu, owner: "Finder"),
        ])

        XCTAssertEqual(group.winner?.ownerName, "Finder")
    }
}

final class ClaimMergerTests: XCTestCase {

    private let combo = KeyCombo(character: "g", modifiers: [.command, .shift])

    func testMergeUnionsEvidenceAndKeepsEarliestFirstSeen() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)

        let first = Claim(
            combo: combo, layer: .appMenu, status: .known,
            owner: Owner(name: "Finder", bundleID: "com.apple.finder"),
            label: "Go to Folder…",
            evidence: [Evidence(kind: .accessibilityMenu, summary: "Go ▸ Go to Folder…")],
            firstSeen: early, lastConfirmed: early
        )
        let second = Claim(
            combo: combo, layer: .appMenu, status: .known,
            owner: Owner(name: "Finder", bundleID: "com.apple.finder"),
            label: "Go to Folder…",
            evidence: [Evidence(kind: .userKeyEquivalent, summary: "User shortcut")],
            firstSeen: late, lastConfirmed: late
        )

        let merged = ClaimMerger.merge([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].evidence.count, 2)
        XCTAssertEqual(merged[0].firstSeen, early)
        XCTAssertEqual(merged[0].lastConfirmed, late)
    }

    /// A probe refusal on a combination that a named WindowServer claim already
    /// explains is corroboration, not a phantom second claim.
    func testProbeResultAttachesToAnExistingWindowServerClaim() {
        let named = Claim(
            combo: combo, layer: .windowServer, status: .known,
            owner: Owner(name: "Raycast", bundleID: "com.raycast.macos"),
            label: "Search Snippets"
        )
        let report = ProbeReport(
            results: [CarbonHotKey.ProbeResult(combo: combo, outcome: .claimed, status: -9878)],
            breadth: .common,
            startedAt: Date(), finishedAt: Date(),
            probingVerified: true
        )

        let result = ClaimMerger.applyProbeReport(report, to: [named])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, .known)
        XCTAssertTrue(result[0].evidence.contains { $0.kind == .probeExclusionFailure })
    }

    /// A session-tap claim cannot cause a registration refusal, so it must not
    /// absorb the evidence — the refusal still needs its own unattributed claim.
    func testProbeResultDoesNotAttachToASessionTapClaim() {
        let skhd = Claim(
            combo: combo, layer: .sessionTap, status: .known,
            owner: Owner(name: "skhd"), label: "open -a Finder"
        )
        let report = ProbeReport(
            results: [CarbonHotKey.ProbeResult(combo: combo, outcome: .claimed, status: -9878)],
            breadth: .common,
            startedAt: Date(), finishedAt: Date(),
            probingVerified: true
        )

        let result = ClaimMerger.applyProbeReport(report, to: [skhd])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains { $0.status == .probedClaimed })
    }

    /// If probing is unreliable on this machine, its results must not enter the
    /// model at all rather than being shown wrongly.
    func testUnverifiedProbeReportIsIgnored() {
        let report = ProbeReport(
            results: [CarbonHotKey.ProbeResult(combo: combo, outcome: .claimed, status: -9878)],
            breadth: .common,
            startedAt: Date(), finishedAt: Date(),
            probingVerified: false
        )
        XCTAssertTrue(ClaimMerger.applyProbeReport(report, to: []).isEmpty)
        XCTAssertTrue(ProbeSweep.claims(from: report).isEmpty)
    }

    func testGroupingDropsCapabilityAndBareCombos() {
        let capability = Claim(
            combo: KeyCombo(keyCode: nil, character: nil, modifiers: []),
            layer: .sessionTap, status: .capability,
            owner: Owner(name: "Hammerspoon")
        )
        let real = Claim(
            combo: combo, layer: .appMenu, status: .known, owner: Owner(name: "Finder")
        )

        let groups = ClaimMerger.group([capability, real])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].combo, combo)
    }
}

final class ProbeClassificationTests: XCTestCase {

    /// `-9868` on an ⌥-only combination is the macOS 15 hardening, not a conflict.
    /// Getting this wrong emits a false positive on every ⌥ shortcut on the machine.
    func testOptionHardeningIsNotAConflict() {
        let optionOnly = KeyCombo(character: "o", modifiers: [.option, .shift])
        XCTAssertEqual(
            CarbonHotKey.classify(status: CarbonHotKey.internalErr, combo: optionOnly),
            .restricted
        )
    }

    /// The same status code on a combination Apple did *not* harden is genuinely
    /// unknown, and is reported as such rather than being swept into "restricted".
    func testInternalErrorElsewhereIsUnknown() {
        let normal = KeyCombo(character: "g", modifiers: [.command, .shift])
        XCTAssertEqual(
            CarbonHotKey.classify(status: CarbonHotKey.internalErr, combo: normal),
            .unknown
        )
    }

    func testExistingHotKeyIsClaimed() {
        let combo = KeyCombo(character: "g", modifiers: [.command, .shift])
        XCTAssertEqual(
            CarbonHotKey.classify(status: CarbonHotKey.hotKeyExistsErr, combo: combo),
            .claimed
        )
        XCTAssertEqual(CarbonHotKey.classify(status: 0, combo: combo), .free)
    }

    func testProbeSpaceNeverIncludesBareCombos() {
        for breadth in ProbeBreadth.allCases {
            XCTAssertFalse(
                ProbeSpace.combos(for: breadth).contains { $0.isBare },
                "\(breadth) produced a bare combination"
            )
        }
    }

    func testProbeSpaceGrowsWithBreadth() {
        XCTAssertLessThan(
            ProbeSpace.estimatedProbeCount(for: .common),
            ProbeSpace.estimatedProbeCount(for: .exhaustive)
        )
    }

    func testComboEncodingRoundTrip() {
        let combos = [
            KeyCombo(character: "g", modifiers: [.command, .shift]),
            KeyCombo(token: "space", modifiers: [.control, .option])!,
        ]
        let encoded = combos.compactMap { combo -> String? in
            guard let keyCode = combo.keyCode else { return nil }
            return "\(keyCode):\(combo.modifiers.rawValue)"
        }.joined(separator: ",")

        XCTAssertEqual(ProbeRunner.decodeCombos(encoded), combos)
    }
}

final class AttributionTests: XCTestCase {

    func testConfidenceRisesWithConsistentObservations() {
        let one = AttributionStore.confidence(supporting: 1, contradicting: 0)
        let three = AttributionStore.confidence(supporting: 3, contradicting: 0)
        let seven = AttributionStore.confidence(supporting: 7, contradicting: 0)

        XCTAssertLessThan(one, three)
        XCTAssertLessThan(three, seven)
    }

    /// An inference is never a direct read, so it must never reach 1.0 — the UI
    /// would otherwise be able to render a guess as a fact.
    func testConfidenceNeverReachesCertainty() {
        XCTAssertLessThan(AttributionStore.confidence(supporting: 1_000, contradicting: 0), 1.0)
        XCTAssertLessThanOrEqual(AttributionStore.confidence(supporting: 1_000, contradicting: 0), 0.95)
    }

    /// One contradiction costs twice what one confirmation gains: a wrong name is
    /// worse than no name.
    func testContradictionsAreWeightedMoreHeavily() {
        XCTAssertEqual(AttributionStore.confidence(supporting: 2, contradicting: 1), 0)
        XCTAssertGreaterThan(
            AttributionStore.confidence(supporting: 6, contradicting: 0),
            AttributionStore.confidence(supporting: 6, contradicting: 1)
        )
    }

    func testAmbiguousObservationsCountHalf() {
        let clear = AttributionObservation(
            comboKey: "k5|m3", ownerIdentity: "a", ownerName: "A", kind: .freedOnQuit
        )
        let ambiguous = AttributionObservation(
            comboKey: "k5|m3", ownerIdentity: "a", ownerName: "A",
            kind: .freedOnQuit, ambiguous: true
        )
        XCTAssertEqual(ambiguous.weight, clear.weight / 2)
    }

    /// A live capture names the process outright, so it outweighs a pile of
    /// circumstantial launch/quit observations.
    func testLiveCaptureOutweighsOtherEvidence() {
        let live = AttributionObservation(
            comboKey: "k5|m3", ownerIdentity: "a", ownerName: "A", kind: .liveCapture
        )
        let quit = AttributionObservation(
            comboKey: "k5|m3", ownerIdentity: "a", ownerName: "A", kind: .freedOnQuit
        )
        XCTAssertGreaterThan(live.weight, quit.weight * 3)
    }

    func testInferenceRequiresMinimumConfidence() {
        let store = AttributionStore(persistent: false)
        let combo = KeyCombo(character: "g", modifiers: [.command, .shift])

        store.record([
            AttributionObservation(
                comboKey: combo.groupingKey,
                ownerIdentity: "com.raycast.macos",
                ownerName: "Raycast",
                kind: .freedOnQuit
            )
        ])

        let claims = store.inferredClaims(for: [combo])
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims[0].status, .inferred)
        XCTAssertEqual(claims[0].owner?.name, "Raycast")
        XCTAssertLessThan(claims[0].confidence, 1.0)

        XCTAssertTrue(store.inferredClaims(for: [combo], minimumConfidence: 0.9).isEmpty)
    }

    func testStrongestCandidateWinsASingleCombination() {
        let store = AttributionStore(persistent: false)
        let combo = KeyCombo(character: "g", modifiers: [.command, .shift])

        for _ in 0..<5 {
            store.record([
                AttributionObservation(
                    comboKey: combo.groupingKey, ownerIdentity: "com.raycast.macos",
                    ownerName: "Raycast", kind: .freedOnQuit
                )
            ])
        }
        store.record([
            AttributionObservation(
                comboKey: combo.groupingKey, ownerIdentity: "com.runningwithcrayons.Alfred",
                ownerName: "Alfred", kind: .freedOnQuit
            )
        ])

        let claims = store.inferredClaims(for: [combo])
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims[0].owner?.name, "Raycast")
    }
}
