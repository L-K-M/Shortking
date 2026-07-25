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

/// A caption plus one chip per claim, each showing the layer, the owner, and the
/// function it binds — the label is what distinguishes two claims by the same owner.
struct ClaimChipRow: View {
    let caption: String
    let claims: [Claim]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)

            FlowingChips(claims: claims)
        }
    }
}

private struct FlowingChips: View {
    let claims: [Claim]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(claims) { claim in
            HStack(spacing: 4) {
                LayerBadge(layer: claim.layer, compact: true)
                Text(claim.ownerName)
                    .font(.caption)
                if let label = claim.label, !label.isEmpty {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct ConflictListRow: View {
    @EnvironmentObject private var state: AppState
    let conflict: Conflict

    /// Two claims from the same owner with the same label are one thing to the
    /// user, however many records back them — "macOS, macOS" is noise.
    private var dedupedLosers: [Claim] {
        var seen = Set<String>()
        return conflict.losers.filter { claim in
            seen.insert("\(claim.owner?.identity ?? claim.ownerName)|\(claim.label ?? "")").inserted
        }
    }

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
                // Long measures are hard to read; conflict explanations are prose,
                // not table cells, so they stop well short of the window edge.
                .frame(maxWidth: 720, alignment: .leading)

            if let suggestion = conflict.suggestion {
                Label(suggestion, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 720, alignment: .leading)
            }

            if let winner = conflict.winner {
                ClaimChipRow(caption: "Wins:", claims: [winner])
            }

            if !dedupedLosers.isEmpty {
                ClaimChipRow(caption: "Loses:", claims: dedupedLosers)
            }
        }
        .padding(.vertical, 8)
    }
}
