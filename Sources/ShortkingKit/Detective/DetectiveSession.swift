import AppKit
import Combine
import Foundation

/// The investigation of a single combination — "I pressed ⌘⇧G and the wrong thing
/// happened. Who ate it?"
///
/// Three independent techniques feed one verdict panel, ordered by how decisive
/// they are:
///
/// 1. **Live capture** — the per-pid `systemDefined` sniffer names the receiving
///    process outright, plus the sandwich taps classify *how* the key was consumed.
/// 2. **Blackout** — separates "a WindowServer hotkey ate it" from everything else
///    in one press.
/// 3. **Identify by restart** — differential binary search, when nothing live works.
///
/// Side-channel correlation runs underneath all of them, because it is the only
/// thing that sees event-tap claimants at all.
@MainActor
public final class DetectiveSession: ObservableObject {

    public struct Finding: Identifiable, Sendable {
        public enum Kind: String, Sendable {
            case named
            case classification
            case sideChannel
            case blackout
            case inventory
            case note

            public var displayName: String {
                switch self {
                case .named:          return "Owner identified"
                case .classification: return "How it was consumed"
                case .sideChannel:    return "Side-channel signal"
                case .blackout:       return "Blackout result"
                case .inventory:      return "From the inventory"
                case .note:           return "Note"
                }
            }
        }

        public var id = UUID()
        public var kind: Kind
        public var headline: String
        public var detail: String
        public var confidence: Double
        public var at: Date = Date()
    }

    // MARK: - State

    @Published public private(set) var combo: KeyCombo?
    @Published public private(set) var findings: [Finding] = []
    @Published public private(set) var isCapturing = false
    @Published public private(set) var capturedProcessCount = 0
    @Published public private(set) var blackoutActive = false
    @Published public private(set) var blackoutRemaining = 0
    @Published public private(set) var lastError: String?

    private let sniffer = SystemDefinedSniffer()
    private let sandwich = SandwichTaps()
    private let sideChannel = SideChannelCorrelator()
    public let blackout = BlackoutController()

    private let store: AttributionStore
    private var captureTimeout: Task<Void, Never>?
    private var blackoutTicker: Timer?
    private var suspectPIDs: Set<Int32> = []
    private var beforeSnapshot: SideChannelCorrelator.Snapshot?

    /// How long a live capture stays armed before tearing itself down.
    public var captureDuration: TimeInterval = 30

