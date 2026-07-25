import AppKit
import Combine
import Foundation
import ShortkingKit
import SwiftUI

/// The sidebar destinations.
enum Destination: String, Hashable, CaseIterable, Identifiable {
    case home
    case inventory
    case conflicts
    case detective
    case suspects
    case health
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:      return "Overview"
        case .inventory: return "All combos"
        case .conflicts: return "Conflicts"
        case .detective: return "Detective"
        case .suspects:  return "Suspects"
        case .health:    return "Health"
        case .settings:  return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home:      return "sparkles"
        case .inventory: return "keyboard"
        case .conflicts: return "exclamationmark.triangle"
        case .detective: return "magnifyingglass"
        case .suspects:  return "eye"
        case .health:    return "stethoscope"
        case .settings:  return "gearshape"
        }
    }

    var section: String {
        switch self {
        case .home:                  return "Start here"
        case .inventory, .conflicts: return "Inventory"
        case .detective, .suspects:  return "Investigate"
        case .health, .settings:     return "System"
        }
    }
}

/// How the inventory table is grouped.
enum GroupingMode: String, CaseIterable, Identifiable {
    case combo
    case owner
    case layer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .combo: return "By combo"
        case .owner: return "By owner"
        case .layer: return "By layer"
        }
    }
}

/// Everything the UI reads.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    @Published var destination: Destination = .home
    @Published private(set) var result = ScanResult()
    @Published private(set) var health = HealthReport(checks: [])
    @Published private(set) var isScanning = false
    @Published private(set) var scanPhase = ""
    @Published var settings: AppSettings {
        didSet { settingsStore.update { $0 = settings } }
    }

    // Inventory filters
    @Published var searchText = ""
    @Published var grouping: GroupingMode = .combo
    @Published var conflictsOnly = false
    @Published var enabledOnly = false
    @Published var layerFilter: Set<ClaimLayer> = []
    @Published var statusFilter: Set<ClaimStatus> = []
    @Published var selectedComboKey: String?

    // MARK: - Collaborators

    let attribution: AttributionStore
    let detective: DetectiveSession
    private let coordinator: ScanCoordinator
    private let settingsStore: SettingsStore
    private let adapterRegistry = AdapterRegistry()
    private var differential: DifferentialEngine?
    private var previouslyEnabledTapIDs: Set<UInt32> = []
    private var scanTask: Task<Void, Never>?

    init() {
        // One store, shared by the coordinator (which folds inferences into scans)
        // and the detective session (which records live captures into it).
        let store = AttributionStore()
        let settingsStore = SettingsStore()
        self.attribution = store
        self.detective = DetectiveSession(store: store)
        self.coordinator = ScanCoordinator(attribution: store)
        self.settingsStore = settingsStore
        self.settings = settingsStore.current

        // Show the last known inventory immediately rather than an empty window
        // while the first scan runs.
        let cached = ClaimDatabase().load()
        if !cached.isEmpty {
            let groups = ConflictAnalyzer.analyze(ClaimMerger.group(cached))
            result = ScanResult(
                claims: cached,
                groups: groups,
                conflicts: ConflictAnalyzer.conflicts(in: groups)
            )
        }
    }

    // MARK: - Scanning

    func rescan() {
        guard !isScanning else { return }
        scanTask?.cancel()

        isScanning = true
        scanPhase = "Collecting running applications…"

        let options = settings.scanOptions
        let context = ScanContext.capture(options: options)

        scanTask = Task { [weak self] in
            guard let self else { return }
            self.scanPhase = "Reading menus, configs and system shortcuts…"

            let scanResult = await self.coordinator.scan(context: context)
            guard !Task.isCancelled else { return }

            self.result = scanResult
            self.health = HealthChecker.run(
                eventTaps: scanResult.eventTaps,
                probeReport: scanResult.probeReport,
                previouslyEnabledTapIDs: self.previouslyEnabledTapIDs
            )
            self.previouslyEnabledTapIDs = Set(
                scanResult.eventTaps.filter(\.enabled).map(\.tapID)
            )

            if let report = scanResult.probeReport {
                self.settings.probingVerified = report.probingVerified
                self.settings.probingVerifiedAt = Date()
                self.startDifferentialLearning(baseline: report)
            }

            self.isScanning = false
            self.scanPhase = ""
        }
    }

    private func startDifferentialLearning(baseline: ProbeReport) {
        guard settings.differentialLearningEnabled else {
            differential?.stop()
            differential = nil
            return
        }
        if differential == nil {
            let engine = DifferentialEngine(store: attribution)
            engine.onAttributionChanged = { [weak self] in
                // New attributions only change inferred claims, so a full rescan is
                // wasteful — but the inventory does need to reflect them.
                MainActor.assumeIsolated { self?.refreshInferences() }
            }
            differential = engine
        }
        differential?.start(baseline: baseline)
    }

    private func refreshInferences() {
        let unattributed = result.claims
            .filter { $0.status == .probedClaimed }
            .map(\.combo)
        guard !unattributed.isEmpty else { return }

        let inferred = attribution.inferredClaims(for: unattributed)
        guard !inferred.isEmpty else { return }

        let merged = ClaimMerger.merge(result.claims + inferred)
        let groups = ConflictAnalyzer.analyze(ClaimMerger.group(merged))
        result = ScanResult(
            claims: merged,
            groups: groups,
            conflicts: ConflictAnalyzer.conflicts(in: groups),
            outcomes: result.outcomes,
            eventTaps: result.eventTaps,
            probeReport: result.probeReport,
            startedAt: result.startedAt,
            finishedAt: result.finishedAt
        )
    }

    // MARK: - Derived views of the data

    var filteredGroups: [ComboGroup] {
        var groups = result.groups

        if conflictsOnly {
            groups = groups.filter(\.hasConflict)
        }
        if enabledOnly {
            groups = groups.filter { group in group.claims.contains(where: \.enabled) }
        }
        if !layerFilter.isEmpty {
            groups = groups.filter { group in
                group.claims.contains { layerFilter.contains($0.layer) }
            }
        }
        if !statusFilter.isEmpty {
            groups = groups.filter { group in
                group.claims.contains { statusFilter.contains($0.status) }
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            groups = groups.filter { group in
                if group.combo.displayString.lowercased().contains(query) { return true }
                return group.claims.contains { claim in
                    claim.searchTokens.contains { $0.contains(query) }
                }
            }
        }

        return groups
    }

    var selectedGroup: ComboGroup? {
        guard let selectedComboKey else { return nil }
        return result.groups.first { $0.id == selectedComboKey }
    }

    /// Capability records — processes that *could* take a key, with no known binding.
    var capabilityClaims: [Claim] {
        result.claims.filter { $0.status == .capability }
    }

    // MARK: - Overview

    /// Two apps fighting over the same shortcut. The answer to "why does this do
    /// the wrong thing".
    ///
    /// Includes `.shadowed` as well as `.definite`: from the user's side, "macOS
    /// takes ⌃⌘S and Karabiner never gets it" is two apps fighting, whatever the
    /// analyzer calls the shape of it. Only `.contextual` is left out, because that
    /// one genuinely reads as "works everywhere except here" and has its own
    /// section.
    var appConflicts: [Conflict] {
        result.conflicts.filter {
            !$0.isSystemDefault && ($0.kind == .definite || $0.kind == .shadowed)
        }
    }

    /// Shortcuts that fire everywhere except where the user expects. The answer to
    /// "why does this work only sometimes".
    var intermittentConflicts: [Conflict] {
        result.conflicts.filter { !$0.isSystemDefault && $0.kind == .contextual }
    }

    /// Collisions between macOS's own shortcuts — real, but Apple's, and not what
    /// anyone opens the app to find out.
    var systemConflicts: [Conflict] {
        result.conflicts.filter(\.isSystemDefault)
    }

    var unknownOwnerGroups: [ComboGroup] {
        result.groups.filter { $0.conflict?.kind == .unattributed }
    }

    /// Health problems that specifically cause a working shortcut to stop or
    /// misfire, as opposed to Shortking's own permission state.
    var intermittencyWarnings: [HealthCheck] {
        health.checks.filter { check in
            guard check.status == .warning || check.status == .failing else { return false }
            return ["secure-input", "dead-taps", "option-hardening"].contains(check.id)
        }
    }

    /// Event taps grouped by the process that installed them.
    ///
    /// One process routinely installs several taps — universalaccessd has three —
    /// so a raw tap count and a process count are different numbers, and quoting
    /// one while showing the other is how "6 processes" ended up above a list of 21
    /// rows.
    struct TapProcess: Identifiable {
        var pid: Int32
        var owner: Owner
        var taps: [EventTapInfo]

        var id: Int32 { pid }

        /// Installs at least one enabled, active filter that asks for key events.
        var canSwallowKeys: Bool {
            taps.contains { $0.canSwallowKeys }
        }

        /// Sees key events, even if only to observe them.
        var watchesKeys: Bool {
            taps.contains { EventTapScanner.masksKeyEvents($0.eventMask) }
        }

        var hasDisabledTap: Bool {
            taps.contains { !$0.enabled }
        }
    }

    var tapProcesses: [TapProcess] {
        var byPID: [Int32: [EventTapInfo]] = [:]
        for tap in result.eventTaps {
            byPID[tap.tappingPID, default: []].append(tap)
        }

        return byPID.compactMap { pid, taps -> TapProcess? in
            guard let first = taps.first else { return nil }
            return TapProcess(pid: pid, owner: first.owner, taps: taps)
        }
        .sorted { lhs, rhs in
            // Most dangerous first: swallowers, then key watchers, then the rest.
            if lhs.canSwallowKeys != rhs.canSwallowKeys { return lhs.canSwallowKeys }
            if lhs.watchesKeys != rhs.watchesKeys { return lhs.watchesKeys }
            return lhs.owner.name.localizedStandardCompare(rhs.owner.name) == .orderedAscending
        }
    }

    var processesThatCanSwallowKeys: Int {
        tapProcesses.filter(\.canSwallowKeys).count
    }

    /// True when nothing on the overview needs the user's attention.
    var everythingLooksFine: Bool {
        appConflicts.isEmpty
            && intermittentConflicts.isEmpty
            && intermittencyWarnings.isEmpty
            && !result.claims.isEmpty
    }

    // MARK: - Instant verdict

    /// What Shortking can say about a combination without running anything.
    struct Verdict {
        enum Tone {
            case good
            case conflict
            case unknown
            case blocked
        }

        var tone: Tone
        var headline: String
        var detail: String
        /// Whether a live investigation would add anything.
        var offersInvestigation: Bool
    }

    /// The answer to "I pressed this and the wrong thing happened", straight from
    /// the inventory. Detective Mode is for when this isn't enough — which the
    /// verdict says explicitly rather than leaving the user to guess.
    func verdict(for combo: KeyCombo) -> Verdict {
        if combo.isRestrictedByOptionHardening {
            return Verdict(
                tone: .blocked,
                headline: "No app can claim \(combo.displayString)",
                detail: "Since macOS 15, shortcuts whose only modifiers are ⌥ or ⌥⇧ are refused "
                    + "system-wide as an anti-keylogging measure. If this one used to work, that "
                    + "is why — it is not a conflict, and rebinding the app won't help.",
                offersInvestigation: false
            )
        }

        guard let group = result.groups.first(where: { $0.combo == combo }) else {
            return Verdict(
                tone: .unknown,
                headline: "Nothing Shortking can see claims \(combo.displayString)",
                detail: "No config file, menu bar, preference domain or hotkey registration "
                    + "accounts for it. That points at the frontmost app's own handling, or at a "
                    + "tool that pattern-matches keys in its own code and registers nothing.",
                offersInvestigation: true
            )
        }

        if let conflict = group.conflict {
            switch conflict.kind {
            case .unattributed:
                return Verdict(
                    tone: .unknown,
                    headline: "Something holds \(combo.displayString), and it won't say what",
                    detail: conflict.explanation,
                    offersInvestigation: true
                )
            default:
                return Verdict(
                    tone: .conflict,
                    headline: conflict.kind == .contextual
                        ? "\(conflict.winner?.ownerName ?? "Something") takes \(combo.displayString) first"
                        : "\(combo.displayString) is claimed more than once",
                    detail: conflict.explanation,
                    offersInvestigation: true
                )
            }
        }

        guard let winner = group.winner else {
            return Verdict(
                tone: .unknown,
                headline: "\(combo.displayString) is claimed, but everything holding it is disabled",
                detail: "Every claim Shortking found on this combination is switched off, so "
                    + "pressing it should do nothing at all.",
                offersInvestigation: true
            )
        }

        return Verdict(
            tone: .good,
            headline: "\(winner.ownerName) has \(combo.displayString)",
            detail: [winner.label, winner.layer.explanation]
                .compactMap { $0 }
                .joined(separator: " — "),
            offersInvestigation: winner.confidence < 1.0
        )
    }

    var unattributedCount: Int {
        result.groups.filter { $0.conflict?.kind == .unattributed }.count
    }

    var runningApps: [RunningApp] {
        ScanContext.capture(options: .unprivileged).runningApps
    }

    var adapterStatuses: [AdapterRegistry.AdapterStatus] {
        adapterRegistry.statuses()
    }

    // MARK: - Actions

    func investigate(combo: KeyCombo) {
        detective.investigate(
            combo: combo,
            knownClaims: result.claims,
            probeReport: result.probeReport
        )
        destination = .detective
    }

    func startDetectiveCapture() {
        detective.startCapture(
            eventTaps: result.eventTaps,
            capabilityClaims: capabilityClaims,
            runningApps: runningApps
        )
    }

    func requestAccessibility() {
        AXBridge.requestTrust()
    }

    /// Whether Accessibility is granted *and* actually works.
    ///
    /// `AXIsProcessTrusted()` can flip to `true` the moment the grant lands while
    /// the process still cannot read anything, so onboarding waits on a real menu
    /// read rather than on the permission bit.
    var accessibilityWorks: Bool {
        AXBridge.canReadOwnMenuBar()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    /// Quits and reopens the app.
    ///
    /// macOS caches a process's Accessibility decision, so a grant made while
    /// Shortking is running often does not take effect until it restarts. Telling
    /// the user to quit and relaunch without giving them a way to do it — which is
    /// what the first version of onboarding did — is not acceptable.
    func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else {
            // Running as a bare executable: there is no bundle to reopen, so a
            // relaunch would just quit. Say so instead of silently terminating.
            Log.ui.warning("Relaunch requested but not running from an app bundle")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The delay lets this process exit first, so `open` does not simply
        // reactivate the instance that is on its way out.
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]

        do {
            try process.run()
        } catch {
            Log.ui.error("Failed to schedule relaunch: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    func openSettingsPane(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        if let url { NSWorkspace.shared.open(url) }
    }

    func revealStoreFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: StoreLocation.directory.path)
    }

    func resetAttribution() {
        attribution.reset()
        refreshInferences()
    }

    func clearCaches() {
        MenuCache().clear()
        TriageCache().clear()
    }

    /// Exports the inventory as Markdown — the format people paste into a bug report.
    func exportMarkdown() -> String {
        var lines = [
            "# Shortking inventory",
            "",
            "Generated \(ISO8601DateFormatter().string(from: Date()))",
            "",
            "\(result.claims.count) claims · \(result.conflicts.count) conflicts · "
                + "\(unattributedCount) unattributed",
            "",
            "| Combination | Layer | Owner | Label | Status | Confidence |",
            "|---|---|---|---|---|---|",
        ]

        for group in result.groups {
            for claim in group.claims {
                lines.append(
                    "| `\(group.combo.displayString)` | \(claim.layer.displayName) "
                        + "| \(claim.ownerName) | \(claim.label ?? "—") "
                        + "| \(claim.status.displayName) "
                        + "| \(String(format: "%.2f", claim.confidence)) |"
                )
            }
        }

        if !result.conflicts.isEmpty {
            lines.append(contentsOf: ["", "## Conflicts", ""])
            for conflict in result.conflicts {
                lines.append("- **\(conflict.combo.displayString)** "
                    + "(\(conflict.kind.displayName)) — \(conflict.explanation)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func copyExportToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(exportMarkdown(), forType: .string)
    }
}
