import AppKit
import ShortkingKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            Section("Scan scope") {
                Toggle("Read menu bars (Accessibility)", isOn: binding(\.includeMenus))
                Toggle("Frontmost app only", isOn: binding(\.menusForFrontmostOnly))
                    .disabled(!state.settings.scanOptions.includeMenus)
                    .help("Menus are the slow part of a scan. On a machine with many running "
                        + "apps this keeps rescans instant.")
                Toggle("macOS system shortcuts", isOn: binding(\.includeSymbolicHotKeys))
                Toggle("User-assigned App Shortcuts", isOn: binding(\.includeUserKeyEquivalents))
                Toggle("Services", isOn: binding(\.includeServices))
                Toggle("Input sources", isOn: binding(\.includeInputSources))
                Toggle("Event taps", isOn: binding(\.includeEventTaps))
                Toggle("Third-party config files", isOn: binding(\.includeConfigAdapters))
                Toggle("Sniff app preferences for shortcut libraries",
                       isOn: binding(\.includeGenericPreferences))
                    .help("Scans every preference domain for MASShortcut, ShortcutRecorder and "
                        + "KeyboardShortcuts storage signatures — hotkeys from hundreds of apps "
                        + "for the price of three parsers.")
                Toggle("Scan installed app binaries (slow)", isOn: binding(\.includeBinaryTriage))
                    .help("Runs nm on every installed app to find which ones can claim a global "
                        + "hotkey at all. Cached by file, so only the first run is slow.")
            }

            Section("Hotkey probing") {
                Toggle("Probe for claimed combinations", isOn: binding(\.includeProbe))
                Picker("Breadth", selection: binding(\.probeBreadth)) {
                    ForEach(ProbeBreadth.allCases, id: \.self) { breadth in
                        Text("\(breadth.displayName) — "
                            + "\(ProbeSpace.estimatedProbeCount(for: breadth)) probes")
                            .tag(breadth)
                    }
                }
                .disabled(!state.settings.scanOptions.includeProbe)

                Text("Probing registers each combination for a moment and releases it immediately, "
                    + "in a separate short-lived process so a crash cannot leave your keyboard "
                    + "hijacked. A refusal means someone else holds it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let verified = state.settings.probingVerified {
                    Label(
                        verified
                            ? "Verified on this machine: duplicate registration is refused."
                            : "This macOS build permits duplicate registration, so probe results "
                                + "are hidden rather than shown wrongly.",
                        systemImage: verified ? "checkmark.seal" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(verified ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Attribution") {
                Toggle("Learn owners from app launch and quit",
                       isOn: $state.settings.differentialLearningEnabled)
                Text("When an app launches or quits, Shortking re-probes and records which "
                    + "combinations changed hands. After a few days of ordinary use this "
                    + "attributes the WindowServer layer on its own — using only public API, with "
                    + "no cooperation from any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("\(state.attribution.observations.count) observation(s) recorded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget everything", role: .destructive) {
                        showingResetConfirmation = true
                    }
                    .controlSize(.small)
                }
            }

            Section("Config adapters") {
                ForEach(state.adapterStatuses) { adapter in
                    HStack {
                        Image(systemName: adapter.isDetected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(adapter.isDetected ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(adapter.displayName)
                            Text(adapter.isDetected
                                ? adapter.paths.map(abbreviate).joined(separator: ", ")
                                : "Not installed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                Text("Adapters are a filter-list, not a release: adding support for another tool "
                    + "is a new parser and a pull request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Data") {
                HStack {
                    Text(StoreLocation.directory.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") { state.revealStoreFolder() }
                        .controlSize(.small)
                }

                HStack {
                    Button("Copy inventory as Markdown") { state.copyExportToPasteboard() }
                        .controlSize(.small)
                    Button("Clear caches") { state.clearCaches() }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Forget all learned attributions?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget everything", role: .destructive) { state.resetAttribution() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every launch/quit observation Shortking has accumulated. Owners it "
                + "inferred will go back to “unknown” until it relearns them.")
        }
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<ScanOptions, Value>
    ) -> Binding<Value> {
        Binding(
            get: { state.settings.scanOptions[keyPath: keyPath] },
            set: { state.settings.scanOptions[keyPath: keyPath] = $0 }
        )
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
