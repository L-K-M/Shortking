/// Registration types the probe has distinguished from an available key across processes.
public enum ProbeCoverage: Sendable {
    case unverified
    case exclusiveOnly
    case sharedAndExclusive
}
