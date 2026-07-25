import ShortkingKit
import SwiftUI

/// Conflicts, sorted by severity, each with an explanation and an advisory fix.
///
/// Shortking never rebinds anything itself — it tells you what is happening and
/// where to change it.
struct ConflictsView: View {
    @EnvironmentObject private var state: AppState
    @State private var kindFilter: Set<Conflict.Kind> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if filtered.isEmpty {
                EmptyStateView(
                    symbol: state.result.conflicts.isEmpty
                        ? "checkmark.seal"
                        : "line.3.horizontal.decrease.circle",
                    title: state.result.conflicts.isEmpty ? "No conflicts found" : "No matches",
                    message: state.result.conflicts.isEmpty
                        ? "Nothing Shortking can see is fighting over a key combination. Note that "
                            + "event-tap tools bind in their own code, so their shortcuts are only "
                            + "visible through their config files — check Suspects for processes "
                            + "that could still be intercepting keys."
                        : "No conflicts of the selected kinds."
                )
            } else {
                List {
                    ForEach(filtered) { conflict in
                        ConflictListRow(conflict: conflict)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForEach(Conflict.Kind.allCases, id: \.self) { kind in
                    FilterChip(
                        title: "\(kind.displayName) (\(count(of: kind)))",
                        isOn: Binding(
                            get: { kindFilter.contains(kind) },
                            set: { isOn in
                                if isOn { kindFilter.insert(kind) } else { kindFilter.remove(kind) }
                            }
                        )
                    )
                }
                Spacer()
                Button {
                    state.copyExportToPasteboard()
                } label: {
                    Label("Copy report", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            Text(legend)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var legend: String {
        "Lower dispatch layers win: a shortcut matched inside WindowServer never reaches an app's "
            + "menu bar. Layer numbers are shown on every badge."
    }

    private func count(of kind: Conflict.Kind) -> Int {
        state.result.conflicts.filter { $0.kind == kind }.count
    }

    private var filtered: [Conflict] {
        guard !kindFilter.isEmpty else { return state.result.conflicts }
        return state.result.conflicts.filter { kindFilter.contains($0.kind) }
    }
}

struct ConflictListRow: View {
    @EnvironmentObject private var state: AppState
    let conflict: Conflict

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                KeyComboBadge(combo: conflict.combo)
                ConflictChip(conflict: conflict)
                Spacer()
                Button("Investigate") {
                    state.investigate(combo: conflict.combo)
                }
                .controlSize(.small)
            }

            Text(conflict.explanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let suggestion = conflict.suggestion {
                Label(suggestion, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let winner = conflict.winner {
                HStack(spacing: 8) {
                    Text("Wins:").font(.caption).foregroundStyle(.tertiary)
                    LayerBadge(layer: winner.layer, compact: true)
                    Text(winner.ownerName).font(.caption)
                }
            }

            if !conflict.losers.isEmpty {
                HStack(spacing: 8) {
                    Text("Loses:").font(.caption).foregroundStyle(.tertiary)
                    ForEach(conflict.losers) { loser in
                        HStack(spacing: 4) {
                            LayerBadge(layer: loser.layer, compact: true)
                            Text(loser.ownerName).font(.caption)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
