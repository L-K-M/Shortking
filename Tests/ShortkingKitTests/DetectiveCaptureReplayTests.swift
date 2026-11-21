import XCTest
@testable import ShortkingKit

final class DetectiveCaptureReplayTests: XCTestCase {
    /// Replays tap callbacks. The live OS test separately checks event delivery.
    @MainActor
    func testOnlyTheSelectedPressNamesTheUnlistedHelperAndReachesTheLedger() {
        let target = KeyCombo(character: "1", modifiers: .command)
        let unrelated = KeyCombo(character: "2", modifiers: .command)
        let store = AttributionStore(persistent: false)
        let session = DetectiveSession(store: store)
        session.investigate(combo: target, knownClaims: [], probeReport: nil)
        let capture = session.beginCapture()
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        let helper = "test.unlisted." + UUID().uuidString
        func delivery(_ registration: Int, after interval: TimeInterval) -> SystemDefinedSniffer.Delivery {
            .init(pid: 42, ownerName: "Unlisted Helper", bundleID: helper,
                  subtype: SystemDefinedSniffer.hotKeyDownSubtype, hotKeyID: registration,
                  receivedAt: origin.addingTimeInterval(interval))
        }

        session.recordPress(unrelated, at: origin, captureID: capture)
        session.record(delivery: delivery(2, after: 0.01), captureID: capture)
        // A different key also invalidates an outstanding target press.
        session.recordPress(target, at: origin.addingTimeInterval(1), captureID: capture)
        session.recordPress(unrelated, at: origin.addingTimeInterval(1.02), captureID: capture)
        session.record(delivery: delivery(2, after: 1.03), captureID: capture)
        XCTAssertFalse(session.findings.contains { $0.kind == .named })
        XCTAssertTrue(store.observations.isEmpty)

        session.recordPress(target, at: origin.addingTimeInterval(2), captureID: capture)
        session.record(delivery: delivery(1, after: 2.01), captureID: capture)
        let named = session.findings.filter { $0.kind == .named }
        XCTAssertEqual(named.count, 1)
        XCTAssertTrue(named.first?.headline.contains("Unlisted Helper") == true)
        XCTAssertEqual(store.observations.map(\.kind), [.liveCapture])
        XCTAssertEqual(store.observations.map(\.ownerIdentity), [helper])
        XCTAssertEqual(store.observations.map(\.comboKey), [target.groupingKey])

        session.stopCapture()
        session.recordPress(target, at: origin.addingTimeInterval(3), captureID: capture)
        session.record(delivery: delivery(1, after: 3.01), captureID: capture)
        XCTAssertEqual(session.findings.filter { $0.kind == .named }.count, 1)
        XCTAssertEqual(store.observations.count, 1)
    }
}
