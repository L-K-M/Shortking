import Carbon.HIToolbox
import Foundation

/// Secure event input detection.
///
/// While a password field is focused anywhere on the system, secure event input is
/// enabled and event taps stop receiving keys. Apps sometimes leave it stuck on
/// after they quit or crash — a common, and totally non-conflict, cause of "my
/// shortcut doesn't work". Detecting it is one of the things that makes Shortking
/// useful on day one.
public enum SecureInput {

    public struct State: Sendable {
        public var isEnabled: Bool
        /// The process that most likely holds it, when we can determine one.
        public var suspectedHolder: String?
        public var suspectedPID: Int32?
    }

    public static var isEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// Current state, including a best-effort culprit lookup via `ioreg`.
    ///
    /// The culprit lookup shells out because there is no API for it: the kernel
    /// exposes the owning pid in the IORegistry and nowhere else.
    public static func currentState() -> State {
        guard isEnabled else {
            return State(isEnabled: false, suspectedHolder: nil, suspectedPID: nil)
        }
        let (name, pid) = findHolder()
        return State(isEnabled: true, suspectedHolder: name, suspectedPID: pid)
    }

    private static func findHolder() -> (String?, Int32?) {
        guard let output = Shell.run("/usr/sbin/ioreg", arguments: ["-l", "-w", "0", "-d", "1"]) else {
            return (nil, nil)
        }
        // The IORegistry root carries `"kCGSSessionSecureInputPID" = <pid>` while
        // secure input is held.
        for line in output.split(separator: "\n") {
            guard line.contains("kCGSSessionSecureInputPID") else { continue }
            let digits = line.filter { $0.isNumber }
            guard let pid = Int32(digits) else { continue }
            return (ProcessLookup.name(forPID: pid), pid)
        }
        return (nil, nil)
    }
}
