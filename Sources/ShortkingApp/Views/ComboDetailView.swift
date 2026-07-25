import AppKit
import ShortkingKit
import SwiftUI

/// Everything known about one combination: who claims it, which one wins, and the
/// evidence behind each claim.
struct ComboDetailView: View {
    @EnvironmentObject private var state: AppState
    let group: ComboGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let conflict = group.conflict {
                    ConflictCard(conflict: conflict)
                }

                claimsSection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyComboBadge(combo: group.combo, size: .large)

            if let winner = group.winner {
                Label {
                    Text("**\(winner.ownerName)** wins this combination at the "
                        + "\(winner.layer.displayName) layer.")
                } icon: {
                    Image(systemName: "trophy")
                }
                .font(.callout)
            }

            HStack {
                Button {
                    state.investigate(combo: group.combo)
                } label: {
                    Label("Investigate", systemImage: "magnifyingglass")
                }

                Button {
                    copyToPasteboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var claimsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Plural.count(group.claims.count, "claim"))
                .font(.headline)

            ForEach(group.claims) { claim in
                ClaimCard(claim: claim, isWinner: claim.id == group.winner?.id)
            }
        }
    }

    private func copyToPasteboard() {
        var lines = ["\(group.combo.displayString)"]
        for claim in group.claims {
            lines.append(
                "  \(claim.layer.rawValue) \(claim.layer.displayName) · \(claim.ownerName) · "
                    + "\(claim.label ?? "—") · \(claim.status.displayName)"
            )
            for evidence in claim.evidence {
                lines.append("      \(evidence.kind.displayName): \(evidence.summary)")
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

struct ClaimCard: View {
    let claim: Claim
    var isWinner = false

    @State private var showingEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(claim.ownerName)
                    .font(.body.weight(.medium))
                if isWinner {
                    Image(systemName: "trophy.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("This is the claim that actually fires.")
                }
                Spacer()
                if !claim.enabled {
                    Label("Disabled", systemImage: "slash.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                StatusChip(status: claim.status)
            }

            if let label = claim.label {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                LayerBadge(layer: claim.layer)
                ConfidenceMeter(confidence: claim.confidence)
                Spacer()
            }

            if claim.status == .probedClaimed {
                Text("Nothing in any config file, menu bar, or preference domain accounts for this "
                    + "claim. Shortking knows it exists because registering the combination was "
                    + "refused — but not who holds it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !claim.evidence.isEmpty {
                DisclosureGroup(isExpanded: $showingEvidence) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(claim.evidence) { evidence in
                            EvidenceRow(evidence: evidence)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Evidence (\(claim.evidence.count))")
                        .font(.caption.weight(.medium))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    claim.status == .probedClaimed ? Color.orange.opacity(0.5) : Color.clear,
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
        )
    }
}

struct EvidenceRow: View {
    let evidence: Evidence

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(evidence.kind.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(evidence.kind.isDirect ? Color.green : Color.blue)
                Text(evidence.summary)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            ForEach(evidence.detail.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 6) {
                    Text(key)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(width: 100, alignment: .leading)
                    Text(evidence.detail[key] ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 4)
    }
}

struct ConflictCard: View {
    @EnvironmentObject private var state: AppState
    let conflict: Conflict

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ConflictChip(conflict: conflict)
                Spacer()
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

            if conflict.kind == .unattributed {
                Button {
                    state.investigate(combo: conflict.combo)
                } label: {
                    Label("Find out who owns it", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
    }
}
