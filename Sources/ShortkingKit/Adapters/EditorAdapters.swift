import Foundation

/// VS Code and its forks — `.../User/keybindings.json`.
///
/// These bindings are app-local: they only fire while the editor is focused, which
/// makes them a *contextual* conflict against a global hotkey rather than a definite
/// one. That distinction is exactly what the layer model exists to express.
public final class VSCodeAdapter: ConfigAdapter {

    public let identifier = "vscode"
    public let displayName = "VS Code and forks"
    public let layer: ClaimLayer = .appMenu
    public let ownerName = "Visual Studio Code"
    public let ownerBundleID: String? = "com.microsoft.VSCode"

    /// Directory name under Application Support → display name.
    static let variants: [(directory: String, name: String, bundleID: String?)] = [
        ("Code", "Visual Studio Code", "com.microsoft.VSCode"),
        ("Code - Insiders", "VS Code Insiders", "com.microsoft.VSCodeInsiders"),
        ("Cursor", "Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Windsurf", "Windsurf", nil),
        ("VSCodium", "VSCodium", "com.vscodium"),
    ]

    public init() {}

    public func detectedPaths() -> [String] {
        let base = Self.home("Library/Application Support")
        return existing(Self.variants.map { "\(base)/\($0.directory)/User/keybindings.json" })
    }

    public func parse(path: String) throws -> [ParsedBinding] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ScanError.parseFailure(path: path, reason: "unreadable")
        }
        return try Self.parse(contents: contents, path: path)
    }

    public static func parse(contents: String, path: String) throws -> [ParsedBinding] {
        // keybindings.json is JSONC: comments and trailing commas are legal.
        let json = JSONC.strip(contents)
        guard let data = json.data(using: .utf8) else {
            throw ScanError.parseFailure(path: path, reason: "not UTF-8")
        }
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ScanError.parseFailure(path: path, reason: "not a JSON array")
        }

        return entries.compactMap { entry -> ParsedBinding? in
            guard let key = entry["key"] as? String else { return nil }
            guard let command = entry["command"] as? String else { return nil }

            // A `-` prefix on the command *removes* a default binding, so it is the
            // opposite of a claim.
            let isRemoval = command.hasPrefix("-")
            guard !isRemoval else { return nil }

            // Chords ("cmd+k cmd+s") only claim their first keystroke.
            let firstChord = key.split(separator: " ").first.map(String.init) ?? key
            guard let combo = parseChord(firstChord) else { return nil }

            var detail: [String: String] = ["command": command, "key": key]
            if let when = entry["when"] as? String { detail["when"] = when }
            if key.contains(" ") { detail["chord"] = key }

            return ParsedBinding(combo: combo, label: command, detail: detail)
        }
    }

    /// `cmd+shift+g` → ⌘⇧G.
    static func parseChord(_ chord: String) -> KeyCombo? {
        let parts = chord.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return nil }

        let modifiers = Modifiers.parseTokens(Array(parts.dropLast()))
        guard !modifiers.isEmpty else { return nil }

        return KeyCombo(token: key, modifiers: modifiers)
    }
}

/// JetBrains IDEs — `~/Library/Application Support/JetBrains/<IDE>/keymaps/*.xml`.
///
/// Only custom keymaps live on disk; the built-in ones ship inside the IDE. So this
/// sees what the user changed, which is usually the interesting part anyway.
public final class JetBrainsAdapter: ConfigAdapter {

    public let identifier = "jetbrains"
    public let displayName = "JetBrains IDEs"
    public let layer: ClaimLayer = .appMenu
    public let ownerName = "JetBrains IDE"
    public let ownerBundleID: String? = nil

    public init() {}

    public func detectedPaths() -> [String] {
        let base = Self.home("Library/Application Support/JetBrains")
        let fm = FileManager.default
        guard let ides = try? fm.contentsOfDirectory(atPath: base) else { return [] }

        var paths: [String] = []
        for ide in ides {
            let keymaps = "\(base)/\(ide)/keymaps"
            guard let files = try? fm.contentsOfDirectory(atPath: keymaps) else { continue }
            paths.append(contentsOf: files.filter { $0.hasSuffix(".xml") }.map { "\(keymaps)/\($0)" })
        }
        return paths.sorted()
    }

