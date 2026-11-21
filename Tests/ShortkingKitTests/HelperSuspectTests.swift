import CoreGraphics
import XCTest
@testable import ShortkingKit

final class HelperSuspectTests: XCTestCase {
    func testKeyboardTapIncludesItsHelperEvenWithoutAWorkspaceApp() {
        let helperPID: Int32 = 12345
        let helper = Owner(name: "deskflow-core", pid: helperPID, kind: .unknown)
        let tap = EventTapInfo(
            tapID: 1, tapPoint: .hid, isActiveFilter: true,
            eventMask: 1 << CGEventType.keyDown.rawValue, tappingPID: helperPID, tappedPID: 0,
            enabled: true, minLatencyUsec: 0, avgLatencyUsec: 0, maxLatencyUsec: 0, owner: helper
        )
        var mouseOnly = tap
        mouseOnly.tappingPID = 23456
        mouseOnly.eventMask = 1 << CGEventType.mouseMoved.rawValue
        let apps = SystemDefinedSniffer.suspects(
            eventTaps: [tap, tap, mouseOnly], capabilityClaims: [], runningApps: []
        )
        XCTAssertEqual(apps.map(\.pid), [helperPID])
        XCTAssertEqual(apps.first?.name, "deskflow-core")
    }
}
