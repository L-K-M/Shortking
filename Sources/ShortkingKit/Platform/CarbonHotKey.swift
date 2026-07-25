import Carbon.HIToolbox
import Foundation

/// A thin, safe wrapper around `RegisterEventHotKey`, used for negative-space
/// probing: you cannot ask macOS what is registered, but you can ask "may I have
/// this?" — and the answer is no precisely when someone else holds it.
public enum CarbonHotKey {

    /// The outcome of asking for one combination.
    public enum ProbeOutcome: String, Codable, Hashable, Sendable {
        /// Registration succeeded (and was immediately released) — nobody holds it.
        case free
        /// Registration was refused because someone already holds it.
        case claimed
        /// Refused by the macOS 15+ ⌥-only / ⌥⇧-only hardening. **Not** a conflict.
        case restricted
        /// Refused for a reason we do not recognise. Recorded raw, never guessed at.
        case unknown

        public var displayName: String {
            switch self {
            case .free:       return "Available"
            case .claimed:    return "Claimed"
            case .restricted: return "Restricted by macOS"
            case .unknown:    return "Unknown"
            }
        }
    }

    /// `eventHotKeyExistsErr` — the combination is genuinely taken.
    public static let hotKeyExistsErr: OSStatus = -9878
    /// `eventInternalErr` — returned for ⌥-only and ⌥⇧-only combos since macOS 15.
    public static let internalErr: OSStatus = -9868

    public struct ProbeResult: Codable, Hashable, Sendable {
        public var combo: KeyCombo
        public var outcome: ProbeOutcome
        public var status: OSStatus

        public init(combo: KeyCombo, outcome: ProbeOutcome, status: OSStatus) {
            self.combo = combo
            self.outcome = outcome
            self.status = status
        }
    }

    /// Interprets an `OSStatus` from `RegisterEventHotKey`.
    ///
    /// The ⌥-hardening check is combination-aware on purpose: `-9868` only means
    /// "restricted" for the modifier sets Apple actually hardened. Anywhere else it
    /// is an unknown failure and is reported as such rather than being swept up.
    public static func classify(status: OSStatus, combo: KeyCombo) -> ProbeOutcome {
        if status == noErr { return .free }
        if status == hotKeyExistsErr { return .claimed }
        if status == internalErr && combo.isRestrictedByOptionHardening { return .restricted }
        return .unknown
    }

    /// A live registration. Releasing is idempotent, and `deinit` releases too, so a
    /// dropped handle cannot leak a hijacked combination.
    public final class Registration {
        private var ref: EventHotKeyRef?
        public let combo: KeyCombo

        init(ref: EventHotKeyRef?, combo: KeyCombo) {
            self.ref = ref
            self.combo = combo
        }

        public func release() {
            if let ref {
                UnregisterEventHotKey(ref)
                self.ref = nil
            }
        }

        deinit { release() }
    }

    private static let signature: OSType = 0x534B_474E  // 'SKGN' — Shortking

    /// Attempts to register `combo`, returning the raw status and, on success, a
    /// handle the caller must release.
    ///
    /// Callers that only want to know availability should use ``probe(_:id:)``,
    /// which releases in a `defer` and cannot leak.
    public static func register(_ combo: KeyCombo, id: UInt32) -> (OSStatus, Registration?) {
        guard let keyCode = combo.keyCode else {
            return (paramErr, nil)
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            combo.modifiers.carbonMask,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return (status, nil) }
        return (status, Registration(ref: ref, combo: combo))
    }

    /// Asks whether `combo` is available, releasing any successful registration
    /// immediately.
    ///
    /// The release is in a `defer` so that no path — including a thrown error or an
    /// early return added later — can leave the combination held. The probe sweep
    /// additionally runs in a short-lived helper process so that even a crash here
    /// is cleaned up by the OS.
    public static func probe(_ combo: KeyCombo, id: UInt32) -> ProbeResult {
        let (status, registration) = register(combo, id: id)
        defer { registration?.release() }
        return ProbeResult(
            combo: combo,
            outcome: classify(status: status, combo: combo),
            status: status
        )
    }

    /// Experiment A from the research document, as a runtime self-test.
    ///
    /// Registers a combination, then probes the same combination from the same
    /// process. If the second attempt fails distinguishably, negative-space probing
    /// and differential attribution both work on this OS build. If it succeeds,
    /// duplicate registration is permitted and the whole probe line of attack has to
    /// be disabled rather than silently producing nonsense.
    public static func selfTestProbingWorks() -> (works: Bool, status: OSStatus) {
        // ⌃⌥⌘F19 — a combination essentially nothing binds, so a "claimed" result
        // here really is our own registration and not a bystander.
        guard let keyCode = KeyCodes.nameToKeyCode["f19"] else { return (false, paramErr) }
        let combo = KeyCombo(keyCode: keyCode, modifiers: [.control, .option, .command])

        let (firstStatus, holder) = register(combo, id: 0xF001)
        defer { holder?.release() }
        guard firstStatus == noErr, holder != nil else {
            // We could not even take it — inconclusive, so assume probing is unsafe.
            return (false, firstStatus)
        }

        let second = probe(combo, id: 0xF002)
        return (second.outcome == .claimed, second.status)
    }
}
