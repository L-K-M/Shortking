import ShortkingKit
import SwiftUI

/// Every process that can intercept a keystroke.
///
/// `CGGetEventTapList` cannot tell us *which* combinations a tap consumes — the
/// binding lives only in that app's own code — but it gives an exact, authoritative
/// suspect list. Paired with static binary triage it covers apps that are not even
/// running.
struct SuspectsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                explanation
                tapSection
                capabilitySection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var explanation: some View {
        Text("These processes can see or swallow your keystrokes. Shortking cannot read what "
            + "combinations they consume — event-tap tools pattern-match in their own code and "
            + "register nothing with the system — so this is a suspect list, not an inventory. "
            + "Their bindings show up in the inventory only via their config files.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var tapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active event taps (\(state.result.eventTaps.count))")
                .font(.headline)

            if state.result.eventTaps.isEmpty {
                Text("No event taps installed. Nothing on this machine is filtering keystrokes "
                    + "at the session or HID layer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.result.eventTaps) { tap in
                    EventTapRow(tap: tap)
                }
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
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.secondary)
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

struct EventTapRow: View {
    let tap: EventTapInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(tap.owner.name)
                    .font(.callout.weight(.medium))

                Text(tap.tapPoint.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))

                if tap.isActiveFilter {
                    Label("Can swallow keys", systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("Listen only", systemImage: "ear")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !tap.enabled {
                    Label("Disabled", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .help("This tap is installed but not receiving events, so its shortcuts "
                            + "will not fire. Usually a timeout or a code-signature change.")
                }
            }

            HStack(spacing: 6) {
                ForEach(tap.eventNames, id: \.self) { name in
                    Text(name)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
            }

            HStack(spacing: 14) {
                Text("pid \(tap.tappingPID)")
                if tap.tappedPID != 0 {
                    Text("tapping pid \(tap.tappedPID)")
                }
                Text(tap.latencyDescription)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tap.enabled ? Color.clear : Color.red.opacity(0.4), lineWidth: 1)
        )
    }
}
