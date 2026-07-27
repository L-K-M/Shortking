import AppKit
import ShortkingKit
import SwiftUI

/// Every process that can intercept a keystroke.
///
/// `CGGetEventTapList` cannot tell us *which* combinations a tap consumes — the
/// binding lives only in that app's own code — but it gives an exact, authoritative
/// suspect list. Paired with static binary triage it covers apps that are not even
/// running.
///
/// Grouped by **process**, not by tap: one process routinely installs several taps
/// (universalaccessd installs three), so a flat list of taps made the overview's
/// process count look unrelated to what was on screen.
struct SuspectsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                explanation
                processSection
                capabilitySection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("Shortking cannot read which combinations they consume — event-tap tools "
                + "pattern-match in their own code and register nothing with the system — so this "
                + "is a suspect list, not an inventory. Their bindings show up in the inventory "
                + "only via their config files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Spells out the relationship between the counts, since the overview quotes
    /// the process figure and this screen shows the taps behind it.
    private var summary: String {
        let processes = state.tapProcesses
        guard !processes.isEmpty else {
            return "No event taps are installed. Nothing on this machine is filtering keystrokes "
                + "at the session or HID layer."
        }
        let swallowers = state.processesThatCanSwallowKeys
        let taps = state.result.eventTaps.count

        return "\(taps) event tap\(taps == 1 ? "" : "s") across \(processes.count) "
            + "process\(processes.count == 1 ? "" : "es"). "
            + (swallowers == 0
                ? "None of them can swallow a keystroke — they only observe."
                : "\(swallowers) can intercept and swallow keystrokes; the rest only observe, or "
                    + "watch the mouse.")
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(state.tapProcesses) { process in
                TapProcessCard(process: process)
            }
        }
    }

    private var capabilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capability triage (\(state.capabilityClaims.count))")
                .font(.headline)

            if state.capabilityClaims.isEmpty {
                Text("Enable “Scan installed app binaries” in Settings to list every installed "
                    + "app whose binary imports RegisterEventHotKey or CGEventTapCreate. This "
                    + "narrows hundreds of installed apps to the handful worth investigating, and "
                    + "it works on apps that are not running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(state.capabilityClaims) { claim in
                    HStack(alignment: .top, spacing: 10) {
                        if let owner = claim.owner {
                            OwnerIcon(owner: owner, size: 20)
                        } else {
                            Image(systemName: "app.dashed")
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(claim.ownerName).font(.callout.weight(.medium))
                            Text(claim.label ?? "Can claim keyboard shortcuts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(claim.evidence) { evidence in
                                Text(evidence.summary)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        LayerBadge(layer: claim.layer, compact: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
        }
    }
}

/// One process, with every tap it installed.
struct TapProcessCard: View {
    let process: AppState.TapProcess

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OwnerIcon(owner: process.owner, size: 22)

                Text(process.owner.name)
                    .font(.body.weight(.semibold))

                Text("pid \(process.pid)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)

                if let path = process.owner.path {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Reveal \(process.owner.name) in Finder")
                }

                if process.canSwallowKeys {
                    Label("Can swallow keystrokes", systemImage: "scissors")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.crimson)
                } else if process.watchesKeys {
                    Label("Watches keystrokes", systemImage: "ear")
                        .font(.caption)
                        .foregroundStyle(Palette.amber)
                } else {
                    Label("No key events", systemImage: "cursorarrow")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if process.hasDisabledTap {
                    Label("Has a disabled tap", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .help("A tap that is installed but not receiving events. Its shortcuts "
                            + "will not fire — usually a timeout or a code-signature change.")
                }
            }

            ForEach(process.taps) { tap in
                EventTapRow(tap: tap)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    process.canSwallowKeys ? Palette.crimson.opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
        )
    }
}

/// One tap belonging to a process.
struct EventTapRow: View {
    let tap: EventTapInfo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tap.tapPoint.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .frame(width: 118, alignment: .leading)

            // "Active filter" is the honest description: whether it can swallow a
            // *key* also depends on the mask, which the chips below spell out.
            Text(tap.isActiveFilter ? "active filter" : "listen only")
                .font(.caption2)
                .foregroundStyle(tap.isActiveFilter ? Palette.amber : .secondary)
                .frame(width: 78, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(tap.eventNames, id: \.self) { name in
                    Text(name)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
            }

            Spacer(minLength: 6)

            if !tap.enabled {
                Text("disabled")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red)
            }

            Text(tap.latencyDescription)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
