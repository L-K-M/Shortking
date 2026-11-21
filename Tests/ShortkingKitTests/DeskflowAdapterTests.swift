import Foundation
import XCTest
@testable import ShortkingKit

final class DeskflowAdapterTests: XCTestCase {
    func testDefaultRegistryAttributesServerHotkeysToDeskflow() throws {
        let adapter = try XCTUnwrap(AdapterRegistry.defaultAdapters().first { $0.identifier == "deskflow" })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        section: options
            keystroke(Alt+1) = switchToScreen(local)
            keystroke(Alt+2) = switchToScreen(remote)
        end
        """.write(to: url, atomically: true, encoding: .utf8)
        let bindings = try adapter.parse(path: url.path)
        XCTAssertEqual(adapter.ownerBundleID, "org.deskflow.deskflow")
        XCTAssertEqual(adapter.layer, .windowServer)
        XCTAssertEqual(bindings.map(\.combo), ["1", "2"].map { KeyCombo(character: $0, modifiers: .command) })
        XCTAssertEqual(bindings.map(\.line), [2, 3])
        XCTAssertEqual(bindings.map(\.label), ["switchToScreen(local)", "switchToScreen(remote)"])
    }

    func testSelectedFileWinsOverInternalSettingsAndInactiveBindings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("Deskflow.conf")
        let external = directory.appendingPathComponent("external layout.conf")
        let generated = directory.appendingPathComponent("deskflow-server.conf")
        try """
        section: options
            keystroke(Alt+1) = switchToScreen(old)
        end
        """.write(to: generated, atomically: true, encoding: .utf8)
        try """
        section: links
            keystroke(Alt+3) = ignored()
        end

        section: options
            # keystroke(Alt+1) = ignored()
            keystroke(Control+Shift+1) = switchToScreen(local)
            keystroke(Control+Shift+2) = switchToScreen(remote) # comment
            keystroke(Super+Control+F5) = keystroke(Alt+3)
            keystroke(Unknown+Alt+4) = ignored()
            mousepress(2) = keystroke(Alt+5)
        end
        """.write(to: external, atomically: true, encoding: .utf8)
        let preferences = """
        [internalConfig]
        hotkeys\\1\\keys\\size=2
        [server]
        externalConfig=true
        externalConfigFile="\(external.path)"
        """
        try preferences.write(to: settings, atomically: true, encoding: .utf8)

        var arguments = [["/Applications/Deskflow.app/Contents/MacOS/deskflow-core", "server"]]
        let adapter = DeskflowAdapter(defaultSettings: { settings.path }, coreArguments: { arguments })
        let registry = AdapterRegistry(adapters: [adapter])
        let context = ScanContext(runningApps: [], installedApps: [], options: .default)
        XCTAssertEqual(adapter.detectedPaths(), [external.path])
        let claims = try await registry.scan(context: context)
        XCTAssertEqual(claims.map(\.combo), [
            KeyCombo(character: "1", modifiers: [.control, .shift]),
            KeyCombo(character: "2", modifiers: [.control, .shift]),
            try XCTUnwrap(KeyCombo(token: "F5", modifiers: [.option, .control]))
        ])
        XCTAssertTrue(claims.allSatisfy(\.enabled))
        XCTAssertEqual(claims[1].label, "switchToScreen(remote)")
        XCTAssertEqual(claims[1].evidence.first?.detail["line"], "8")
        XCTAssertEqual(claims[1].evidence.first?.detail["path"], external.path)

        for inactive in [[], [["deskflow-core", "client"]]] {
            arguments = inactive
            let inactiveClaims = try await registry.scan(context: context)
            XCTAssertEqual(inactiveClaims.count, claims.count)
            XCTAssertFalse(inactiveClaims.contains(where: \.enabled))
        }

        try preferences.replacingOccurrences(of: "externalConfig=true", with: "externalConfig=false")
            .write(to: settings, atomically: true, encoding: .utf8)
        arguments = [["deskflow-core", "server"]]
        XCTAssertEqual(adapter.detectedPaths(), [generated.path])
        let internalClaims = try await registry.scan(context: context)
        XCTAssertEqual(internalClaims.map(\.combo), [KeyCombo(character: "1", modifiers: .command)])
        XCTAssertTrue(internalClaims.allSatisfy(\.enabled))

        try preferences.replacingOccurrences(of: external.path, with: external.path + ".missing")
            .write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertEqual(adapter.detectedPaths(), [])

        // A device or pipe selected as a config must never block a scan.
        try preferences.replacingOccurrences(of: external.path, with: "/dev/null")
            .write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertEqual(adapter.detectedPaths(), [])
    }

    func testDeskflowKeyNamesAndKeypadAreNotGenericMacAliases() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let triggers = ["CONTROL+hOmE", "Alt+BackSpace", "Alt+Delete", "Alt+KP_1",
                        "Alt+1", "Ctrl+2", "Cmd+2", "Alt+keypad1", "Alt+esc", "Alt+pgdn"]
        let lines = triggers.map { "keystroke(\($0)) = switchToNextScreen()" }
        try (["section: options"] + lines + ["end"]).joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let adapter = DeskflowAdapter(defaultSettings: { "" }, coreArguments: { [] })
        let bindings = try adapter.parse(path: file.path)
        XCTAssertEqual(bindings.map(\.combo.keyCode), [0x73, 0x33, 0x75, 0x53, 0x12])
        XCTAssertEqual(bindings.map(\.combo.modifiers), [.control, .command, .command, .command, .command])
    }

    func testCoreWithExplicitSettingsSelectsItsOwnConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("other settings.conf")
        let generated = directory.appendingPathComponent("deskflow-server.conf")
        try "[server]\nexternalConfig=false".write(to: settings, atomically: true, encoding: .utf8)
        try "section: options\n keystroke(Alt+1) = switchToScreen(test)\nend"
            .write(to: generated, atomically: true, encoding: .utf8)
        let adapter = DeskflowAdapter(defaultSettings: { directory.appendingPathComponent("missing.conf").path },
                                     coreArguments: { [["deskflow-core", "server", "--settings", settings.path]] })
        XCTAssertEqual(adapter.detectedPaths(), [generated.path])
        XCTAssertEqual(try adapter.parse(path: generated.path).first?.enabled, true)
    }
}
