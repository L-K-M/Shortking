import XCTest
@testable import ShortkingKit

final class ModifierTests: XCTestCase {

    func testCarbonRoundTrip() {
        let combos: [Modifiers] = [
            [.command],
            [.command, .shift],
            [.control, .option],
            [.command, .control, .option, .shift],
        ]
        for modifiers in combos {
            XCTAssertEqual(Modifiers(carbon: modifiers.carbonMask), modifiers)
        }
    }

    func testCocoaRoundTrip() {
        let modifiers: Modifiers = [.command, .option, .function]
        XCTAssertEqual(Modifiers(cocoa: modifiers.cocoaFlags), modifiers)
    }

    /// The Accessibility API inverts the Command bit: `0` means plain ⌘ and `8`
    /// means no modifier at all. Getting this backwards silently mislabels every
    /// menu shortcut on the system, so it is pinned here.
    func testAccessibilityInvertedCommandBit() {
        XCTAssertEqual(Modifiers(axMenuItemModifiers: 0), [.command])
        XCTAssertEqual(Modifiers(axMenuItemModifiers: 1), [.command, .shift])
        XCTAssertEqual(Modifiers(axMenuItemModifiers: 2), [.command, .option])
        XCTAssertEqual(Modifiers(axMenuItemModifiers: 4), [.command, .control])
        XCTAssertEqual(Modifiers(axMenuItemModifiers: 8), [])
        XCTAssertEqual(Modifiers(axMenuItemModifiers: 9), [.shift])
        XCTAssertEqual(Modifiers(axMenuItemModifiers: 3), [.command, .shift, .option])
    }

    func testAccessibilityRoundTrip() {
        for raw in 0...15 {
            let modifiers = Modifiers(axMenuItemModifiers: raw)
            XCTAssertEqual(modifiers.axMenuItemModifiers, raw, "failed for raw \(raw)")
        }
    }

    func testKeyEquivalentParsing() {
        let (modifiers, key) = Modifiers.parseKeyEquivalent("@$g")
        XCTAssertEqual(modifiers, [.command, .shift])
        XCTAssertEqual(key, "g")

        let (plain, plainKey) = Modifiers.parseKeyEquivalent("@n")
        XCTAssertEqual(plain, [.command])
        XCTAssertEqual(plainKey, "n")

        let (all, allKey) = Modifiers.parseKeyEquivalent("^~$@k")
        XCTAssertEqual(all, [.control, .option, .shift, .command])
        XCTAssertEqual(allKey, "k")
    }

    /// AppKit treats an uppercase letter as implying Shift.
    func testUppercaseImpliesShift() {
        let (modifiers, key) = Modifiers.parseKeyEquivalent("@G")
        XCTAssertEqual(modifiers, [.command, .shift])
        XCTAssertEqual(key, "G")
    }

    func testKeyEquivalentPrefixRoundTrip() {
        let modifiers: Modifiers = [.control, .option, .shift, .command]
        let string = modifiers.keyEquivalentPrefix() + "k"
        XCTAssertEqual(Modifiers.parseKeyEquivalent(string).modifiers, modifiers)
    }

    func testDisplayOrderIsCanonical() {
        let modifiers: Modifiers = [.command, .shift, .option, .control]
        XCTAssertEqual(modifiers.displayString, "⌃⌥⇧⌘")
    }

    /// The macOS 15 hardening applies to ⌥-only and ⌥⇧-only, and to nothing else.
    /// A false positive here would report a system restriction as a conflict.
    func testOptionOnlyRestrictionScope() {
        XCTAssertTrue((Modifiers.option).isOptionOnlyRestricted)
        XCTAssertTrue(([.option, .shift] as Modifiers).isOptionOnlyRestricted)
        XCTAssertFalse(([.option, .command] as Modifiers).isOptionOnlyRestricted)
        XCTAssertFalse(([.option, .control] as Modifiers).isOptionOnlyRestricted)
        XCTAssertFalse((Modifiers.shift).isOptionOnlyRestricted)
        XCTAssertFalse((Modifiers.none).isOptionOnlyRestricted)
    }

    func testTokenParsing() {
        XCTAssertEqual(Modifiers.parseTokens(["cmd", "shift"]), [.command, .shift])
        XCTAssertEqual(Modifiers.parseTokens(["meta", "alt"]), [.command, .option])
        XCTAssertEqual(Modifiers.parseTokens(["left_command", "right_shift"]), [.command, .shift])
        XCTAssertEqual(Modifiers.parseTokens(["nonsense"]), [])
    }
}
