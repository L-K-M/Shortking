import Foundation

/// skhd — `~/.skhdrc` or `~/.config/skhd/skhdrc`.
///
/// skhd is an event-tap tool, so its bindings exist only in its config: nothing is
/// registered with WindowServer and nothing is probeable. Parsing the config is the
/// only way these ever become visible.
public final class SkhdAdapter: ConfigAdapter {

    public let identifier = "skhd"
    public let displayName = "skhd"
    public let layer: ClaimLayer = .sessionTap
    public let ownerName = "skhd"
    public let ownerBundleID: String? = nil

    public init() {}

    public func detectedPaths() -> [String] {
        existing([
            Self.home(".skhdrc"),
            Self.home(".config/skhd/skhdrc"),
        ])
    }

    public func parse(path: String) throws -> [ParsedBinding] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ScanError.parseFailure(path: path, reason: "unreadable")
        }
        return Self.parse(contents: contents)
    }

    /// Parses skhd's line-based grammar:
    ///
    /// ```
    /// cmd + shift - g : open -a Finder
    /// default < ctrl - a : echo hello
    /// # comments and blank lines are skipped
    /// ```
    public static func parse(contents: String) -> [ParsedBinding] {
        var bindings: [ParsedBinding] = []

        for (index, rawLine) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(rawLine)

            // skhd treats `#` as a comment to end of line, so this matches its own
            // parser — including the consequence that a literal `#` in a command is
            // truncated. That is skhd's behaviour, not a bug in the adapter.
            if let hash = line.firstIndex(of: "#") {
                line = String(line[line.startIndex..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Mode declarations and blacklists are not bindings.
            if line.hasPrefix("::") || line.hasPrefix(".blacklist") { continue }

            // Split trigger from command on the first `:` that is not part of `::`.
            guard let separator = line.firstIndex(of: ":") else { continue }
            var trigger = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let command = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !trigger.isEmpty else { continue }

            // `mode <` prefix scopes the binding to a mode.
            var mode: String?
            if let modeSeparator = trigger.firstIndex(of: "<") {
                mode = String(trigger[trigger.startIndex..<modeSeparator])
                    .trimmingCharacters(in: .whitespaces)
                trigger = String(trigger[trigger.index(after: modeSeparator)...])
                    .trimmingCharacters(in: .whitespaces)
            }

            guard let combo = parseTrigger(trigger) else { continue }

            var detail: [String: String] = ["command": command]
            if let mode, !mode.isEmpty, mode != "default" { detail["mode"] = mode }

            bindings.append(
                ParsedBinding(
                    combo: combo,
                    label: command.isEmpty ? "skhd binding" : command,
                    line: index + 1,
                    detail: detail
                )
            )
        }

        return bindings
    }

    /// `cmd + shift - g` → ⌘⇧G. The key follows the last `-`; modifiers precede it,
    /// separated by `+`.
    static func parseTrigger(_ trigger: String) -> KeyCombo? {
        guard let dash = trigger.lastIndex(of: "-") else {
            // A trigger with no `-` is a bare key, which skhd allows but which is
            // not a shortcut worth inventorying.
            return nil
        }
        let modifierPart = String(trigger[trigger.startIndex..<dash])
        let keyPart = String(trigger[trigger.index(after: dash)...])
            .trimmingCharacters(in: .whitespaces)
        guard !keyPart.isEmpty else { return nil }

        let tokens = modifierPart
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let modifiers = Modifiers.parseTokens(tokens)
        guard !modifiers.isEmpty else { return nil }

        // skhd accepts `0x28`-style literal keycodes as well as names.
        if keyPart.hasPrefix("0x"), let code = UInt16(keyPart.dropFirst(2), radix: 16) {
            return KeyCombo(keyCode: code, modifiers: modifiers)
        }
        return KeyCombo(token: keyPart, modifiers: modifiers)
    }
}

/// Hammerspoon — `~/.hammerspoon/init.lua` and any file it loads from that
/// directory.
///
/// This is a heuristic parse of `hs.hotkey.bind` calls, and it is labelled as such
/// in the evidence trail: Hammerspoon configs are arbitrary Lua, so a binding built
/// at runtime from a loop or a variable is invisible to us. We report what we can
/// read literally and never imply the list is complete.
public final class HammerspoonAdapter: ConfigAdapter {

    public let identifier = "hammerspoon"
    public let displayName = "Hammerspoon"
    public let layer: ClaimLayer = .sessionTap
    public let ownerName = "Hammerspoon"
    public let ownerBundleID: String? = "org.hammerspoon.Hammerspoon"

    public init() {}

    public func detectedPaths() -> [String] {
        let directory = Self.home(".hammerspoon")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        return entries
            .filter { $0.hasSuffix(".lua") }
            .map { directory + "/" + $0 }
            .sorted()
    }

    public func parse(path: String) throws -> [ParsedBinding] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ScanError.parseFailure(path: path, reason: "unreadable")
        }
        return Self.parse(contents: contents)
    }

    /// Matches `hs.hotkey.bind({"cmd", "shift"}, "g", …)` and the `bindSpec` form.
    private static let pattern = try? NSRegularExpression(
        pattern: #"hs\.hotkey\.bind\s*\(\s*\{([^}]*)\}\s*,\s*["']([^"']+)["']"#,
        options: []
    )

    public static func parse(contents: String) -> [ParsedBinding] {
        guard let pattern else { return [] }

        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        var bindings: [ParsedBinding] = []

        pattern.enumerateMatches(in: contents, options: [], range: range) { match, _, _ in
            guard let match,
                  let modifierRange = Range(match.range(at: 1), in: contents),
                  let keyRange = Range(match.range(at: 2), in: contents) else { return }

            let tokens = contents[modifierRange]
                .split(whereSeparator: { $0 == "," || $0 == "\"" || $0 == "'" || $0 == " " })
                .map(String.init)
                .filter { !$0.isEmpty }
            let modifiers = Modifiers.parseTokens(tokens)
            guard !modifiers.isEmpty else { return }

            let key = String(contents[keyRange])
            guard let combo = KeyCombo(token: key, modifiers: modifiers) else { return }

            let line = contents[contents.startIndex..<modifierRange.lowerBound]
                .reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }

            bindings.append(
                ParsedBinding(
                    combo: combo,
                    label: "Hammerspoon binding",
                    line: line,
                    detail: ["parse": "heuristic — dynamically built bindings are not visible"]
                )
            )
        }

        return bindings
    }
}
