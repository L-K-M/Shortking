import AppKit
import CoreGraphics
import Foundation

/// Swallow detection by observing the same keystroke at two points in the chain.
///
/// Two listen-only taps:
///
/// - **A** at `kCGSessionEventTap`, head-inserted — sees the key early.
/// - **B** at `kCGAnnotatedSessionEventTap`, tail-appended — sees it after everyone
///   who might consume it, and carries the delivery target.
///
/// | A | B | Conclusion |
/// |---|---|---|
/// | ✅ | ✅ | Delivered to an app — target read from `kCGEventTargetUnixProcessID` |
/// | ✅ | ❌ | Swallowed between the two: a filtering tap or a WindowServer hotkey |
/// | ❌ | ❌ | Swallowed upstream: a HID-level tap or a virtual HID remap |
///
/// HID-level taps require root, so Shortking does not install one. The ❌/❌ row
/// already tells the user where to look (Karabiner, or a privileged tool), which is
/// what matters for a diagnostic.
public final class SandwichTaps {

    /// What happened to one keystroke.
    public struct Observation: Identifiable, Hashable, Sendable {
        public enum Verdict: String, Sendable {
            case delivered
            case swallowedMidChain
            case swallowedUpstream

            public var displayName: String {
                switch self {
                case .delivered:         return "Delivered"
                case .swallowedMidChain: return "Swallowed"
                case .swallowedUpstream: return "Never arrived"
                }
            }
        }

        public var id = UUID()
        public var combo: KeyCombo
        public var verdict: Verdict
        public var targetPID: Int32?
        public var targetName: String?
        public var observedAt: Date

        public var explanation: String {
            switch verdict {
            case .delivered:
                let target = targetName
                    ?? targetPID.map { "pid \($0)" }
                    ?? "an application"
                return "\(combo.displayString) was delivered to \(target). "
                    + "Nothing intercepted it — if the wrong thing happened, that app's own "
                    + "handling is responsible."
            case .swallowedMidChain:
                return "\(combo.displayString) reached the session event tap but never arrived at "
                    + "the end of the chain. Something consumed it: either a filtering event tap "
                    + "or a hotkey registered with WindowServer. Run the Blackout test to tell "
                    + "those two apart."
            case .swallowedUpstream:
                return "\(combo.displayString) never reached the session event tap at all. It was "
                    + "consumed above it — a HID-level tap, or remapped by a virtual keyboard "
                    + "driver such as Karabiner-Elements before macOS finished building the event."
            }
        }
    }

    /// How long to wait at tap B before concluding a key was swallowed.
    private let correlationWindow: TimeInterval = 0.15

    private var tapA: CFMachPort?
    private var tapB: CFMachPort?
    private var sourceA: CFRunLoopSource?
    private var sourceB: CFRunLoopSource?
    private var contextA: Unmanaged<SandwichContext>?
    private var contextB: Unmanaged<SandwichContext>?

    /// Keys seen at A and still waiting to be seen at B.
    private var pending: [String: (combo: KeyCombo, at: Date, work: DispatchWorkItem)] = [:]

    public private(set) var isRunning = false
    private var onObservation: ((Observation) -> Void)?

    public init() {}

    deinit { teardown() }

    /// Starts both taps. Returns `false` when Input Monitoring is missing.
    @discardableResult
    public func start(onObservation: @escaping (Observation) -> Void) -> Bool {
        stop()
        self.onObservation = onObservation

        let mask = CGEventMask(
            (UInt64(1) << UInt64(CGEventType.keyDown.rawValue))
        )

        // Named distinctly from the `contextA`/`contextB` stored properties: a
        // local of the same name shadows the property, so the assignments below
        // would target the local `let` instead of the box the class holds on to.
        let headContext = SandwichContext(position: .head) { [weak self] event in
            self?.sawAtA(event: event)
        }
        let boxA = Unmanaged.passRetained(headContext)
        guard let portA = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: shortkingSandwichCallback,
            userInfo: boxA.toOpaque()
        ) else {
            boxA.release()
            return false
        }

