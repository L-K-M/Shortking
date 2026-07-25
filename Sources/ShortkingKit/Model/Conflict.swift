import Foundation

/// A key combination that will not do what someone expects.
public struct Conflict: Identifiable, Hashable, Sendable {

    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// Two global claims on the same combination.
        case definite
        /// A global claim versus an app-local menu equivalent — bites only when that
        /// app is frontmost.
        case contextual
        /// A strictly lower layer wins outright and the others never fire.
        case shadowed
        /// The probe says someone holds it; nobody claims it.
        case unattributed

        public var displayName: String {
            switch self {
            case .definite:     return "Conflict"
            case .contextual:   return "Contextual"
            case .shadowed:     return "Shadowed"
            case .unattributed: return "Unknown owner"
            }
        }
    }

    public enum Severity: Int, Comparable, Sendable {
        case info = 0
        case low = 1
        case medium = 2
        case high = 3

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public var id: String { "\(combo.groupingKey)|\(kind.rawValue)" }

    public var combo: KeyCombo
    public var kind: Kind
    public var winner: Claim?
    public var losers: [Claim]
    /// A plain-language sentence generated from the layer comparison.
    public var explanation: String
    /// Advisory only — Shortking never rebinds anything itself.
    public var suggestion: String?
    public var severity: Severity

    /// Every claimant is macOS itself.
    ///
    /// macOS ships a number of symbolic hotkeys that collide with each other out of
    /// the box. Those collisions are real, but they are Apple's arrangement rather
    /// than something an installed app did, and the user's first question is almost
    /// never about them — so the overview separates the two.
    public var isSystemDefault: Bool

    /// A conflict only some of the time: a global claim shadowing an app's own menu
    /// shortcut fires everywhere *except* where the user expects, which reads as
    /// "this works inconsistently" rather than "this is broken".
    public var isIntermittent: Bool {
        kind == .contextual || (kind == .shadowed && losers.contains { $0.layer == .appMenu })
    }

    public init(
        combo: KeyCombo,
        kind: Kind,
        winner: Claim?,
        losers: [Claim],
        explanation: String,
        suggestion: String? = nil,
        severity: Severity,
        isSystemDefault: Bool = false
    ) {
        self.combo = combo
        self.kind = kind
        self.winner = winner
        self.losers = losers
        self.explanation = explanation
        self.suggestion = suggestion
        self.severity = severity
        self.isSystemDefault = isSystemDefault
    }

    public static func == (lhs: Conflict, rhs: Conflict) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
