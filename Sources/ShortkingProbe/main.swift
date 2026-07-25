import Foundation
import ShortkingKit

/// `shortking-probe` — the negative-space sweep, in a process that exits.
///
/// Everything about this helper exists to make one guarantee: **no combination is
/// ever left registered**. Registrations are released immediately in a `defer`, a
/// signal handler releases and exits on termination, a watchdog thread hard-exits if
/// the sweep somehow stalls, and the process itself is short-lived so the kernel
/// cleans up whatever we missed.

// MARK: - Safety net

/// Hard ceiling on how long this process may live, whatever happens. Exceeding it
/// means something is very wrong, and dying is strictly safer than continuing to
/// hold registrations.
let watchdogSeconds: TimeInterval = 120

let watchdog = Thread {
    Thread.sleep(forTimeInterval: watchdogSeconds)
    FileHandle.standardError.write(
        Data("shortking-probe: watchdog expired, exiting\n".utf8)
    )
    exit(3)
}
watchdog.stackSize = 64 * 1024
watchdog.start()

// Exiting on a signal drops every registration with it. `SIG_DFL` would too, but
// being explicit documents the intent.
for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
    signal(signalNumber) { _ in
        exit(2)
    }
}

// MARK: - Arguments

struct Arguments {
    var breadth: ProbeBreadth = .common
    var combos: [KeyCombo]?
    var pretty = false
}

func parseArguments(_ argv: [String]) -> Arguments {
    var arguments = Arguments()
    var index = 1
    while index < argv.count {
        switch argv[index] {
        case "--breadth":
            index += 1
            if index < argv.count, let breadth = ProbeBreadth(rawValue: argv[index]) {
                arguments.breadth = breadth
            }
        case "--combos":
            index += 1
            if index < argv.count {
                arguments.combos = ProbeRunner.decodeCombos(argv[index])
            }
        case "--pretty":
            arguments.pretty = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            break
        }
        index += 1
    }
    return arguments
}

func printUsage() {
    let usage = """
    shortking-probe — asks macOS which key combinations are already claimed.

    USAGE:
      shortking-probe [--breadth common|wide|exhaustive]
      shortking-probe --combos <keyCode:modifiers,…>

    Registers each combination momentarily and releases it immediately; a refusal
    means someone else holds it. Prints a JSON ProbeReport on stdout.

    OPTIONS:
      --breadth <b>   How much of the combination space to sweep. Default: common.
      --combos <list> Probe only these combinations, as keyCode:modifierBits pairs.
      --pretty        Pretty-print the JSON.
      --help          Show this message.

    """
    FileHandle.standardError.write(Data(usage.utf8))
}

// MARK: - Run

let arguments = parseArguments(CommandLine.arguments)

let report = ProbeSweep.run(breadth: arguments.breadth, combos: arguments.combos)

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
if arguments.pretty {
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
}

do {
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    exit(0)
} catch {
    FileHandle.standardError.write(
        Data("shortking-probe: failed to encode report: \(error)\n".utf8)
    )
    exit(1)
}