        let tailContext = SandwichContext(position: .tail) { [weak self] event in
            self?.sawAtB(event: event)
        }
        let boxB = Unmanaged.passRetained(tailContext)
        guard let portB = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: shortkingSandwichCallback,
            userInfo: boxB.toOpaque()
        ) else {
            boxA.release()
            boxB.release()
            CFMachPortInvalidate(portA)
            return false
        }

        // The callback needs its own port to re-arm the tap after the system
        // disables it. See `shortkingSandwichCallback`.
        headContext.port = portA
        tailContext.port = portB

        tapA = portA
        tapB = portB
        contextA = boxA
        contextB = boxB

        sourceA = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, portA, 0)
        sourceB = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, portB, 0)
        if let sourceA { CFRunLoopAddSource(CFRunLoopGetMain(), sourceA, .commonModes) }
        if let sourceB { CFRunLoopAddSource(CFRunLoopGetMain(), sourceB, .commonModes) }
        CGEvent.tapEnable(tap: portA, enable: true)
        CGEvent.tapEnable(tap: portB, enable: true)

        isRunning = true
        return true
    }

    public func stop() {
        teardown()
        isRunning = false
        onObservation = nil
    }

    private func teardown() {
        for work in pending.values { work.work.cancel() }
        pending = [:]

        for (port, source) in [(tapA, sourceA), (tapB, sourceB)] {
            if let port {
                CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
            }
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        tapA = nil
        tapB = nil
        sourceA = nil
        sourceB = nil
        contextA?.release()
        contextB?.release()
        contextA = nil
        contextB = nil
    }

    // MARK: - Correlation

    /// Correlation key: the same physical press produces the same keycode and flags
    /// at both taps, so that pair identifies it within the window.
    private static func key(for event: CGEvent) -> (String, KeyCombo) {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Modifiers(cocoa: event.flags.rawValue)
        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        return (combo.groupingKey, combo)
    }

    private func sawAtA(event: CGEvent) {
        let (key, combo) = Self.key(for: event)

        // If B never reports this key inside the window, it was swallowed.
        let work = DispatchWorkItem { [weak self] in
            guard let self, let entry = self.pending.removeValue(forKey: key) else { return }
            self.emit(
                Observation(
                    combo: entry.combo,
                    verdict: .swallowedMidChain,
                    targetPID: nil,
                    targetName: nil,
                    observedAt: Date()
                )
            )
        }

        pending[key]?.work.cancel()
        pending[key] = (combo: combo, at: Date(), work: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + correlationWindow, execute: work)
    }

    private func sawAtB(event: CGEvent) {
        let (key, combo) = Self.key(for: event)

        guard let entry = pending.removeValue(forKey: key) else {
            // Seen at B but never at A. This should not happen for a real key press
            // — but if it does, reporting it as delivered is still true.
            emitDelivered(event: event, combo: combo)
            return
        }
        entry.work.cancel()
        emitDelivered(event: event, combo: entry.combo)
    }

    private func emitDelivered(event: CGEvent, combo: KeyCombo) {
        let rawPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let pid = rawPID > 0 ? Int32(truncatingIfNeeded: rawPID) : nil

        emit(
            Observation(
                combo: combo,
                verdict: .delivered,
                targetPID: pid,
                targetName: pid.flatMap { ProcessLookup.name(forPID: $0) },
                observedAt: Date()
            )
        )
    }

    /// Records a key press that neither tap saw.
    ///
    /// The caller knows a key was pressed (it asked the user to press it) but
    /// neither tap fired, which is itself the diagnosis: something above the session
    /// tap consumed or rewrote it.
    public func reportNothingObserved(for combo: KeyCombo) {
        emit(
            Observation(
                combo: combo,
                verdict: .swallowedUpstream,
                targetPID: nil,
                targetName: nil,
                observedAt: Date()
            )
        )
    }

    private func emit(_ observation: Observation) {
        let handler = onObservation
        DispatchQueue.main.async { handler?(observation) }
    }
}

/// The box handed to the sandwich C callback.
final class SandwichContext {
    enum Position { case head, tail }

    let position: Position
    let handler: (CGEvent) -> Void
    /// Assigned immediately after the tap is created, so the callback can re-arm
    /// its own tap when the system disables it.
    var port: CFMachPort?

    init(position: Position, handler: @escaping (CGEvent) -> Void) {
        self.position = position
        self.handler = handler
    }
}

private func shortkingSandwichCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    // A tap disabled by timeout or by user input must be re-armed or it stays dead
    // silently — one of the failure modes Shortking exists to detect in *other*
    // people's apps, so falling into it here would be embarrassing. The old code
    // said "it will be re-armed" and then did not: nothing anywhere re-enabled it,
    // and the capture went on reporting "never arrived" for keys the dead tap simply
    // never saw.
    //
    // These two types are delivered to the callback whatever the mask says, which is
    // just as well: their raw values are 0xFFFFFFFE and 0xFFFFFFFF, so they cannot be
    // expressed as mask bits at all.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let context = Unmanaged<SandwichContext>.fromOpaque(userInfo).takeUnretainedValue()
        if let port = context.port {
            CGEvent.tapEnable(tap: port, enable: true)
            Log.detective.warning("Sandwich tap disabled by the system; re-armed")
        } else {
            Log.detective.error("Sandwich tap disabled before its port was recorded")
        }
        return nil
    }

    if type == .keyDown {
        // Handled synchronously: the event is only guaranteed valid for the
        // duration of this callback, and both taps are sourced on the main run
        // loop, so there is nothing to hop to.
        let context = Unmanaged<SandwichContext>.fromOpaque(userInfo).takeUnretainedValue()
        context.handler(event)
    }

    return Unmanaged.passUnretained(event)
}
