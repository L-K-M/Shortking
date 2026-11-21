import XCTest
@testable import ShortkingKit

final class DeskflowInventoryTests: XCTestCase {
    func testStoppedServerCannotAccountForAnotherOwnersRegistration() {
        let combo = KeyCombo(character: "1", modifiers: .command)
        let saved = Claim(
            combo: combo, layer: .windowServer, status: .known,
            owner: Owner(name: "Deskflow", bundleID: "org.deskflow.deskflow"),
            label: "switchToScreen(local)", enabled: false
        )
        let report = ProbeReport(
            results: [.init(combo: combo, outcome: .claimed, status: CarbonHotKey.hotKeyExistsErr)],
            breadth: .common, startedAt: Date(), finishedAt: Date(), probingVerified: true
        )
        let claims = ClaimMerger.applyProbeReport(report, to: [saved])
        XCTAssertEqual(claims.filter { $0.enabled && $0.status == .probedClaimed }.map(\.combo), [combo])
        XCTAssertEqual(claims.first { $0.id == saved.id }?.evidence, [])
    }
}
