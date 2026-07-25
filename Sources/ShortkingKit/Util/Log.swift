import Foundation
import OSLog

/// Subsystem loggers. Keeping them in one place means a bug report can ask for
/// `log show --predicate 'subsystem == "com.shortking.app"'` and get everything.
public enum Log {
    private static let subsystem = "com.shortking.app"

    public static let scan       = Logger(subsystem: subsystem, category: "scan")
    public static let platform   = Logger(subsystem: subsystem, category: "platform")
    public static let probe      = Logger(subsystem: subsystem, category: "probe")
    public static let attribution = Logger(subsystem: subsystem, category: "attribution")
    public static let detective  = Logger(subsystem: subsystem, category: "detective")
    public static let store      = Logger(subsystem: subsystem, category: "store")
    public static let ui         = Logger(subsystem: subsystem, category: "ui")
}
