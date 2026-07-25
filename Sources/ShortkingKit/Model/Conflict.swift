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

    public init(
        combo: KeyCombo,
        kind: Kind,
        winner: Claim?,
        losers: [Claim],
        explanation: String,
        suggestion: String? = nil,
        severity: Severity
    ) {
        self.combo = combo
        self.kind = kind
        self.winner = winner
        self.losers = losers
        self.explanation = explanation
        self.suggestion = suggestion
        self.severity = severity
    }

    public static func == (lhs: Conflict, rhs: Conflict) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
