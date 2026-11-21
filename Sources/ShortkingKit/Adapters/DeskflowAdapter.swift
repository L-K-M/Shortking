import Foundation

/// Deskflow's Mac server registers its screen-switching shortcuts using Carbon.
/// The GUI also runs in client mode and with the server stopped.
public final class DeskflowAdapter: ConfigAdapter {
    public let identifier = "deskflow"
    public let displayName = "Deskflow"
    public let layer: ClaimLayer = .windowServer
    public let ownerName = "Deskflow"
    public let ownerBundleID: String? = "org.deskflow.deskflow"

    private let defaultSettings: () -> String
    private let coreArguments: () -> [[String]]

    public convenience init() {
        self.init(defaultSettings: Self.defaultSettingsPath, coreArguments: Self.runningCores)
    }

    init(defaultSettings: @escaping () -> String, coreArguments: @escaping () -> [[String]]) {
        self.defaultSettings = defaultSettings
        self.coreArguments = coreArguments
    }

    private static func defaultSettingsPath() -> String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("Deskflow/Deskflow.conf")
        }
        let userSettings = Self.home("Library/Deskflow/Deskflow.conf")
        return FileManager.default.fileExists(atPath: userSettings) ? userSettings : "/Library/Deskflow/Deskflow.conf"
    }

    public func detectedPaths() -> [String] {
        let paths = [Self.serverFile(for: defaultSettings())].compactMap { $0 } + activePaths()
        return Array(Set(paths)).sorted().filter(Self.isRegularFile)
    }

    private func activePaths() -> [String] {
        coreArguments().compactMap { arguments in
            var mode: String?
            var settings = defaultSettings()
            var options = arguments.dropFirst().makeIterator()
            while let argument = options.next() {
                switch argument {
                case "-s", "--settings", "-settings":
                    guard let path = options.next() else { return nil }
                    settings = path
                case "--new-instance", "-new-instance": continue
                default:
                    if let separator = argument.firstIndex(of: "="),
                       ["-s", "--settings", "-settings"].contains(String(argument[..<separator])) {
                        settings = String(argument[argument.index(after: separator)...])
                    } else if !argument.hasPrefix("-"), mode == nil {
                        mode = argument.lowercased()
                    } else {
                        return nil
                    }
                }
            }
            guard mode == "server", (settings as NSString).isAbsolutePath else { return nil }
            return Self.serverFile(for: settings)
        }
    }

    private static func isRegularFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func serverFile(for settingsPath: String) -> String? {
        guard isRegularFile(settingsPath),
              let settings = try? String(contentsOfFile: settingsPath, encoding: .utf8) else { return nil }
        let server = Self.serverSettings(settings)
        // In internal mode the GUI exports the editable Qt arrays to this file
        // before starting the core. Only that exported copy is read by the server.
        let generated = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
            .appendingPathComponent("deskflow-server.conf").path
        let external = server["externalConfig"]?.lowercased()
        let path = external == "true" || external == "1" ? server["externalConfigFile"] ?? generated : generated
        guard (path as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func serverSettings(_ settings: String) -> [String: String] {
        var inServer = false
        var values: [String: String] = [:]
        for rawLine in settings.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inServer = line == "[server]"
            } else if inServer, let separator = line.firstIndex(of: "=") {
                let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.first == "\"", value.last == "\"" {
                    value = String(value.dropFirst().dropLast())
                }
                values[key] = value
            }
        }
        return values
    }

    private static func runningCores() -> [[String]] {
        // NSWorkspace can see the GUI but miss the separate headless process
        // that owns the shortcuts. Only query arguments for same-user cores.
        let result = Shell.run("/usr/bin/pgrep", arguments: ["-U", String(getuid()), "-x", "deskflow-core"])
        let pids = result?.split(whereSeparator: \.isNewline).compactMap { Int32($0) } ?? []
        return pids.compactMap { pid in
            var mib = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
            let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            guard argc > 0 else { return nil }
            // argc, executable path, padding, argv, then the environment.
            // Decode only argv and ignore the environment entirely.
            let fields = bytes[MemoryLayout<Int32>.size..<size].split(separator: 0, maxSplits: Int(argc) + 1)
            guard fields.count > Int(argc),
                  (String(decoding: fields[0], as: UTF8.self) as NSString).lastPathComponent == "deskflow-core"
            else { return nil }
            return fields.dropFirst().prefix(Int(argc)).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    public func parse(path: String) throws -> [ParsedBinding] {
        guard Self.isRegularFile(path) else { return [] }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let enabled = activePaths().contains(URL(fileURLWithPath: path).standardizedFileURL.path)
        var bindings: [ParsedBinding] = []
        var inOptions = false
        for (offset, rawLine) in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("section:") {
                inOptions = line.dropFirst("section:".count).trimmingCharacters(in: .whitespaces) == "options"
                continue
            }
            if line == "end" { inOptions = false }
            guard inOptions, let equal = line.firstIndex(of: "=") else { continue }
            let condition = line[..<equal].trimmingCharacters(in: .whitespaces)
            let action = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            guard !action.isEmpty, let open = condition.firstIndex(of: "("), condition.last == ")",
                  condition[..<open].trimmingCharacters(in: .whitespaces) == "keystroke" else { continue }
            let trigger = String(condition[condition.index(after: open)...].dropLast())
            guard let combo = Self.combo(for: trigger) else { continue }
            bindings.append(ParsedBinding(
                combo: combo, label: action, enabled: enabled, line: offset + 1,
                detail: ["trigger": trigger, "server": enabled ? "running" : "inactive"]
            ))
        }
        return bindings
    }

    private static func combo(for trigger: String) -> KeyCombo? {
        let tokens = trigger.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard tokens.count > 1, let key = tokens.last else { return nil }
        // OSXKeyState::mapDeskflowHotKeyToMac uses a different convention for
        // hotkey registration from the usual Mac meanings of Alt and Super.
        let mapping: [String: Modifiers] = ["alt": .command, "super": .option, "control": .control,
                                            "shift": .shift, "meta": [], "altgr": []]
        let modifierTokens = tokens.dropLast()
        guard Set(modifierTokens).count == modifierTokens.count else { return nil }
        var modifiers: Modifiers = []
        for token in modifierTokens {
            guard let modifier = mapping[token] else { return nil }
            modifiers.formUnion(modifier)
        }
        guard !modifiers.isEmpty, let code = keyCode(for: key) else { return nil }
        return KeyCombo(keyCode: code, modifiers: modifiers)
    }

    private static func keyCode(for key: String) -> UInt16? {
        // Deskflow uses X11 spellings for named keys. A generic alias such as
        // "esc" or "keypad1" is not a valid Deskflow trigger.
        let names = ["backspace": "delete", "delete": "forwarddelete", "insert": "help",
                     "kp_decimal": "keypaddecimal", "kp_equal": "keypadequals", "kp_add": "keypadplus",
                     "kp_divide": "keypaddivide", "kp_multiply": "keypadmultiply", "kp_subtract": "keypadminus",
                     "kp_enter": "keypadenter", "apostrophe": "'", "comma": ",", "minus": "-", "period": ".",
                     "slash": "/", "semicolon": ";", "equal": "=", "bracketl": "[", "backslash": "\\",
                     "bracketr": "]", "grave": "`"]
        if let canonical = names[key] { return KeyCodes.keyCode(forToken: canonical) }
        if key.hasPrefix("kp_"), key.count == 4, let digit = key.last, digit.isNumber {
            return KeyCodes.nameToKeyCode["keypad" + String(digit)]
        }
        if key.hasPrefix("keypad") || key == "forwarddelete" { return nil }
        return KeyCodes.nameToKeyCode[key] ?? KeyCodes.charToKeyCode[key]
    }
}
