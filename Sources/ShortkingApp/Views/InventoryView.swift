import ShortkingKit
import SwiftUI

/// The inventory, grouped by combination.
///
/// The unit of the UI is the *key combination*, not the claim, because that is the
/// user's mental model — "what happens when I press this" — and because conflicts
/// are only visible when the claims sit next to each other.
struct InventoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var recordedCombo: KeyCombo?
    @State private var showingRecorder = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                list
            }
            .frame(minWidth: 420)

            if let group = state.selectedGroup {
                ComboDetailView(group: group)
                    .frame(minWidth: 340)
            } else {
                EmptyStateView(
                    symbol: "sidebar.right",
                    title: "Select a combination",
                    message: "Pick a row to see every claim on it, which one wins, and the "
                        + "evidence behind each."
                )
                .frame(minWidth: 340)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by shortcut, app, or command…", text: $state.searchText)
                    .textFieldStyle(.plain)
                if !state.searchText.isEmpty {
                    Button {
                        state.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
                Button {
                    showingRecorder.toggle()
                } label: {
                    Image(systemName: "record.circle")
                }
                .buttonStyle(.plain)
                .help("Press the shortcut instead of typing it")
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )

            if showingRecorder {
                ComboRecorder(combo: $recordedCombo, prompt: "Record")
                    .onChange(of: recordedCombo) { _, combo in
                        guard let combo else { return }
                        state.searchText = combo.displayString
                        showingRecorder = false
                    }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: "Conflicts only", isOn: $state.conflictsOnly)
                    FilterChip(title: "Enabled only", isOn: $state.enabledOnly)

                    Divider().frame(height: 14)

                    ForEach(ClaimStatus.allCases, id: \.self) { status in
                        FilterChip(
                            title: status.displayName,
                            isOn: binding(for: status)
                        )
                    }

                    Divider().frame(height: 14)

                    ForEach(ClaimLayer.allCases, id: \.self) { layer in
                        FilterChip(
                            title: layer.displayName,
                            isOn: binding(for: layer)
                        )
                    }
                }
            }

            HStack {
                Picker("", selection: $state.grouping) {
                    ForEach(GroupingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                Spacer()

                Text("\(state.filteredGroups.count) of \(state.result.groups.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private func binding(for status: ClaimStatus) -> Binding<Bool> {
        Binding(
            get: { state.statusFilter.contains(status) },
            set: { isOn in
                if isOn { state.statusFilter.insert(status) } else { state.statusFilter.remove(status) }
            }
        )
    }

    private func binding(for layer: ClaimLayer) -> Binding<Bool> {
        Binding(
            get: { state.layerFilter.contains(layer) },
            set: { isOn in
                if isOn { state.layerFilter.insert(layer) } else { state.layerFilter.remove(layer) }
            }
        )
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if state.result.groups.isEmpty {
            EmptyStateView(
                symbol: "keyboard",
                title: state.isScanning ? "Scanning…" : "Nothing found yet",
                message: state.isScanning
                    ? "Reading menus, config files, system shortcuts and the probe map."
                    : "An empty inventory almost always means a permission grant lapsed. Check "
                        + "the Health screen first.",
                actionTitle: state.isScanning ? nil : "Open Health",
                action: state.isScanning ? nil : { state.destination = .health }
            )
        } else if state.filteredGroups.isEmpty {
            EmptyStateView(
                symbol: "line.3.horizontal.decrease.circle",
                title: "No matches",
                message: "Nothing matches the current search and filters.",
                actionTitle: "Clear filters",
                action: clearFilters
            )
        } else {
            switch state.grouping {
            case .combo: comboList
            case .owner: groupedList(by: { $0.ownerName })
            case .layer: groupedList(by: { $0.layer.displayName })
            }
        }
    }

    private var comboList: some View {
        List(selection: $state.selectedComboKey) {
            ForEach(state.filteredGroups) { group in
                ComboRow(group: group).tag(group.id)
            }
        }
        .listStyle(.inset)
    }

    /// The by-owner and by-layer views, which flatten to claims rather than groups.
    private func groupedList(by key: @escaping (Claim) -> String) -> some View {
        let claims = state.filteredGroups.flatMap(\.claims)
        var buckets: [String: [Claim]] = [:]
        for claim in claims { buckets[key(claim), default: []].append(claim) }

        return List(selection: $state.selectedComboKey) {
            ForEach(buckets.keys.sorted(), id: \.self) { bucket in
                Section("\(bucket) — \(buckets[bucket]?.count ?? 0)") {
                    ForEach(buckets[bucket] ?? []) { claim in
                        HStack(spacing: 10) {
                            KeyComboBadge(combo: claim.combo, size: .small)
                            Text(claim.label ?? claim.ownerName)
                                .lineLimit(1)
                            Spacer()
                            LayerBadge(layer: claim.layer, compact: true)
                            StatusChip(status: claim.status)
                        }
                        .tag(claim.combo.groupingKey)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func clearFilters() {
        state.searchText = ""
        state.conflictsOnly = false
        state.enabledOnly = false
        state.layerFilter = []
        state.statusFilter = []
    }
}

/// One combination in the inventory table.
struct ComboRow: View {
    let group: ComboGroup

    var body: some View {
        HStack(spacing: 12) {
            KeyComboBadge(combo: group.combo)
                .frame(width: 130, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(claimantSummary)
                    .lineLimit(1)
                if let label = group.winner?.label {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // The layer strip: which layers are involved, in order. With more than
            // one badge showing, the leftmost is the one that wins.
            HStack(spacing: 3) {
                ForEach(Array(Set(group.claims.map(\.layer))).sorted(), id: \.self) { layer in
                    LayerBadge(layer: layer, compact: true)
                }
            }

            if let conflict = group.conflict {
                ConflictChip(conflict: conflict)
            } else if group.claims.allSatisfy({ !$0.enabled }) {
                Label("Disabled", systemImage: "slash.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var claimantSummary: String {
        let owners = Array(Set(group.claims.map(\.ownerName))).sorted()
        switch owners.count {
        case 0:  return "No claimant"
        case 1:  return owners[0]
        default: return "\(owners.count) claimants — \(owners.prefix(2).joined(separator: ", "))…"
        }
    }
}
