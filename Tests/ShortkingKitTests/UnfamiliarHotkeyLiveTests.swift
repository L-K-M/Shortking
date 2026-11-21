import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ShortkingKit

/// Opt in on a logged-in Mac: SHORTKING_LIVE_HOTKEY_TEST=1 swift test --filter UnfamiliarHotkeyLiveTests
@MainActor
final class UnfamiliarHotkeyLiveTests: XCTestCase {
    func testOnlyCommandOneIdentifiesTheUnfamiliarHelper() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHORTKING_LIVE_HOTKEY_TEST"] == "1",
                          "Opt-in test posts two shortcuts in the current macOS session.")
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: scratch) }
        let identifier = "org.example.hotkey-witness." + UUID().uuidString.lowercased()
        let bundle = try buildWitness(in: scratch, identifier: identifier)
        let executable = try XCTUnwrap(bundle.executableURL)
        let receipts = scratch.appendingPathComponent("receipts")
        try Data().write(to: receipts)
        let output = try FileHandle(forWritingTo: receipts)
        defer { try? output.close() }
        let helper = Process()
        helper.executableURL = executable
        helper.standardOutput = output
        try helper.run()
        defer {
            if helper.isRunning { helper.terminate() }
            helper.waitUntilExit()
        }

        func witnessLines() -> [Substring] {
            ((try? String(contentsOf: receipts, encoding: .utf8)) ?? "").split(separator: "\n")
        }
        try await waitFor("helper to register both shortcuts", timeout: 20) {
            !helper.isRunning || witnessLines().first == Substring("ready \(helper.processIdentifier)")
        }
        guard helper.isRunning else { return XCTFail("The hotkey helper exited with status \(helper.terminationStatus).") }

        var running: RunningApp?
        try await waitFor("Launch Services to list the helper") {
            running = ScanContext.capture(options: ScanOptions(includeGenericPreferences: false))
                .runningApps.first { $0.pid == helper.processIdentifier && $0.bundleID == identifier }
            return running != nil
        }
        let candidate = try XCTUnwrap(running)
        // This is a background app, so its import of RegisterEventHotKey must qualify
        // it for capture. No shortcut configuration or expected owner is seeded.
        XCTAssertFalse(candidate.isActive)
        let installed = InstalledApp(name: candidate.name, bundleID: candidate.bundleID,
                                    bundlePath: bundle.bundlePath, executablePath: executable.path, version: nil)
        let context = ScanContext(runningApps: [candidate], installedApps: [installed], options: .default)
        let claims = try await BinaryTriage(cache: TriageCache(persistent: false)).scan(context: context)
        guard claims.contains(where: { $0.status == .capability && $0.owner?.bundleID == identifier }) else {
            return XCTFail("Binary triage missed the unfamiliar background helper.")
        }
        guard CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else {
            return XCTFail("The helper registered both shortcuts and was discovered by binary triage. "
                           + "Live verification requires Input Monitoring and Accessibility for the test host.")
        }

        let store = AttributionStore(persistent: false)
        let detective = DetectiveSession(store: store)
        let target = KeyCombo(keyCode: UInt16(kVK_ANSI_1), modifiers: .command)
        detective.investigate(combo: target, knownClaims: [], probeReport: nil)
        detective.startCapture(eventTaps: [], capabilityClaims: claims, runningApps: context.runningApps)
        defer { detective.stopCapture() }
        guard detective.isCapturing, detective.capturedProcessCount == 1 else {
            return XCTFail("Could not attach to the registered helper: \(detective.lastError ?? "no recipient tap").")
        }

        func liveOwners() -> [String] {
            store.observations.filter { $0.kind == .liveCapture && $0.comboKey == target.groupingKey }
                .map(\.ownerIdentity)
        }
        func namedCount() -> Int { detective.findings.filter { $0.kind == .named }.count }

        // Confirm each independent receipt before checking the detector. An event
        // that never reached the helper cannot make a negative control pass.
        for (index, digit) in [2, 1, 2, 1].enumerated() {
            try postCommandDigit(digit)
            try await waitFor("Carbon receipt for press \(index + 1), Cmd-\(digit)") {
                let lines = witnessLines()
                return lines.count > index + 1 && lines[index + 1] == Substring("pressed \(digit)")
            }
            let expected = (index + 1) / 2
            if digit == 1 {
                try await waitFor("named delivery for Cmd-1") { namedCount() >= expected }
            }
            // Allow queued callbacks, including an incorrect attribution, to run.
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertEqual(namedCount(), expected, "Cmd-\(digit) at step \(index + 1)")
            XCTAssertEqual(liveOwners(), Array(repeating: identifier, count: expected))
            print("Hotkey Witness received Cmd-\(digit). Named findings: \(namedCount()), live owners: \(liveOwners()).")
        }
    }

    private func postCommandDigit(_ digit: Int) throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let key = CGKeyCode(digit == 1 ? kVK_ANSI_1 : kVK_ANSI_2)
        for down in [true, false] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down))
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    private func waitFor(_ label: String, timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NSError(domain: "HotkeyLiveTest", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(label)."])
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func buildWitness(in scratch: URL, identifier: String) throws -> Bundle {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HotkeyWitness.m")
        let app = scratch.appendingPathComponent("Hotkey Witness.app")
        let contents = app.appendingPathComponent("Contents")
        let binaries = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "Hotkey Witness",
                                   "CFBundleExecutable": "HotkeyWitness", "CFBundlePackageType": "APPL",
                                   "CFBundleVersion": "1", "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", "-fobjc-arc", source.path, "-framework", "AppKit", "-framework", "Carbon",
                              "-o", binaries.appendingPathComponent("HotkeyWitness").path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, "could not build the helper")
        return try XCTUnwrap(Bundle(url: app))
    }
}
