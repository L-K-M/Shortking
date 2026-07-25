import XCTest
@testable import ShortkingKit

final class SkhdAdapterTests: XCTestCase {

    func testParsesBindings() {
        let config = """
        # window management
        cmd + shift - g : open -a Finder
        ctrl - a : echo hello
        default < cmd - j : yabai -m window --focus west

        :: resize @
        alt - h  # this is a bare-modifier trigger with a comment
        """

        let bindings = SkhdAdapter.parse(contents: config)
        let byLabel = Dictionary(bindings.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(
            byLabel["open -a Finder"]?.combo,
            KeyCombo(character: "g", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            byLabel["echo hello"]?.combo,
            KeyCombo(character: "a", modifiers: [.control])
        )
        XCTAssertEqual(byLabel["open -a Finder"]?.line, 2)
    }

    func testModeScopedBindingCarriesMode() {
        let bindings = SkhdAdapter.parse(contents: "resize < cmd - h : yabai -m window --resize")
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings[0].detail["mode"], "resize")
        XCTAssertEqual(bindings[0].combo, KeyCombo(character: "h", modifiers: [.command]))
    }

    func testSkipsCommentsModesAndBareKeys() {
        let config = """
        # nothing here
        :: default : echo mode
        .blacklist [ "terminal" ]
        """
        XCTAssertTrue(SkhdAdapter.parse(contents: config).isEmpty)
    }

    func testLiteralKeyCode() {
        let bindings = SkhdAdapter.parse(contents: "cmd - 0x28 : echo k")
        XCTAssertEqual(bindings.first?.combo.keyCode, 0x28)
    }
}

final class HammerspoonAdapterTests: XCTestCase {

    func testParsesHotkeyBind() {
        let lua = """
        local hyper = {"cmd", "alt", "ctrl"}
        hs.hotkey.bind({"cmd", "shift"}, "g", function() print("hi") end)
        hs.hotkey.bind(hyper, "r", function() hs.reload() end)
        hs.hotkey.bind({"ctrl"}, "space", nil, function() end)
        """

        let bindings = HammerspoonAdapter.parse(contents: lua)

        // The `hyper` binding uses a variable, which a literal parse cannot see —
        // and that limitation is documented rather than papered over.
        XCTAssertEqual(bindings.count, 2)
        XCTAssertTrue(bindings.contains {
            $0.combo == KeyCombo(character: "g", modifiers: [.command, .shift])
        })
        XCTAssertTrue(bindings.contains {
            $0.combo == KeyCombo(token: "space", modifiers: [.control])
        })
    }

    func testReportsLineNumbers() {
        let lua = "\n\nhs.hotkey.bind({\"cmd\"}, \"j\", function() end)"
        XCTAssertEqual(HammerspoonAdapter.parse(contents: lua).first?.line, 3)
    }
}

final class VSCodeAdapterTests: XCTestCase {

    func testParsesJSONCWithCommentsAndTrailingCommas() throws {
        let json = """
        // Place your key bindings in this file to override the defaults
        [
            {
                "key": "cmd+shift+g",       // go to symbol
                "command": "workbench.action.gotoSymbol"
            },
            /* a block comment
               spanning lines */
            {
                "key": "cmd+k cmd+s",
                "command": "workbench.action.openGlobalKeybindings",
                "when": "editorTextFocus",
            },
            {
                "key": "cmd+p",
                "command": "-workbench.action.quickOpen"
            },
        ]
        """

        let bindings = try VSCodeAdapter.parse(contents: json, path: "test")

        // Three entries, but one is a removal (`-` prefix) and is not a claim.
        XCTAssertEqual(bindings.count, 2)

        XCTAssertEqual(
            bindings[0].combo,
            KeyCombo(character: "g", modifiers: [.command, .shift])
        )

        // A chord only claims its first keystroke.
        XCTAssertEqual(bindings[1].combo, KeyCombo(character: "k", modifiers: [.command]))
        XCTAssertEqual(bindings[1].detail["chord"], "cmd+k cmd+s")
        XCTAssertEqual(bindings[1].detail["when"], "editorTextFocus")
    }

    func testJSONCPreservesStringsContainingCommentMarkers() {
        let input = #"{"url": "https://example.com/*not a comment*/"}"#
        XCTAssertEqual(JSONC.strip(input), input)
    }

    func testJSONCStripsTrailingCommas() {
        XCTAssertEqual(JSONC.strip("[1, 2, 3,]"), "[1, 2, 3]")
        XCTAssertEqual(JSONC.strip("{\"a\": 1,}"), "{\"a\": 1}")
    }
}

final class JetBrainsAdapterTests: XCTestCase {

    func testParsesKeymapXML() throws {
        let xml = """
        <keymap version="1" name="macOS copy" parent="Mac OS X 10.5+">
          <action id="GotoFile">
            <keyboard-shortcut first-keystroke="shift meta O"/>
          </action>
          <action id="Refactorings.QuickListPopupAction">
            <keyboard-shortcut first-keystroke="ctrl meta T"/>
          </action>
          <action id="EditorDeleteLine">
            <keyboard-shortcut first-keystroke="meta BACK_SPACE"/>
          </action>
        </keymap>
        """

        let parser = KeymapXMLParser()
        XCTAssertTrue(parser.parse(data: Data(xml.utf8)))
        XCTAssertEqual(parser.shortcuts.count, 3)

        XCTAssertEqual(
            JetBrainsAdapter.parseKeystroke("shift meta O"),
            KeyCombo(character: "o", modifiers: [.shift, .command])
        )
        XCTAssertEqual(
            JetBrainsAdapter.parseKeystroke("meta BACK_SPACE"),
            KeyCombo(token: "delete", modifiers: [.command])
        )
    }

