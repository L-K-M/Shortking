import Foundation

/// What a source needs before it can produce anything.
public enum ScanRequirement: String, Sendable {
    case none
    case accessibility
    case inputMonitoring
    case fileAccess
    case privateSymbols
}

/// Anything that can produce claims.
///
/// Sources are long-lived objects (so they can own caches) and are invoked
/// concurrently by the coordinator. A source that throws or hangs degrades to a
/// warning — never an empty inventory, never a crash.
public protocol ClaimSource: AnyObject {
    /// Stable identifier, used in settings and diagnostics.
    var identifier: String { get }
    var displayName: String { get }
    var requirement: ScanRequirement { get }
    /// Whether the user has this source enabled for the given options.
    func isEnabled(for options: ScanOptions) -> Bool
    func scan(context: ScanContext) async throws -> [Claim]
}

public extension ClaimSource {
    var requirement: ScanRequirement { .none }
    func isEnabled(for options: ScanOptions) -> Bool { true }
}

/// What one source produced, including how it failed if it did.
public struct SourceOutcome: Sendable {
    public var identifier: String
    public var displayName: String
    public var claims: [Claim]
    public var duration: TimeInterval
    public var error: String?
    public var timedOut: Bool

    public init(
        identifier: String,
        displayName: String,
        claims: [Claim],
        duration: TimeInterval,
        error: String? = nil,
        timedOut: Bool = false
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.claims = claims
        self.duration = duration
        self.error = error
        self.timedOut = timedOut
    }

    public var succeeded: Bool { error == nil && !timedOut }
}

/// The complete result of a scan.
public struct ScanResult: Sendable {
    public var claims: [Claim]
    public var groups: [ComboGroup]
    public var conflicts: [Conflict]
    public var outcomes: [SourceOutcome]
    public var eventTaps: [EventTapInfo]
    public var probeReport: ProbeReport?
    public var startedAt: Date
    public var finishedAt: Date

    public init(
        claims: [Claim] = [],
        groups: [ComboGroup] = [],
        conflicts: [Conflict] = [],
        outcomes: [SourceOutcome] = [],
        eventTaps: [EventTapInfo] = [],
        probeReport: ProbeReport? = nil,
        startedAt: Date = Date(),
        finishedAt: Date = Date()
    ) {
        self.claims = claims
        self.groups = groups
        self.conflicts = conflicts
        self.outcomes = outcomes
        self.eventTaps = eventTaps
        self.probeReport = probeReport
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    public var warnings: [SourceOutcome] { outcomes.filter { !$0.succeeded } }
}

/// Errors a source can raise. All of them are survivable.
public enum ScanError: LocalizedError {
    case missingPermission(ScanRequirement)
    case unavailable(String)
    case parseFailure(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .missingPermission(let requirement):
            switch requirement {
            case .accessibility:
                return "Accessibility permission is required to read other apps' menus."
            case .inputMonitoring:
                return "Input Monitoring permission is required to observe key events."
            case .fileAccess:
                return "File access is required to read other apps' preferences."
            case .privateSymbols:
                return "The required SkyLight symbols are not available on this macOS version."
            case .none:
                return "A required permission is missing."
            }
        case .unavailable(let what):
            return "\(what) is not available on this system."
        case .parseFailure(let path, let reason):
            return "Could not parse \(path): \(reason)"
        }
    }
}
