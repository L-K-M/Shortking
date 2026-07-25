import ShortkingKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingOnboarding = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
            // The status bar is a safe-area inset rather than a VStack sibling, so
            // it pins to the bottom of the pane and the content above it scrolls
            // underneath instead of being squeezed by it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    StatusBar()
                }
            }
            // Title and toolbar belong to the detail pane, not to the split view.
            .navigationTitle(state.destination.title)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        state.rescan()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.isScanning)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Re-read every source (⌘R)")
                }
            }
        }
        // An *ideal* size is what stops AppKit sizing the window to fit its content.
        // Without one, a long screen like Suspects reports a very tall ideal, the
        // window grows to match, and it snaps back every time the selection changes
        // — which is exactly what happened. `maxWidth`/`maxHeight` of `.infinity`
        // keep it freely resizable; the ideal is only consulted for the automatic
        // size.
        .frame(
            minWidth: 900,
            idealWidth: 1160,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(isPresented: $showingOnboarding)
                .environmentObject(state)
        }
        .onAppear {
            if !state.settings.hasCompletedOnboarding {
                showingOnboarding = true
            } else {
                state.rescan()
            }
        }
    }

    private var subtitle: String {
        switch state.destination {
        case .home:
            let count = state.appConflicts.count
            if state.result.claims.isEmpty { return "" }
            return count == 0
                ? "no app conflicts"
                : "\(count) app conflict\(count == 1 ? "" : "s")"
        case .inventory: return "\(state.result.groups.count) combinations"
        case .conflicts: return "\(state.result.conflicts.count) conflicts"
        case .suspects:  return "\(state.result.eventTaps.count) event taps"
        default:         return ""
        }
    }

    private var sidebar: some View {
        List(selection: $state.destination) {
            ForEach(sections) { section in
                Section(section.name) {
                    ForEach(section.destinations) { destination in
                        NavigationLink(value: destination) {
                            Label {
                                HStack {
                                    Text(destination.title)
                                    Spacer()
                                    if let badge = badge(for: destination) {
                                        Text(badge)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: destination.symbol)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    }

    /// A named group of sidebar destinations. A struct rather than a tuple because
    /// `ForEach` needs an `Identifiable` element or a key path, and key paths into
    /// tuple elements are not expressible in Swift.
    private struct SidebarSection: Identifiable {
        let name: String
        let destinations: [Destination]
        var id: String { name }
    }

    private var sections: [SidebarSection] {
        var order: [String] = []
        var grouped: [String: [Destination]] = [:]
        for destination in Destination.allCases {
            if grouped[destination.section] == nil { order.append(destination.section) }
            grouped[destination.section, default: []].append(destination)
        }
        return order.map { SidebarSection(name: $0, destinations: grouped[$0] ?? []) }
    }

    private func badge(for destination: Destination) -> String? {
        switch destination {
        case .inventory:
            return state.result.groups.isEmpty ? nil : "\(state.result.groups.count)"
        case .conflicts:
            return state.result.conflicts.isEmpty ? nil : "\(state.result.conflicts.count)"
        case .suspects:
            return state.result.eventTaps.isEmpty ? nil : "\(state.result.eventTaps.count)"
        case .health:
            let problems = state.health.problems.count
            return problems == 0 ? nil : "\(problems)"
        default:
            return nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.destination {
        case .home:      HomeView()
        case .inventory: InventoryView()
        case .conflicts: ConflictsView()
        case .detective: DetectiveView()
        case .suspects:  SuspectsView()
        case .health:    HealthView()
        case .settings:  SettingsView()
        }
    }
}

/// Permission health, inventory size, and the last scan — always visible, because
/// "the scan is empty" is almost always a lapsed grant and the answer should not be
/// two clicks away.
struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            ForEach(permissionChecks, id: \.id) { check in
                Label(check.title, systemImage: symbol(for: check.status))
                    .font(.caption)
                    .foregroundStyle(color(for: check.status))
                    .help(check.message)
            }

            Divider().frame(height: 12)

            if state.isScanning {
                ProgressView().controlSize(.small)
                Text(state.scanPhase.isEmpty ? "Scanning…" : state.scanPhase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !state.result.warnings.isEmpty {
                Button {
                    state.destination = .health
                } label: {
                    Label(
                        "\(state.result.warnings.count) source(s) incomplete",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }

            if state.result.finishedAt > state.result.startedAt {
                Text(state.result.finishedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var permissionChecks: [HealthCheck] {
        state.health.checks.filter { $0.id == "accessibility" || $0.id == "input-monitoring" }
    }

    private var summary: String {
        let claims = state.result.claims.filter(\.isBinding).count
        var parts = ["\(claims) claims", "\(state.result.conflicts.count) conflicts"]
        if state.unattributedCount > 0 {
            parts.append("\(state.unattributedCount) unattributed")
        }
        return parts.joined(separator: " · ")
    }

    private func symbol(for status: HealthCheck.Status) -> String {
        switch status {
        case .ok:      return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .failing: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(for status: HealthCheck.Status) -> Color {
        switch status {
        case .ok:      return .green
        case .warning: return .orange
        case .failing: return .red
        case .unknown: return .secondary
        }
    }
}
