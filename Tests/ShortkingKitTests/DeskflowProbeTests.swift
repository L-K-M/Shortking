import XCTest
@testable import ShortkingKit

final class DeskflowProbeTests: XCTestCase {
    func testCommonSweepIncludesCommandDigits() {
        let combos = ProbeSpace.combos(for: .common)
        for digit in ["1", "2"] {
            XCTAssertTrue(combos.contains(KeyCombo(keyCode: KeyCodes.charToKeyCode[digit]!, modifiers: .command)))
        }
        XCTAssertEqual(Set(ProbeSpace.combos(for: .wide)).count, ProbeSpace.combos(for: .wide).count)
    }

    @MainActor
    func testCrossProcessRegistrations() async throws {
        let bundle = try XCTUnwrap(Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" })
        let directory = bundle.bundleURL.deletingLastPathComponent()
        let runner = ProbeRunner(helperURL: directory.appendingPathComponent("shortking-probe"))
        let modifiers: Modifiers = [.control, .option, .command, .shift]
        let sharedKey = KeyCombo(keyCode: try XCTUnwrap(KeyCodes.nameToKeyCode["f17"]), modifiers: modifiers)
        let exclusiveKey = KeyCombo(keyCode: try XCTUnwrap(KeyCodes.nameToKeyCode["f16"]), modifiers: modifiers)

        let (status, shared) = CarbonHotKey.register(sharedKey, id: 0xD170)
        guard let shared else { throw XCTSkip("WindowServer denied the shared test hotkey (\(status)).") }
        defer { shared.release() }
        let (exclusiveStatus, exclusive) = CarbonHotKey.register(exclusiveKey, id: 0xD171, exclusive: true)
        guard let exclusive else { throw XCTSkip("WindowServer denied the exclusive test hotkey (\(exclusiveStatus)).") }
        defer { exclusive.release() }

        let report = try await runner.sweep(combos: [sharedKey, exclusiveKey])
        XCTAssertNotEqual(report.outcome(for: sharedKey), .free)
        if report.probingVerified {
            XCTAssertEqual(report.outcome(for: exclusiveKey), .claimed)
            XCTAssertEqual(report.outcome(for: sharedKey), report.detectsSharedRegistrations == true ? .claimed : .accepted)
        } else {
            XCTAssertFalse(report.claimedCombos.contains(exclusiveKey))
        }
    }

    func testOlderReportsCannotVerifyCrossProcessDetection() throws {
        let key = KeyCombo(keyCode: try XCTUnwrap(KeyCodes.charToKeyCode["1"]), modifiers: .command)
        let report = ProbeReport(
            results: [.init(combo: key, outcome: .free, status: 0)],
            breadth: .common, startedAt: Date(), finishedAt: Date(), probingVerified: true
        )
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        legacy.removeValue(forKey: "detectsSharedRegistrations")
        let decoded = try JSONDecoder().decode(ProbeReport.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(decoded.probingVerified)
        XCTAssertEqual(decoded.outcome(for: key), .accepted)
        XCTAssertTrue(decoded.free.isEmpty)
    }
}