    func testIDENameExtraction() {
        let path = NSHomeDirectory()
            + "/Library/Application Support/JetBrains/IntelliJIdea2026.1/keymaps/custom.xml"
        XCTAssertEqual(JetBrainsAdapter.ideName(fromPath: path), "IntelliJIdea2026.1")
    }
}

final class KarabinerAdapterTests: XCTestCase {

    func testParsesSelectedProfileOnly() throws {
        let json = """
        {
          "profiles": [
            {
              "name": "Inactive",
              "selected": false,
              "complex_modifications": {
                "rules": [{
                  "description": "Should be ignored",
                  "manipulators": [{
                    "from": {"key_code": "z", "modifiers": {"mandatory": ["left_command"]}}
                  }]
                }]
              }
            },
            {
              "name": "Default",
              "selected": true,
              "simple_modifications": [
                {"from": {"key_code": "caps_lock"}, "to": [{"key_code": "escape"}]}
              ],
              "complex_modifications": {
                "rules": [{
                  "description": "Hyper key",
                  "manipulators": [{
                    "from": {
                      "key_code": "g",
                      "modifiers": {"mandatory": ["left_command", "left_shift"],
                                    "optional": ["any"]}
                    }
                  }]
                }]
              }
            }
          ]
        }
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("karabiner-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let bindings = try KarabinerAdapter().parse(path: url.path)

        // The inactive profile contributes nothing: it is not live, so reporting it
        // as a claim would be a lie.
        XCTAssertFalse(bindings.contains { $0.label == "Should be ignored" })

        XCTAssertTrue(bindings.contains { $0.label == "Hyper key" })

        // `optional` modifiers merely permit extra keys; only `mandatory` ones are
        // part of the trigger.
        let hyper = bindings.first { $0.label == "Hyper key" }
        XCTAssertEqual(hyper?.combo, KeyCombo(character: "g", modifiers: [.command, .shift]))

        XCTAssertTrue(bindings.contains { $0.detail["kind"] == "simple_modification" })
    }
}

final class GenericPreferenceTests: XCTestCase {

    func testKeyboardShortcutsLibrarySignature() {
        let json = #"{"carbonKeyCode":5,"carbonModifiers":768}"#
        let combo = GenericPreferenceScanner.parseKeyboardShortcuts(json: json)
        // 768 == cmdKey (256) | shiftKey (512)
        XCTAssertEqual(combo, KeyCombo(character: "g", modifiers: [.command, .shift]))
    }

    func testShortcutRecorderSignature() {
        let dictionary: [String: Any] = [
            "keyCode": NSNumber(value: 5),
            "modifierFlags": NSNumber(value: Modifiers([.command, .shift]).cocoaFlags),
        ]
        XCTAssertEqual(
            GenericPreferenceScanner.parseShortcutRecorder(dictionary),
            KeyCombo(character: "g", modifiers: [.command, .shift])
        )
    }

    func testIgnoresBareCombos() {
        let dictionary: [String: Any] = [
            "keyCode": NSNumber(value: 5),
            "modifierFlags": NSNumber(value: 0),
        ]
        XCTAssertNil(GenericPreferenceScanner.parseShortcutRecorder(dictionary))
    }

    func testHumanizesKeyNames() {
        XCTAssertEqual(GenericPreferenceScanner.humanize("globalSearchHotKey"), "Global Search Hot Key")
        XCTAssertEqual(GenericPreferenceScanner.humanize("toggle_window"), "Toggle window")
    }
}

final class ServicesScannerTests: XCTestCase {

    func testParsesServiceKey() {
        let (bundleID, name) = ServicesScanner.parseServiceKey("(com.apple.Finder, Open)")
        XCTAssertEqual(bundleID, "com.apple.Finder")
        XCTAssertEqual(name, "Open")

        let (missing, only) = ServicesScanner.parseServiceKey("Reveal in Finder")
        XCTAssertNil(missing)
        XCTAssertEqual(only, "Reveal in Finder")
    }

    /// Real `pbs.plist` entries carry a bracketed suffix on the identifier, which
    /// used to leak "(null" into the owner name shown in the conflict list.
    func testStripsBracketedSuffixFromServiceIdentifier() {
        let (bundleID, name) = ServicesScanner.parseServiceKey(
            "(org.pqrs.Karabiner-Elements(null), Save Current AEM Form Service - runWorkflowAsService)"
        )
        XCTAssertEqual(bundleID, "org.pqrs.Karabiner-Elements")
        XCTAssertEqual(name, "Save Current AEM Form Service - runWorkflowAsService")
    }

    func testBundleIDDisplayName() {
        XCTAssertEqual(Owner.displayName(forBundleID: "co.podzim.BoltGPT"), "BoltGPT")
        XCTAssertEqual(Owner.displayName(forBundleID: "Shortcat"), "Shortcat")
    }
}