    public func parse(path: String) throws -> [ParsedBinding] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ScanError.parseFailure(path: path, reason: "unreadable")
        }
        let parser = KeymapXMLParser()
        guard parser.parse(data: data) else {
            throw ScanError.parseFailure(path: path, reason: "malformed XML")
        }

        let ide = Self.ideName(fromPath: path)

        return parser.shortcuts.compactMap { shortcut -> ParsedBinding? in
            guard let combo = Self.parseKeystroke(shortcut.keystroke) else { return nil }
            var detail = ["action": shortcut.actionID, "keystroke": shortcut.keystroke]
            if let second = shortcut.secondKeystroke { detail["secondKeystroke"] = second }
            if let ide { detail["ide"] = ide }
            return ParsedBinding(combo: combo, label: shortcut.actionID, detail: detail)
        }
    }

    static func ideName(fromPath path: String) -> String? {
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(of: "JetBrains"),
              components.index(after: index) < components.endIndex else { return nil }
        return String(components[components.index(after: index)])
    }

    /// JetBrains keystroke syntax: `shift meta G`, `ctrl alt BACK_SPACE`, `meta F5`.
    static func parseKeystroke(_ keystroke: String) -> KeyCombo? {
        let tokens = keystroke.split(separator: " ").map(String.init)
        guard let key = tokens.last, !key.isEmpty else { return nil }

        let modifiers = Modifiers.parseTokens(Array(tokens.dropLast()))
        guard !modifiers.isEmpty else { return nil }

        let normalized = keyNames[key.uppercased()] ?? key
        return KeyCombo(token: normalized, modifiers: modifiers)
    }

    /// JetBrains uses AWT key names, which differ from ours in enough places to
    /// need a table.
    static let keyNames: [String: String] = [
        "BACK_SPACE": "delete",
        "DELETE": "forwarddelete",
        "ENTER": "return",
        "ESCAPE": "escape",
        "SPACE": "space",
        "TAB": "tab",
        "PAGE_UP": "pageup",
        "PAGE_DOWN": "pagedown",
        "LEFT": "left", "RIGHT": "right", "UP": "up", "DOWN": "down",
        "HOME": "home", "END": "end",
        "SLASH": "/", "BACK_SLASH": "\\", "PERIOD": ".", "COMMA": ",",
        "SEMICOLON": ";", "QUOTE": "'", "BACK_QUOTE": "`",
        "OPEN_BRACKET": "[", "CLOSE_BRACKET": "]",
        "MINUS": "-", "EQUALS": "=",
    ]
}

/// Pulls `<action id="…"><keyboard-shortcut first-keystroke="…"/></action>` out of
/// a JetBrains keymap.
final class KeymapXMLParser: NSObject, XMLParserDelegate {

    struct Shortcut {
        var actionID: String
        var keystroke: String
        var secondKeystroke: String?
    }

    private(set) var shortcuts: [Shortcut] = []
    private var currentActionID: String?

    func parse(data: Data) -> Bool {
        shortcuts = []
        currentActionID = nil
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "action":
            currentActionID = attributes["id"]
        case "keyboard-shortcut":
            guard let actionID = currentActionID,
                  let first = attributes["first-keystroke"] else { return }
            shortcuts.append(
                Shortcut(
                    actionID: actionID,
                    keystroke: first,
                    secondKeystroke: attributes["second-keystroke"]
                )
            )
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName == "action" { currentActionID = nil }
    }
}

/// Strips comments and trailing commas from JSON-with-comments.
///
/// Written by hand rather than pulled in as a dependency because it has to be
/// string-aware: a `//` inside a string literal is not a comment, and an escaped
/// quote does not end a string.
public enum JSONC {

    public static func strip(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)

        var inString = false
        var escaped = false
        var inLineComment = false
        var inBlockComment = false

        var iterator = input.startIndex
        while iterator < input.endIndex {
            let character = input[iterator]
            let next = input.index(after: iterator) < input.endIndex
                ? input[input.index(after: iterator)]
                : nil

            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    output.append(character)
                }
                iterator = input.index(after: iterator)
                continue
            }

            if inBlockComment {
                if character == "*", next == "/" {
                    inBlockComment = false
                    iterator = input.index(iterator, offsetBy: 2)
                    continue
                }
                // Preserve newlines so line numbers survive.
                if character == "\n" { output.append(character) }
                iterator = input.index(after: iterator)
                continue
            }

            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                iterator = input.index(after: iterator)
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                iterator = input.index(after: iterator)
                continue
            }

            if character == "/", next == "/" {
                inLineComment = true
                iterator = input.index(iterator, offsetBy: 2)
                continue
            }

            if character == "/", next == "*" {
                inBlockComment = true
                iterator = input.index(iterator, offsetBy: 2)
                continue
            }

            output.append(character)
            iterator = input.index(after: iterator)
        }

        return removeTrailingCommas(output)
    }

    /// Removes commas that sit immediately before a closing bracket or brace.
    private static func removeTrailingCommas(_ input: String) -> String {
        let characters = Array(input)
        var result: [Character] = []
        result.reserveCapacity(characters.count)

        var inString = false
        var escaped = false

        var index = 0
        while index < characters.count {
            let character = characters[index]

            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                index += 1
                continue
            }

            if character == "," {
                // Look ahead past whitespace for a closer.
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead].isWhitespace {
                    lookahead += 1
                }
                if lookahead < characters.count,
                   characters[lookahead] == "}" || characters[lookahead] == "]" {
                    index += 1
                    continue
                }
            }

            result.append(character)
            index += 1
        }

        return String(result)
    }
}
