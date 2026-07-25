import AppKit
import ShortkingKit
import SwiftUI

/// The non-conflict failure modes, plus Shortking's own ability to see the system.
///
/// Half the support burden for a tool like this is "the scan is empty" caused by a
/// grant that silently lapsed after an update, so this screen exists from day one
/// and is linked from the status bar.
struct HealthView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.health.checks.isEmpty {
                    EmptyStateView(
                        symbol: "stethoscope",
                        title: "No diagnostics yet",
                        message: "Run a scan to check permissions, secure input, event taps and "
                            + "the macOS Option-key restriction.",
                        actionTitle: "Scan now",
                        action: { state.rescan() }
                    )
                } else {
                    ForEach(state.health.checks) { check in
                        HealthCheckRow(check: check)
                    }
                }

                if !state.result.warnings.isEmpty {
                    incompleteSources
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var incompleteSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Incomplete sources")
                .font(.headline)
            Text("These sources did not finish, so the inventory below is partial. Shortking shows "
                + "what it has rather than pretending the gap does not exist.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(state.result.warnings, id: \.identifier) { outcome in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: outcome.timedOut ? "clock.badge.exclamationmark" : "xmark.circle")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.displayName).font(.callout.weight(.medium))
                        Text(outcome.error ?? "Timed out")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }
        }
    }
}

struct HealthCheckRow: View {
    @EnvironmentObject private var state: AppState
    let check: HealthCheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(check.title).font(.callout.weight(.semibold))
                    Spacer()
                    Text(check.status.displayName)
                        .font(.caption)
                        .foregroundStyle(color)
                }

                Text(check.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = check.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actionButton
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(check.status == .ok ? 0.05 : 0.1))
        )
    }

    @ViewBuilder
    private var actionButton: some View {
        switch check.action {
        case .requestAccessibility:
            Button("Grant Accessibility…") { state.requestAccessibility() }
                .controlSize(.small)
        case .openSettings(let pane):
            Button("Open System Settings…") { state.openSettingsPane(pane) }
                .controlSize(.small)
        case .revealPath(let path):
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            }
            .controlSize(.small)
        case .rescan:
            Button("Rescan") { state.rescan() }
                .controlSize(.small)
        case .noAction:
            EmptyView()
        }
    }

    private var symbol: String {
        switch check.status {
        case .ok:      return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failing: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch check.status {
        case .ok:      return .green
        case .warning: return .orange
        case .failing: return .red
        case .unknown: return .secondary
        }
    }
}
