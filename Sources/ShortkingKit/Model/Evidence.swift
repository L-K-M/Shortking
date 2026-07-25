import Foundation

/// Why Shortking believes a claim exists.
///
/// Deliberately a struct with a string-keyed detail bag rather than an enum with
/// associated values: evidence is persisted for the lifetime of the install and
/// accumulates across OS versions, so it has to survive new evidence kinds being
/// added without invalidating the ledger. It also renders directly as a key/value
/// disclosure in the UI.
public struct Evidence: Codable, Hashable, Sendable, Identifiable {

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case configFile
        case accessibilityMenu
        case symbolicHotKey
        case userKeyEquivalent
        case servicesPlist
        case inputSource
        case genericPreference
        case probeExclusionFailure
        case probeAvailable
        case systemDefinedDelivery
        case differentialObservation
        case sideChannel
        case eventTapCapability
        case staticBinarySymbol

        public var displayName: String {
            switch self {
            case .configFile:              return "Config file"
            case .accessibilityMenu:       return "Menu bar"
            case .symbolicHotKey:          return "Symbolic hotkey"
            case .userKeyEquivalent:       return "User key equivalent"
            case .servicesPlist:           return "Services"
            case .inputSource:             return "Input source"
            case .genericPreference:       return "App preferences"
            case .probeExclusionFailure:   return "Probe: refused"
            case .probeAvailable:          return "Probe: available"
            case .systemDefinedDelivery:   return "Live capture"
            case .differentialObservation: return "Launch/quit observation"
            case .sideChannel:             return "Side channel"
            case .eventTapCapability:      return "Event tap"
            case .staticBinarySymbol:      return "Binary symbols"
            }
        }

        /// True when this evidence is a direct read rather than an inference.
        public var isDirect: Bool {
            switch self {
            case .configFile, .accessibilityMenu, .symbolicHotKey, .userKeyEquivalent,
                 .servicesPlist, .inputSource, .genericPreference, .systemDefinedDelivery:
                return true
            case .probeExclusionFailure, .probeAvailable, .differentialObservation,
                 .sideChannel, .eventTapCapability, .staticBinarySymbol:
                return false
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// One line, written for a human: `"~/.skhdrc line 42"`, `"File ▸ Go to Folder…"`.
    public var summary: String
    /// Structured supporting facts, shown in the expandable evidence trail.
    public var detail: [String: String]
    public var observedAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        summary: String,
        detail: [String: String] = [:],
        observedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.observedAt = observedAt
    }

    /// Two pieces of evidence are the same fact if they say the same thing, whenever
    /// they were observed. Used to union evidence across rescans without growing the
    /// trail unboundedly.
    public var factKey: String {
        "\(kind.rawValue)|\(summary)"
    }
}
