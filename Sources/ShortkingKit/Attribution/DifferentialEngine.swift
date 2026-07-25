import AppKit
import Foundation

/// Differential attribution across app launch and quit.
///
/// Probing tells you *that* a combination is taken, not *who* took it. Process
/// lifecycle closes the gap: a combination that becomes free the moment Raycast
/// quits belongs to Raycast, and one that becomes claimed the moment Raycast
/// launches does too. Repeat across ordinary daily use and the WindowServer layer
/// attributes itself, using nothing but public API.
///
/// Ambiguity is handled honestly rather than optimistically: if two apps changed
/// state inside the observation window, the observation is recorded against both at
/// half weight and flagged `ambiguous`, instead of being credited to whichever
/// notification happened to arrive first.
@MainActor
public final class DifferentialEngine {

    /// How long to wait after a launch/quit before re-probing.
    ///
    /// Apps register hotkeys lazily — on window open, on first use — so probing the
    /// instant a launch notification arrives would miss them and generate a false
    /// "unchanged" observation.
    public var settleDelay: TimeInterval = 1.5

    /// Transitions inside this window of each other are treated as simultaneous, and
    /// any observation spanning them is marked ambiguous.
    public var ambiguityWindow: TimeInterval = 3.0

    public private(set) var isRunning = false

    private let store: AttributionStore
    private let runner: ProbeRunner
    private var baseline: Set<KeyCombo> = []
    private var watchedCombos: [KeyCombo] = []
    private var observers: [NSObjectProtocol] = []
    private var pendingWork: Task<Void, Never>?
    private var recentTransitions: [(owner: Owner, at: Date)] = []

    /// Called whenever new attributions land, so the UI can refresh.
    public var onAttributionChanged: (() -> Void)?

    public init(store: AttributionStore, runner: ProbeRunner = ProbeRunner()) {
        self.store = store
        self.runner = runner
    }

    // MARK: - Lifecycle

    /// Starts observing, seeded with the claimed set from the last full sweep.
    ///
    /// Only the claimed set and its immediate neighbourhood are re-probed on each
    /// transition — a fraction of a full sweep's cost, and all the diff needs.
    public func start(baseline report: ProbeReport) {
        guard !isRunning else { return }
        guard report.probingVerified else {
            Log.attribution.warning("Differential learning disabled: probing is unreliable here")
            return
        }

        self.baseline = report.claimedCombos
        // Watch the claimed set plus everything else we swept, so a combination that
        // becomes *newly* claimed is visible too.
        self.watchedCombos = report.results.map(\.combo)
        isRunning = true

        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated { self?.handle(notification: notification) }
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated { self?.handle(notification: notification) }
            },
        ]

        Log.attribution.info("Differential learning started with \(self.baseline.count) claimed combos")
    }

    public func stop() {
        guard isRunning else { return }
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
        pendingWork?.cancel()
        pendingWork = nil
        isRunning = false
    }

    // MARK: - Transitions

    private func handle(notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        // Ignore ourselves and our own helper — our probe registrations would
        // otherwise look like somebody else's hotkeys appearing and vanishing.
        let ourBundleID = Bundle.main.bundleIdentifier
        if let bundleID = app.bundleIdentifier, bundleID == ourBundleID { return }

        let owner = Owner(
            name: app.localizedName ?? app.bundleIdentifier ?? "Unknown app",
            bundleID: app.bundleIdentifier,
            path: app.bundleURL?.path,
            pid: app.processIdentifier,
            kind: .application
        )

        let now = Date()
        recentTransitions.append((owner: owner, at: now))
        recentTransitions.removeAll { now.timeIntervalSince($0.at) > ambiguityWindow * 2 }

        // Debounce: collapse a burst of transitions into a single re-probe.
        pendingWork?.cancel()
        pendingWork = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.settleDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.reprobeAndDiff()
        }
    }

    private func reprobeAndDiff() async {
        guard !watchedCombos.isEmpty else { return }

        let report: ProbeReport
        do {
            report = try await runner.sweep(combos: watchedCombos)
        } catch {
            Log.attribution.error("Differential re-probe failed: \(error.localizedDescription)")
            return
        }
        guard report.probingVerified else { return }

        let nowClaimed = report.claimedCombos
        let freed = baseline.subtracting(nowClaimed)
        let newlyClaimed = nowClaimed.subtracting(baseline)
        baseline = nowClaimed

        guard !freed.isEmpty || !newlyClaimed.isEmpty else { return }

        let cutoff = Date().addingTimeInterval(-(settleDelay + ambiguityWindow))
        let candidates = recentTransitions.filter { $0.at >= cutoff }
        guard !candidates.isEmpty else { return }

        // More than one app moved inside the window: we genuinely cannot tell which
        // one owns the combination, so every candidate gets a half-weight, flagged
        // observation rather than one of them getting a confident wrong answer.
        let ambiguous = Set(candidates.map(\.owner.identity)).count > 1

        var observations: [AttributionObservation] = []
        for candidate in candidates {
            for combo in freed {
                observations.append(
                    AttributionObservation(
                        comboKey: combo.groupingKey,
                        ownerIdentity: candidate.owner.identity,
                        ownerName: candidate.owner.name,
                        kind: .freedOnQuit,
                        ambiguous: ambiguous
                    )
                )
            }
            for combo in newlyClaimed {
                observations.append(
                    AttributionObservation(
                        comboKey: combo.groupingKey,
                        ownerIdentity: candidate.owner.identity,
                        ownerName: candidate.owner.name,
                        kind: .claimedOnLaunch,
                        ambiguous: ambiguous
                    )
                )
            }
        }

        store.record(observations)
        recentTransitions.removeAll()
        onAttributionChanged?()
    }

    // MARK: - Guided identification

    /// A step in the "identify owner" flow.
    public struct IdentificationStep: Sendable {
        public var candidates: [Owner]
        public var instruction: String
        public var remainingRestarts: Int
    }

    /// Plans the binary search for a combination's owner.
    ///
    /// Binary search, not a linear scan: partition the suspects, ask the user to
    /// quit half, re-probe, recurse. log₂(n) restarts instead of n.
    ///
    /// Note that suspending a process does **not** work as a substitute — WindowServer
    /// registrations are held by the connection, not the running thread, so `SIGSTOP`
    /// releases nothing. Actual termination is required, which is why this flow asks
    /// the user rather than doing it silently.
    public static func planIdentification(
        combo: KeyCombo,
        suspects: [Owner]
    ) -> IdentificationStep {
        let half = max(1, suspects.count / 2)
        let toQuit = Array(suspects.prefix(half))
        let restarts = suspects.isEmpty ? 0 : Int(ceil(log2(Double(max(suspects.count, 1)))))

        let names = toQuit.map(\.name).joined(separator: ", ")
        return IdentificationStep(
            candidates: suspects,
            instruction: suspects.isEmpty
                ? "No running application imports the symbols needed to register a global hotkey, "
                    + "so the owner of \(combo.displayString) is not currently running."
                : "Quit \(names), then continue. Shortking will re-probe \(combo.displayString) and "
                    + "narrow the search.",
            remainingRestarts: restarts
        )
    }
}
