import Carbon.HIToolbox
import Foundation
import ShortkingKit

/// Carbon always rejects duplicates in a single process. Hold two controls in the
/// sweep helper and have a second instance probe them using the actual sweep path.
enum ProbeCalibration {
    static let checkArgument = "--check-held-keys"
    private static let modifiers: Modifiers = [.command, .control, .shift, .option]
    private static let sharedKey = KeyCombo(keyCode: UInt16(kVK_F18), modifiers: modifiers)
    private static let exclusiveKey = KeyCombo(keyCode: UInt16(kVK_F19), modifiers: modifiers)

    private enum ChildResult: Int32 {
        // Distinct from the helper's normal error, termination and watchdog exits.
        case exclusiveOnly = 10
        case sharedAndExclusive = 11
        case inconclusive = 12
    }

    static func checkHeldKeys() -> Int32 {
        guard CarbonHotKey.probe(exclusiveKey, id: 1).outcome == .claimed else {
            return ChildResult.inconclusive.rawValue
        }
        switch CarbonHotKey.probe(sharedKey, id: 2).outcome {
        case .claimed: return ChildResult.sharedAndExclusive.rawValue
        case .accepted: return ChildResult.exclusiveOnly.rawValue
        default: return ChildResult.inconclusive.rawValue
        }
    }

    static func measure() -> ProbeCoverage {
        // Bundle.main may describe the GUI when this binary lives inside its .app.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0,
              CarbonHotKey.probe(sharedKey, id: 1).outcome == .accepted,
              CarbonHotKey.probe(exclusiveKey, id: 2).outcome == .accepted else { return .unverified }

        let (_, shared) = CarbonHotKey.register(sharedKey, id: 3)
        guard let shared else { return .unverified }
        defer { shared.release() }
        let (_, exclusive) = CarbonHotKey.register(exclusiveKey, id: 4, exclusive: true)
        guard let exclusive else { return .unverified }
        defer { exclusive.release() }

        let observer = Process()
        observer.executableURL = URL(fileURLWithPath: String(cString: path))
        observer.arguments = [checkArgument]
        observer.standardInput = FileHandle.nullDevice
        observer.standardOutput = FileHandle.nullDevice
        observer.standardError = FileHandle.nullDevice
        do { try observer.run() } catch { return .unverified }

        let timeout = DispatchWorkItem {
            if observer.isRunning { observer.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        observer.waitUntilExit()
        timeout.cancel()
        guard observer.terminationReason == .exit else { return .unverified }
        switch ChildResult(rawValue: observer.terminationStatus) {
        case .exclusiveOnly: return .exclusiveOnly
        case .sharedAndExclusive: return .sharedAndExclusive
        default: return .unverified
        }
    }
}
