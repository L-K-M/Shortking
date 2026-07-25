import Foundation

/// Drives the probe sweep in a short-lived helper process.
///
/// This indirection is a correctness requirement, not tidiness. A successful
/// `RegisterEventHotKey` that is never released hijacks that combination for the
/// lifetime of the registering process. Running the sweep in a helper that exits
/// within a couple of seconds means even a hard crash mid-sweep is cleaned up by
/// the OS — the user's keyboard cannot be left in a broken state by a bug in
/// Shortking.
public final class ProbeRunner: @unchecked Sendable {

    public enum ProbeUnavailable: LocalizedError {
        case helperNotFound
        case helperFailed(status: Int32, stderr: String)
        case timedOut
        case malformedOutput(String)

        public var errorDescription: String? {
            switch self {
            case .helperNotFound:
                return "The shortking-probe helper is missing from the app bundle."
            case .helperFailed(let status, let stderr):
                return "The probe helper exited with status \(status). \(stderr)"
            case .timedOut:
                return "The probe helper did not finish in time."
            case .malformedOutput(let detail):
                return "The probe helper produced output Shortking could not read: \(detail)"
            }
        }
    }

    public static let helperName = "shortking-probe"

    private let helperURL: URL?

    public init(helperURL: URL? = ProbeRunner.locateHelper()) {
        self.helperURL = helperURL
    }

    public var isAvailable: Bool { helperURL != nil }

    /// Finds the helper next to the app binary.
    ///
    /// `forAuxiliaryExecutable:` is the bundled case; the sibling-path fallback is
    /// what makes `swift run` work during development.
    public static func locateHelper() -> URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: helperName) {
            return url
        }
        if let executable = Bundle.main.executableURL {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent(helperName)
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        let cwdSibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent(helperName)
        if FileManager.default.isExecutableFile(atPath: cwdSibling.path) { return cwdSibling }
        return nil
    }

    /// Runs a full sweep at the given breadth.
    public func sweep(breadth: ProbeBreadth, timeout: TimeInterval = 60) async throws -> ProbeReport {
        try await run(arguments: ["--breadth", breadth.rawValue], timeout: timeout)
    }

    /// Re-probes only a specific set of combinations.
    ///
    /// The differential engine uses this after every app launch/quit: probing the
    /// currently-claimed subset is a fraction of the cost of a full sweep, and it is
    /// all the diff needs.
    public func sweep(combos: [KeyCombo], timeout: TimeInterval = 30) async throws -> ProbeReport {
        guard !combos.isEmpty else {
            return ProbeReport(
                results: [],
                breadth: .common,
                startedAt: Date(),
                finishedAt: Date(),
                probingVerified: true
            )
        }
        let encoded = combos.compactMap { combo -> String? in
            guard let keyCode = combo.keyCode else { return nil }
            return "\(keyCode):\(combo.modifiers.rawValue)"
        }
        return try await run(arguments: ["--combos", encoded.joined(separator: ",")], timeout: timeout)
    }

    private func run(arguments: [String], timeout: TimeInterval) async throws -> ProbeReport {
        guard let helperURL else { throw ProbeUnavailable.helperNotFound }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let report = try Self.execute(
                        helperURL: helperURL,
                        arguments: arguments,
                        timeout: timeout
                    )
                    continuation.resume(returning: report)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func execute(
        helperURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProbeReport {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Watchdog: if the helper wedges, kill it. It holds no registrations
        // between probes, but a hung helper is still a hung scan.
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                Log.probe.error("Probe helper timed out; terminating")
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Both pipes have to be drained *concurrently*. Reading stdout to EOF and
        // only then reading stderr means that a helper which fills stderr's 64 KB
        // buffer blocks writing while we block reading, and neither side moves
        // again. The helper is quiet on stderr today — but `--help`, the watchdog
        // message and any encoding failure all write there, and a pipe-ordering
        // deadlock is exactly the kind of bug that only shows up in the field.
        let errorBox = DataBox()
        let errorHandle = stderr.fileHandleForReading
        let errorQueue = DispatchQueue(label: "com.shortking.probe.stderr")
        errorQueue.async { errorBox.data = errorHandle.readDataToEndOfFile() }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        // Barrier: guarantees the stderr read finished and its write is visible.
        errorQueue.sync {}
        let errorData = errorBox.data

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            if process.terminationReason == .uncaughtSignal {
                throw ProbeUnavailable.timedOut
            }
            throw ProbeUnavailable.helperFailed(status: process.terminationStatus, stderr: message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ProbeReport.self, from: outputData)
        } catch {
            throw ProbeUnavailable.malformedOutput(error.localizedDescription)
        }
    }

    /// A reference box, so the two pipe reads can run concurrently without a
    /// captured `var` — which a `@Sendable` dispatch block may not mutate.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Decodes the `keyCode:modifierRawValue` list the helper accepts.
    public static func decodeCombos(_ encoded: String) -> [KeyCombo] {
        encoded.split(separator: ",").compactMap { token in
            let parts = token.split(separator: ":")
            guard parts.count == 2,
                  let keyCode = UInt16(parts[0]),
                  let modifierRaw = UInt8(parts[1]) else { return nil }
            return KeyCombo(keyCode: keyCode, modifiers: Modifiers(rawValue: modifierRaw))
        }
    }
}
