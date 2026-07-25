import AppKit
import ShortkingKit
import SwiftUI

/// The screen the app opens on.
///
/// People launch Shortking for two reasons, and the overview is built around
/// exactly those:
///
/// 1. **A shortcut does the wrong thing.** The hero is the recorder — press the
///    keys, get an answer immediately from the inventory, escalate to Detective
///    Mode only when the inventory genuinely can't say.
/// 2. **A shortcut works only sometimes.** That is its own section, because the
///    causes are different: a global hotkey shadowing an app's own menu item,
///    secure input stuck on, a tap that quietly died.
///
/// macOS's own colliding defaults are deliberately *not* here. They are real, but
/// they are Apple's, there are dozens of them, and nobody opens this app to find
/// them — they live on the Conflicts screen with everything else.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var recorded: KeyCombo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                cards

                if !state.appConflicts.isEmpty {
                    fightingSection
                }
                if !state.intermittentConflicts.isEmpty || !state.intermittencyWarnings.isEmpty {
                    intermittentSection
                }
                if state.everythingLooksFine {
                    allClear
                }
                if state.result.claims.isEmpty {
                    emptyState
                }
            }
            .padding(28)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background { Palette.canvas }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Something not working?")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Press the shortcut that misbehaved. Shortking will tell you who has it.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
            }

            // The recorder sits in a material well rather than directly on the
            // gradient, so its controls keep system contrast.
            VStack(alignment: .leading, spacing: 12) {
                ComboRecorder(combo: $recorded, prompt: "Record shortcut")

                if let recorded {
                    verdictPanel(for: recorded)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            )
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Palette.gradient(Palette.hero) }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Palette.indigo.opacity(0.3), radius: 18, y: 8)
    }

    @ViewBuilder
    private func verdictPanel(for combo: KeyCombo) -> some View {
        let verdict = state.verdict(for: combo)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: verdict.tone))
                    .foregroundStyle(color(for: verdict.tone))
                Text(verdict.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !verdict.detail.isEmpty {
                Text(verdict.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if verdict.offersInvestigation {
                    Button {
                        state.investigate(combo: combo)
                    } label: {
                        Label("Investigate live", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Show every claim") {
                    state.selectedComboKey = combo.groupingKey
                    state.searchText = combo.displayString
                    state.destination = .inventory
                }
            }
            .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    private func symbol(for tone: AppState.Verdict.Tone) -> String {
        switch tone {
        case .good:     return "checkmark.circle.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        case .unknown:  return "questionmark.circle.fill"
        case .blocked:  return "hand.raised.fill"
        }
    }

    private func color(for tone: AppState.Verdict.Tone) -> Color {
        switch tone {
        case .good:     return Palette.mint
        case .conflict: return Palette.crimson
        case .unknown:  return Palette.violet
        case .blocked:  return Palette.amber
        }
    }

    // MARK: - Cards

    private var cards: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: 16)],
            spacing: 16
        ) {
            SummaryCard(
                title: "Apps fighting",
                value: fightingValue,
                caption: state.appConflicts.isEmpty ? "no app conflicts" : "claimed twice over",
                symbol: "bolt.trianglebadge.exclamationmark.fill",
                colors: state.appConflicts.isEmpty ? Palette.clear : Palette.conflict,
                actionTitle: "Review",
                action: { state.destination = .conflicts }
            )

            SummaryCard(
                title: "Unknown owners",
                value: unknownValue,
                caption: state.unknownOwnerGroups.isEmpty
                    ? "everything is accounted for"
                    : "held by an app I can't name",
                symbol: "questionmark.circle.fill",
                colors: state.unknownOwnerGroups.isEmpty ? Palette.clear : Palette.unknown,
                actionTitle: "Review",
                action: {
                    state.statusFilter = [.probedClaimed]
                    state.destination = .inventory
                }
            )

            SummaryCard(
                title: "Can swallow keys",
                value: swallowValue,
                caption: "filtering your keystrokes",
                symbol: "eye.fill",
                colors: Palette.watchers,
                actionTitle: "Review",
                action: { state.destination = .suspects }
            )

            SummaryCard(
                title: "Everything else",
                value: "\(state.result.groups.count) combos",
                caption: "in the full inventory",
                symbol: "keyboard.fill",
                colors: [Color(nsColor: .darkGray), Color(nsColor: .black).opacity(0.8)],
                actionTitle: "Browse",
                action: { state.destination = .inventory }
            )
        }
    }

    private var fightingValue: String {
        let count = state.appConflicts.count
        guard count > 0 else { return "None" }
        return "\(count) shortcut\(count == 1 ? "" : "s")"
    }

    private var unknownValue: String {
        let count = state.unknownOwnerGroups.count
        guard count > 0 else { return "None" }
        return "\(count) claimed"
    }

    private var swallowValue: String {
        let count = state.tapsThatCanSwallowKeys
        return "\(count) process\(count == 1 ? "" : "es")"
    }

    // MARK: - Sections

    private var fightingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Two apps want the same shortcut",
                subtitle: "Which one wins depends on registration order, so this can change "
                    + "between reboots.",
                actionTitle: "See all conflicts",
                action: { state.destination = .conflicts }
            )

            Panel {
                ForEach(Array(state.appConflicts.prefix(5).enumerated()), id: \.element.id) { index, conflict in
                    if index > 0 { Divider() }
                    ConflictSummaryRow(conflict: conflict)
                }
            }

            if state.appConflicts.count > 5 {
                Text("and \(state.appConflicts.count - 5) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var intermittentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Works only sometimes",
                subtitle: "These fire everywhere except where you expect them to — or stop "
                    + "working under conditions that come and go."
            )

            Panel {
                ForEach(
                    Array(state.intermittentConflicts.prefix(4).enumerated()),
                    id: \.element.id
                ) { index, conflict in
                    if index > 0 { Divider() }
                    ConflictSummaryRow(conflict: conflict)
                }

                ForEach(Array(state.intermittencyWarnings.enumerated()), id: \.element.id) { index, check in
                    if index > 0 || !state.intermittentConflicts.isEmpty { Divider() }
                    WarningSummaryRow(check: check)
                }
            }
        }
    }

    private var allClear: some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34))
                .foregroundStyle(Palette.mint)

            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing is fighting over your shortcuts")
                    .font(.headline)
                Text("Shortking found no app conflicts and nothing that would make a shortcut "
                    + "misfire. If one still misbehaves, record it above — the cause may be "
                    + "something that registers nothing and has to be caught in the act.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.mint.opacity(0.12))
        )
    }

    private var emptyState: some View {
        HStack(spacing: 16) {
            Image(systemName: state.isScanning ? "arrow.triangle.2.circlepath" : "exclamationmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(state.isScanning ? Palette.azure : Palette.amber)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.isScanning ? "Taking stock of your shortcuts…" : "Nothing scanned yet")
                    .font(.headline)
                Text(state.isScanning
                    ? "Reading menus, config files, system shortcuts and the probe map."
                    : "An empty inventory almost always means a permission grant lapsed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !state.isScanning {
                Button("Open Health") { state.destination = .health }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
    }
}

/// One conflict, compressed to what the user needs to recognise it.
struct ConflictSummaryRow: View {
    @EnvironmentObject private var state: AppState
    let conflict: Conflict

    var body: some View {
        HStack(spacing: 14) {
            KeyComboBadge(combo: conflict.combo)
                .frame(width: 132, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(claimants)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(conflict.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Investigate") {
                state.investigate(combo: conflict.combo)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// "BoltGPT vs Tuna" — the shape of the problem in three words.
    private var claimants: String {
        let involved = ([conflict.winner].compactMap { $0 }) + conflict.losers
        var seen = Set<String>()
        var names: [String] = []
        for claim in involved where seen.insert(claim.ownerName).inserted {
            names.append(claim.ownerName)
        }

        guard !names.isEmpty else { return "Unknown owner" }
        guard names.count <= 3 else {
            return names.prefix(2).joined(separator: " vs ") + " and \(names.count - 2) more"
        }
        return names.joined(separator: " vs ")
    }
}

/// A health warning that explains intermittent behaviour.
struct WarningSummaryRow: View {
    @EnvironmentObject private var state: AppState
    let check: HealthCheck

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.amber)
                .frame(width: 132, alignment: .leading)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                    .font(.callout.weight(.medium))
                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Details") { state.destination = .health }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
