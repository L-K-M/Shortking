import Foundation
import XCTest
@testable import ShortkingKit

final class LiveCaptureCorrelationTests: XCTestCase {
    private let combo = KeyCombo(character: "1", modifiers: .command)
    private let other = KeyCombo(character: "2", modifiers: .command)
    private let at = Date(timeIntervalSince1970: 100)

    func testLiveCaptureRequiresMatchingPhysicalPress() {
        var correlation = LiveCaptureCorrelation()
        correlation.reset(target: combo)
        XCTAssertFalse(correlation.takeMatchingDelivery(at: at))
        correlation.recordPress(combo, at: at)
        correlation.recordPress(other, at: at.addingTimeInterval(0.01))
        XCTAssertFalse(correlation.takeMatchingDelivery(at: at.addingTimeInterval(0.02)))
        correlation.recordPress(combo, at: at)
        XCTAssertTrue(correlation.takeMatchingDelivery(at: at.addingTimeInterval(0.01)))
        XCTAssertFalse(correlation.takeMatchingDelivery(at: at.addingTimeInterval(0.02)))
        correlation.recordPress(combo, at: at)
        XCTAssertFalse(correlation.takeMatchingDelivery(at: at.addingTimeInterval(1)))
        XCTAssertFalse(correlation.takeMatchingDelivery(at: at.addingTimeInterval(-0.01)))
        correlation.recordPress(other, at: at)
        XCTAssertFalse(correlation.takeMatchingDelivery(at: at))
    }

    func testTargetChangesAndStopDiscardQueuedDeliveries() {
        var correlation = LiveCaptureCorrelation()
        correlation.reset(target: combo)
        correlation.recordPress(combo, at: at)
        correlation.reset(target: other)
        XCTAssertFalse(correlation.takeMatchingDelivery(at: at))
        correlation.recordPress(other, at: at)
        correlation.reset()
        XCTAssertFalse(correlation.takeMatchingDelivery(at: at))
    }
}
