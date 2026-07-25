import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Attribution by watching what the owner *does*.
///
/// When a hotkey fires, whoever owns it does something observable: it burns CPU, it
/// opens a window, it activates. Sampling those signals across a short window after
/// a press and diffing them names the owner.
///
/// Crude, entirely public API, and — critically — the **only** technique that works
/// against event-tap-based claimants, which register nothing and so have nothing to
/// enumerate and nothing to probe. Cross-referenced against the `CGGetEventTapList`
/// suspect set it usually converges in one or two presses.
public final class SideChannelCorrelator {

    /// One process that reacted to the press.
    public struct Signal: Identifiable, Hashable, Sendable {
        public enum Kind: String, Sendable {
            case cpuSpike
            case newWindow
            case activated

            public var displayName: String {
                switch self {
                case .cpuSpike:  return "CPU spike"
                case .newWindow: return "Opened a window"
                case .activated: return "Became frontmost"
                }
            }
        }

        public var id = UUID()
        public var owner: Owner
        public var kind: Kind
        public var magnitude: Double
        public var isKnownSuspect: Bool
        public var detail: String
    }

    public struct Snapshot {
        var cpuByPID: [Int32: UInt64]
        var windowIDs: Set<Int>
        var frontmostPID: Int32?
        var takenAt: Date
    }

    /// CPU time delta below this is noise, not a reaction.
    private let cpuThresholdNanoseconds: UInt64 = 2_000_000  // 2 ms

    public init() {}

    /// Captures the current side-channel state.
    public func snapshot() -> Snapshot {
        Snapshot(
            cpuByPID: Self.cpuTimes(),
            windowIDs: Self.windowIDs(),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            takenAt: Date()
        )
    }

    /// Diffs two snapshots into ranked signals.
    ///
    /// `suspectPIDs` comes from the event tap list and the binary triage; a process
    /// that is already a known suspect and also spiked is a much stronger signal
    /// than an unrelated process that happened to wake up, and is ranked as such.
    public func correlate(
        before: Snapshot,
        after: Snapshot,
        suspectPIDs: Set<Int32>
    ) -> [Signal] {
        var signals: [Signal] = []

        for (pid, cpuAfter) in after.cpuByPID {
            let cpuBefore = before.cpuByPID[pid] ?? cpuAfter
            guard cpuAfter > cpuBefore else { continue }
            let delta = cpuAfter - cpuBefore
            guard delta >= cpuThresholdNanoseconds else { continue }

            signals.append(
                Signal(
                    owner: ProcessLookup.owner(forPID: pid),
                    kind: .cpuSpike,
                    magnitude: Double(delta) / 1_000_000,
                    isKnownSuspect: suspectPIDs.contains(pid),
                    detail: String(format: "%.1f ms of CPU in the window", Double(delta) / 1_000_000)
                )
            )
        }

        let newWindows = after.windowIDs.subtracting(before.windowIDs)
        if !newWindows.isEmpty {
            for (pid, count) in Self.windowOwners(of: newWindows) {
                signals.append(
                    Signal(
                        owner: ProcessLookup.owner(forPID: pid),
                        kind: .newWindow,
                        magnitude: Double(count) * 10,
                        isKnownSuspect: suspectPIDs.contains(pid),
                        detail: count == 1 ? "Opened a window" : "Opened \(count) windows"
                    )
                )
            }
        }

        if let frontAfter = after.frontmostPID, frontAfter != before.frontmostPID {
            signals.append(
                Signal(
                    owner: ProcessLookup.owner(forPID: frontAfter),
                    kind: .activated,
                    magnitude: 20,
                    isKnownSuspect: suspectPIDs.contains(frontAfter),
                    detail: "Became the frontmost application"
                )
            )
        }

        // Known suspects first, then by how strongly they reacted.
        return signals.sorted { lhs, rhs in
            if lhs.isKnownSuspect != rhs.isKnownSuspect { return lhs.isKnownSuspect }
            return lhs.magnitude > rhs.magnitude
        }
    }

    /// Runs a correlation across a window, calling `press` once the "before"
    /// snapshot is taken.
    public func observe(
        window: TimeInterval = 0.25,
        suspectPIDs: Set<Int32>,
        press: () -> Void
    ) -> [Signal] {
        let before = snapshot()
        press()
        Thread.sleep(forTimeInterval: window)
        let after = snapshot()
        return correlate(before: before, after: after, suspectPIDs: suspectPIDs)
    }

    /// Converts signals into attribution observations for the ledger.
    ///
    /// Side-channel evidence carries the lowest weight of anything Shortking
    /// records, and only the top-ranked signal is recorded at all — a list of
    /// everything that twitched would poison the ledger rather than inform it.
    public static func observations(
        from signals: [Signal],
        combo: KeyCombo
    ) -> [AttributionObservation] {
        guard let best = signals.first, best.isKnownSuspect else { return [] }
        return [
            AttributionObservation(
                comboKey: combo.groupingKey,
                ownerIdentity: best.owner.identity,
                ownerName: best.owner.name,
                kind: .sideChannel,
                ambiguous: signals.filter(\.isKnownSuspect).count > 1
            )
        ]
    }

    // MARK: - Sampling

    /// Total CPU time per process, in nanoseconds.
    static func cpuTimes() -> [Int32: UInt64] {
        var pids = [Int32](repeating: 0, count: 4096)
        let byteCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard byteCount > 0 else { return [:] }
        let count = Int(byteCount) / MemoryLayout<Int32>.size

        var result: [Int32: UInt64] = [:]
        result.reserveCapacity(count)

        for index in 0..<min(count, pids.count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            if let total = cpuTime(forPID: pid) { result[pid] = total }
        }
        return result
    }

    static func cpuTime(forPID pid: Int32) -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard status == 0 else { return nil }
        return usage.ri_user_time &+ usage.ri_system_time
    }

    static func windowIDs() -> Set<Int> {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
    }

    static func windowOwners(of windowIDs: Set<Int>) -> [Int32: Int] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }

        var counts: [Int32: Int] = [:]
        for window in info {
            guard let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  windowIDs.contains(number),
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
                continue
            }
            counts[pid, default: 0] += 1
        }
        return counts
    }
}
