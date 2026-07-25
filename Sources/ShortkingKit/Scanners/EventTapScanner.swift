import CoreGraphics
import Foundation

/// One installed event tap, as reported by `CGGetEventTapList`.
public struct EventTapInfo: Identifiable, Hashable, Sendable {
    public var tapID: UInt32
    public var tapPoint: TapPoint
    public var isActiveFilter: Bool
    public var eventMask: UInt64
    public var tappingPID: Int32
    public var tappedPID: Int32
    public var enabled: Bool
    public var minLatencyUsec: UInt32
    public var avgLatencyUsec: UInt32
    public var maxLatencyUsec: UInt32
    public var owner: Owner

    public var id: UInt32 { tapID }

    public enum TapPoint: String, Sendable {
        case hid = "HID"
        case session = "Session"
        case annotatedSession = "Annotated session"
        case perProcess = "Per-process"
        case unknown = "Unknown"

        public var layer: ClaimLayer {
            switch self {
            case .hid: return .hidTap
            default: return .sessionTap
            }
        }
    }

    /// The event types this tap asked for, as human-readable names.
    public var eventNames: [String] {
        EventTapScanner.decode(mask: eventMask)
    }

    /// True when this tap can actually swallow a keystroke.
    ///
    /// Listen-only taps see everything and consume nothing, so they are not
    /// suspects for a disappearing key — an important distinction the UI makes.
    public var canSwallowKeys: Bool {
        isActiveFilter && enabled && EventTapScanner.masksKeyEvents(eventMask)
    }
}

/// `CGGetEventTapList` — public API, and underused.
///
/// This cannot tell us *which* combinations a tap consumes (the binding lives only
/// in that app's own code), but it gives an exact, authoritative suspect list:
/// every process capable of swallowing a keystroke, whether it filters or only
/// listens, and whether it is currently enabled.
///
/// It produces two things: `EventTapInfo` records for the Suspects panel, and
/// `capability` claims — never bindings — so that a tapping process shows up in the
/// model without ever being presented as the owner of a specific combination.
public final class EventTapScanner: ClaimSource {

    public let identifier = "event-taps"
    public let displayName = "Event taps"

    public private(set) var lastTaps: [EventTapInfo] = []

    public init() {}

    public func isEnabled(for options: ScanOptions) -> Bool {
        options.includeEventTaps
    }

    public func scan(context: ScanContext) async throws -> [Claim] {
        let taps = Self.currentTaps()
        lastTaps = taps

        // One capability record per tapping process, not per tap: a process with
        // three taps is one suspect, not three.
        var byProcess: [Int32: [EventTapInfo]] = [:]
        for tap in taps where EventTapScanner.masksKeyEvents(tap.eventMask) {
            byProcess[tap.tappingPID, default: []].append(tap)
        }

        return byProcess.map { pid, taps in
            let owner = taps[0].owner
            let filtering = taps.contains { $0.isActiveFilter }
            let evidence = taps.map { tap in
                Evidence(
                    kind: .eventTapCapability,
                    summary: "\(tap.tapPoint.rawValue) tap, "
                        + (tap.isActiveFilter ? "active filter" : "listen-only")
                        + (tap.enabled ? "" : ", DISABLED"),
                    detail: [
                        "tapID": "\(tap.tapID)",
                        "tapPoint": tap.tapPoint.rawValue,
                        "events": tap.eventNames.joined(separator: ", "),
                        "enabled": tap.enabled ? "yes" : "no",
                        "avgLatencyUsec": "\(tap.avgLatencyUsec)",
                        "tappedPID": tap.tappedPID == 0 ? "all" : "\(tap.tappedPID)",
                    ]
                )
            }

            return Claim(
                combo: KeyCombo(keyCode: nil, character: nil, modifiers: []),
                layer: taps.map(\.tapPoint.layer).min() ?? .sessionTap,
                status: .capability,
                owner: owner,
                label: filtering
                    ? "Can intercept and swallow keystrokes"
                    : "Can observe keystrokes",
                enabled: taps.contains { $0.enabled },
                evidence: evidence
            )
        }
    }

    // MARK: - Enumeration

    public static func currentTaps() -> [EventTapInfo] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }

        var buffer = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        var written: UInt32 = 0
        let status = buffer.withUnsafeMutableBufferPointer { pointer -> CGError in
            guard let base = pointer.baseAddress else { return .failure }
            return CGGetEventTapList(count, base, &written)
        }
        guard status == .success else { return [] }

        return buffer.prefix(Int(written)).map { info in
            EventTapInfo(
                tapID: info.eventTapID,
                tapPoint: tapPoint(for: info),
                isActiveFilter: info.options == .defaultTap,
                eventMask: info.eventsOfInterest,
                tappingPID: info.tappingProcess,
                tappedPID: info.processBeingTapped,
                enabled: info.enabled,
                minLatencyUsec: info.minUsecLatency,
                avgLatencyUsec: info.avgUsecLatency,
                maxLatencyUsec: info.maxUsecLatency,
                owner: ProcessLookup.owner(forPID: info.tappingProcess)
            )
        }
    }

    private static func tapPoint(for info: CGEventTapInformation) -> EventTapInfo.TapPoint {
        // A non-zero `processBeingTapped` means a per-pid tap regardless of the
        // nominal tap point.
        if info.processBeingTapped != 0 { return .perProcess }
        switch info.tapPoint {
        case .cghidEventTap: return .hid
        case .cgSessionEventTap: return .session
        case .cgAnnotatedSessionEventTap: return .annotatedSession
        default: return .unknown
        }
    }

    // MARK: - Mask decoding

    /// Event types Shortking names in the UI. `systemDefined` (14) is included
    /// because it is how WindowServer delivers matched hotkeys.
    private static let knownEvents: [(CGEventType, String)] = [
        (.keyDown, "keyDown"),
        (.keyUp, "keyUp"),
        (.flagsChanged, "flagsChanged"),
        (.leftMouseDown, "leftMouseDown"),
        (.rightMouseDown, "rightMouseDown"),
        (.scrollWheel, "scrollWheel"),
        (.tapDisabledByTimeout, "tapDisabledByTimeout"),
        (.tapDisabledByUserInput, "tapDisabledByUserInput"),
    ]

    /// `NX_SYSDEFINED` — not exposed as a `CGEventType` case.
    public static let systemDefinedEventType: UInt32 = 14
    public static let systemDefinedMask: UInt64 = 1 << 14

    public static func decode(mask: UInt64) -> [String] {
        var names: [String] = []
        for (type, name) in knownEvents where mask & (1 << UInt64(type.rawValue)) != 0 {
            names.append(name)
        }
        if mask & systemDefinedMask != 0 { names.append("systemDefined") }
        if mask == ~UInt64(0) { return ["all events"] }
        if names.isEmpty { names.append(String(format: "mask 0x%llX", mask)) }
        return names
    }

    public static func masksKeyEvents(_ mask: UInt64) -> Bool {
        let keyMask = (UInt64(1) << UInt64(CGEventType.keyDown.rawValue))
            | (UInt64(1) << UInt64(CGEventType.keyUp.rawValue))
            | (UInt64(1) << UInt64(CGEventType.flagsChanged.rawValue))
            | systemDefinedMask
        return mask & keyMask != 0
    }
}