    public init(store: AttributionStore) {
        self.store = store
        // `onEnd` fires from `BlackoutController.restore()`, which is already on the
        // main actor — the assumption is checked, not waved through.
        blackout.onEnd = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.blackoutActive = false
                self.blackoutRemaining = 0
                self.blackoutTicker?.invalidate()
                self.blackoutTicker = nil
            }
        }
    }

    deinit {
        sniffer.stop()
        sandwich.stop()
    }

    // MARK: - Setup

    /// Points the session at a combination and seeds it with what the inventory
    /// already knows, so the user starts from evidence rather than a blank screen.
    public func investigate(combo: KeyCombo, knownClaims: [Claim], probeReport: ProbeReport?) {
        reset()
        self.combo = combo

        for claim in knownClaims where claim.combo == combo {
            findings.append(
                Finding(
                    kind: .inventory,
                    headline: "\(claim.ownerName) — \(claim.label ?? "no label")",
                    detail: "\(claim.layer.displayName) layer, \(claim.status.displayName). "
                        + (claim.evidence.first?.summary ?? ""),
                    confidence: claim.confidence
                )
            )
        }

        if let outcome = probeReport?.outcome(for: combo) {
            switch outcome {
            case .claimed:
                findings.append(
                    Finding(
                        kind: .inventory,
                        headline: "Probe: this combination is already claimed",
                        detail: "Registering it was refused, so something holds it at the "
                            + "WindowServer layer. If nothing above names an owner, that owner is "
                            + "not visible in any config file or menu bar.",
                        confidence: 0.5
                    )
                )
            case .restricted:
                findings.append(
                    Finding(
                        kind: .note,
                        headline: "This combination cannot be registered by any app",
                        detail: "Since macOS 15, shortcuts whose only modifiers are ⌥ or ⌥⇧ are "
                            + "refused system-wide as an anti-keylogging measure. This is not a "
                            + "conflict — no app can claim it, including the one you expected to.",
                        confidence: 1.0
                    )
                )
            case .free:
                findings.append(
                    Finding(
                        kind: .inventory,
                        headline: "Probe: nobody holds this at the WindowServer layer",
                        detail: "The combination registers cleanly, so whatever consumed your key "
                            + "press is an event tap, a virtual HID remap, or the frontmost app "
                            + "itself.",
                        confidence: 0.5
                    )
                )
            case .unknown:
                break
            }
        }
    }

    public func reset() {
        stopCapture()
        combo = nil
        findings = []
        lastError = nil
    }

    // MARK: - Live capture

    /// Arms the sniffer and the sandwich taps, then waits for the user to press.
    public func startCapture(
        eventTaps: [EventTapInfo],
        capabilityClaims: [Claim],
        runningApps: [RunningApp]
    ) {
        guard !isCapturing else { return }
        lastError = nil

        let suspects = SystemDefinedSniffer.suspects(
            eventTaps: eventTaps,
            capabilityClaims: capabilityClaims,
            runningApps: runningApps
        )
        suspectPIDs = Set(suspects.map(\.pid))

        // Both callbacks are delivered on the main queue by their sources.
        let attached = sniffer.start(apps: suspects) { [weak self] delivery in
            MainActor.assumeIsolated { self?.record(delivery: delivery) }
        }

        let sandwichStarted = sandwich.start { [weak self] observation in
            MainActor.assumeIsolated { self?.record(observation: observation) }
        }

        guard !attached.isEmpty || sandwichStarted else {
            lastError = "Could not install any event taps. Grant Input Monitoring in "
                + "System Settings ▸ Privacy & Security, then try again."
            return
        }

        capturedProcessCount = attached.count
        isCapturing = true
        beforeSnapshot = sideChannel.snapshot()

        captureTimeout?.cancel()
        captureTimeout = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.captureDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.stopCapture()
        }

        findings.append(
            Finding(
                kind: .note,
                headline: "Listening on " + Plural.count(attached.count, "process"),
                detail: "Press \(combo?.displayString ?? "the shortcut") now. Capture stops "
                    + "automatically after \(Int(captureDuration)) seconds.",
                confidence: 1.0
            )
        )
    }

    public func stopCapture() {
        captureTimeout?.cancel()
        captureTimeout = nil
        sniffer.stop()
        sandwich.stop()
        isCapturing = false
        capturedProcessCount = 0
    }

    private func record(delivery: SystemDefinedSniffer.Delivery) {
        guard delivery.isKeyDown else { return }
        guard let combo else { return }

        findings.insert(
            Finding(
                kind: .named,
                headline: "\(delivery.ownerName) received the hotkey",
                detail: "WindowServer delivered a system-defined event (subtype 6) to "
                    + "\(delivery.ownerName) (pid \(delivery.pid)) with hotkey identifier "
                    + String(format: "0x%llX", UInt64(bitPattern: Int64(delivery.hotKeyID)))
                    + ". That identifier is the registration's address inside that process, so "
                    + "repeated presses of the same shortcut will show the same value.",
                confidence: 0.95
            ),
            at: 0
        )

        // A live capture is near-proof, and weighted accordingly in the ledger.
        store.record([
            AttributionObservation(
                comboKey: combo.groupingKey,
                ownerIdentity: delivery.bundleID ?? delivery.ownerName,
                ownerName: delivery.ownerName,
                kind: .liveCapture
            )
        ])

        runSideChannel()
    }

    private func record(observation: SandwichTaps.Observation) {
        guard let combo, observation.combo == combo else { return }

        findings.append(
            Finding(
                kind: .classification,
                headline: observation.verdict.displayName,
                detail: observation.explanation,
                confidence: 0.8
            )
        )

        runSideChannel()
    }

    private func runSideChannel() {
        guard let combo, let before = beforeSnapshot else { return }
        let after = sideChannel.snapshot()
        let signals = sideChannel.correlate(before: before, after: after, suspectPIDs: suspectPIDs)
        beforeSnapshot = after

        for signal in signals.prefix(3) {
            findings.append(
                Finding(
                    kind: .sideChannel,
                    headline: "\(signal.owner.name) — \(signal.kind.displayName)",
                    detail: signal.detail
                        + (signal.isKnownSuspect
                            ? " This process also has an event tap installed, which makes it a "
                                + "strong candidate even though it registers nothing we can read."
                            : ""),
                    confidence: signal.isKnownSuspect ? 0.4 : 0.2
                )
            )
        }

        store.record(SideChannelCorrelator.observations(from: signals, combo: combo))
    }

    // MARK: - Blackout

    public func startBlackout(duration: TimeInterval = 10) {
        do {
            try blackout.begin(duration: duration)
            blackoutActive = true
            blackoutRemaining = blackout.remainingSeconds
            blackoutTicker?.invalidate()
            blackoutTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.blackoutRemaining = self.blackout.remainingSeconds
                }
            }
            if let blackoutTicker { RunLoop.main.add(blackoutTicker, forMode: .common) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func endBlackout() {
        blackout.restore()
    }

    /// Records what the user reported after the blackout test.
    public func reportBlackoutResult(shortcutWorked: Bool) {
        guard let combo else { return }
        findings.append(
            Finding(
                kind: .blackout,
                headline: shortcutWorked
                    ? "A WindowServer hotkey was consuming it"
                    : "No WindowServer hotkey is responsible",
                detail: BlackoutController.interpret(
                    shortcutWorkedDuringBlackout: shortcutWorked,
                    combo: combo
                ),
                confidence: 0.85
            )
        )
    }

    // MARK: - Verdict

    /// The single best answer so far, or `nil` when nothing conclusive has landed.
    public var verdict: Finding? {
        findings
            .filter { $0.kind == .named || $0.kind == .inventory }
            .max { $0.confidence < $1.confidence }
    }
}
