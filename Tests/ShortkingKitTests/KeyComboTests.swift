import XCTest
@testable import ShortkingKit

final class KeyComboTests: XCTestCase {

    /// Sources disagree about which half they can supply. Grouping only works if a
    /// combo built from a character and one built from a keycode land in the same
    /// bucket.
    func testCharacterAndKeyCodeGroupTogether() {
        let fromCharacter = KeyCombo(character: "g", modifiers: [.command, .shift])
        let fromKeyCode = KeyCombo(keyCode: 0x05, modifiers: [.command, .shift])

        XCTAssertEqual(fromCharacter.groupingKey, fromKeyCode.groupingKey)
        XCTAssertEqual(fromCharacter, fromKeyCode)
        XCTAssertEqual(Set([fromCharacter, fromKeyCode]).count, 1)
    }

    func testNormalizationFillsBothHalves() {
        let combo = KeyCombo(character: "g", modifiers: [.command])
        XCTAssertEqual(combo.keyCode, 0x05)
        XCTAssertEqual(combo.character, "G")

        let fromCode = KeyCombo(keyCode: 0x31, modifiers: [.control])
        XCTAssertEqual(fromCode.keyDisplay, "Space")
    }

    func testNamedKeyTokens() {
        XCTAssertEqual(KeyCombo(token: "space", modifiers: [.command])?.keyCode, 0x31)
        XCTAssertEqual(KeyCombo(token: "Escape", modifiers: [.command])?.keyCode, 0x35)
        XCTAssertEqual(KeyCombo(token: "f12", modifiers: [.command])?.keyCode, 0x6F)
        XCTAssertEqual(KeyCombo(token: "left", modifiers: [.command])?.keyCode, 0x7B)
    }

    /// Third-party configs spell keys their own way.
    func testAliasResolution() {
        XCTAssertEqual(KeyCodes.keyCode(forToken: "enter"), KeyCodes.nameToKeyCode["return"])
        XCTAssertEqual(KeyCodes.keyCode(forToken: "esc"), KeyCodes.nameToKeyCode["escape"])
        XCTAssertEqual(KeyCodes.keyCode(forToken: "backspace"), KeyCodes.nameToKeyCode["delete"])
        XCTAssertEqual(KeyCodes.keyCode(forToken: "PageUp"), KeyCodes.nameToKeyCode["pageup"])
        XCTAssertEqual(KeyCodes.keyCode(forToken: "open_bracket"), KeyCodes.charToKeyCode["["])
    }

    func testGlyphMapping() {
        // Carbon menu glyphs for the arrow keys.
        XCTAssertEqual(KeyCodes.glyphToKeyCode[0x64], 0x7B)  // left
        XCTAssertEqual(KeyCodes.glyphToKeyCode[0x65], 0x7C)  // right
        XCTAssertEqual(KeyCodes.glyphToKeyCode[0x68], 0x7E)  // up
        XCTAssertEqual(KeyCodes.glyphToKeyCode[0x6A], 0x7D)  // down
        XCTAssertEqual(KeyCodes.glyphToKeyCode[0x1B], 0x35)  // escape
    }

    func testDisplayString() {
        XCTAssertEqual(
            KeyCombo(character: "g", modifiers: [.command, .shift]).displayString,
            "⇧⌘G"
        )
        XCTAssertEqual(
            KeyCombo(keyCode: 0x31, modifiers: [.control, .option]).displayString,
            "⌃⌥Space"
        )
    }

    func testBareComboDetection() {
        XCTAssertTrue(KeyCombo(character: "g", modifiers: []).isBare)
        XCTAssertFalse(KeyCombo(character: "g", modifiers: [.command]).isBare)
    }

    func testCodableRoundTrip() throws {
        let combo = KeyCombo(keyCode: 0x05, character: "G", modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: data)
        XCTAssertEqual(decoded, combo)
        XCTAssertEqual(decoded.keyCode, combo.keyCode)
        XCTAssertEqual(decoded.modifiers, combo.modifiers)
    }

    func testSearchTokensCoverModifierWords() {
        let tokens = KeyCombo(character: "g", modifiers: [.command, .shift]).searchTokens
        XCTAssertTrue(tokens.contains("cmd"))
        XCTAssertTrue(tokens.contains("shift"))
        XCTAssertTrue(tokens.contains("g"))
    }
}
