import AppKit
import Darwin
import Foundation

/// Turning pids into something a human can read.
public enum ProcessLookup {

    public static func runningApplication(forPID pid: Int32) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid_t(pid))
    }

    /// A display name for a pid, falling back through the ways macOS will tell you
    /// one. Background daemons have no `NSRunningApplication`, so `ps` is the floor.
    public static func name(forPID pid: Int32) -> String? {
        if let app = runningApplication(forPID: pid) {
            if let name = app.localizedName { return name }
            if let bundleID = app.bundleIdentifier { return bundleID }
        }
        if let output = Shell.run("/bin/ps", arguments: ["-p", "\(pid)", "-o", "comm="]) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return (trimmed as NSString).lastPathComponent
            }
        }
        return nil
    }

    /// An ``Owner`` for a pid, tagged `.unknown` when we could not resolve anything
    /// — because "some process we cannot name" is a legitimate, honest answer.
    public static func owner(forPID pid: Int32) -> Owner {
        if let app = runningApplication(forPID: pid) {
            return Owner(
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)",
                bundleID: app.bundleIdentifier,
                path: app.bundleURL?.path,
                pid: pid,
                kind: app.bundleIdentifier?.hasPrefix("com.apple.") == true ? .system : .application
            )
        }
        return Owner(
            name: name(forPID: pid) ?? "pid \(pid)",
            bundleID: nil,
            path: nil,
            pid: pid,
            kind: .unknown
        )
    }
}

/// Minimal synchronous subprocess helper.
///
/// Used only for things macOS exposes nowhere else: `ioreg` for the secure-input
/// holder and `nm` for static binary triage.
public enum Shell {

    /// How long to wait after SIGTERM before resorting to SIGKILL.
    private static let terminationGrace: TimeInterval = 2

    public static func run(_ launchPath: String, arguments: [String], timeout: TimeInterval = 10) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.platform.error("Failed to launch \(launchPath): \(error.localizedDescription)")
            return nil
        }

        // The watchdog has to be armed *before* the read, not after it.
        //
        // `readDataToEndOfFile()` returns only when the child closes stdout — which
        // is to say, when it exits. The old code did the read first and then polled
        // `process.isRunning` against a deadline, so the deadline could never be
        // reached while the child was still running and the `timeout` parameter was
        // decorative. A wedged `nm` or `ioreg` blocked the caller forever, inside a
        // scan whose own per-source timeout cannot cancel blocking work.
        let terminate = DispatchWorkItem {
            guard process.isRunning else { return }
            Log.platform.warning("Timed out waiting for \(launchPath); terminating")
            process.terminate()
        }
        let forceKill = DispatchWorkItem {
            guard process.isRunning else { return }
            Log.platform.error("\(launchPath) ignored SIGTERM; killing")
            kill(process.processIdentifier, SIGKILL)
        }

        let queue = DispatchQueue.global(qos: .utility)
        queue.asyncAfter(deadline: .now() + timeout, execute: terminate)
        queue.asyncAfter(deadline: .now() + timeout + terminationGrace, execute: forceKill)

        // Read before waiting: a full pipe buffer deadlocks a process that is still
        // writing while we wait for it to exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        terminate.cancel()
        forceKill.cancel()

        return String(data: data, encoding: .utf8)
    }
}
