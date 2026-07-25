import AppKit
import Combine
import Foundation
import ShortkingKit
import SwiftUI

/// The sidebar destinations.
enum Destination: String, Hashable, CaseIterable, Identifiable {
    case inventory
    case conflicts
    case detective
    case suspects
    case health
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
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

    @Published var destination: Destination = .inventory
    @Published private(set) var result = ScanResult()
    @Published private(set) var health = HealthReport(checks: [])
    @Published private(set) var isScanning = false
    @Published private(set) var scanPhase = ""
    @Published var settings: Settings {
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
    private let settingsStore = SettingsStore()
    private let adapterRegistry = AdapterRegistry()
    private var differential: DifferentialEngine?
    private var previouslyEnabledTapIDs: Set<UInt32> = []
    private var scanTask: Task<Void, Never>?

    init() {
        // One store, shared by the coordinator (which folds inferences into scans)
        // and the detective session (which records live captures into it).
        let store = AttributionStore()
        self.attribution = store
        self.detective = DetectiveSession(store: store)
        self.coordinator = ScanCoordinator(attribution: store)
        self.settings = SettingsStore().current

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
