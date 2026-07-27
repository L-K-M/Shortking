import ShortkingKit
import SwiftUI

/// "I pressed ⌘⇧G and the wrong thing happened. Who ate it?"
///
/// Three techniques, each independently runnable, all feeding one verdict panel.
struct DetectiveView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // The session is an ObservableObject owned by AppState; observing it here
        // is what makes findings stream in live.
        DetectiveContent(session: state.detective)
    }
}

struct DetectiveContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: DetectiveSession
    @State private var combo: KeyCombo?
    @State private var blackoutDuration: Double = 10
    /// Set when a blackout has run *and finished*, which is what makes the
    /// "It worked" / "Still broken" answers mean anything.
    @State private var hasCompletedBlackout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                target
                if combo != nil || state.detective.combo != nil {
                    techniques
                    verdict
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Pinned, not scrolled with the content. The README promises this banner is
        // "visible the entire time"; as the first child of the ScrollView it scrolled
        // away after half a screen, taking the countdown and the Restore now button
        // with it — for the one state in this app that can leave a user unable to use
        // their keyboard shortcuts.
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.detective.blackoutActive {
                blackoutBanner
                    .padding(12)
                    .background(.bar)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: state.detective.blackoutActive)
        .onAppear {
            combo = session.combo
        }
        .onChange(of: state.detective.blackoutActive) { wasActive, isActive in
            if wasActive && !isActive { hasCompletedBlackout = true }
        }
        // Keeps the recorder in step when something else points the session at a
        // combination — the Overview's "Investigate live", say — while this screen is
        // already on show. The two guards are what stop it looping against the
        // recorder's own `onChange`, which calls back into `investigate`.
        .onChange(of: session.combo) { _, newValue in
            if let newValue, newValue != combo { combo = newValue }
        }
    }

    // MARK: - Target

    private var target: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which shortcut misbehaved?")
                .font(.title3.weight(.semibold))

            ComboRecorder(combo: $combo)
                .onChange(of: combo) { _, newValue in
                    guard let newValue else { return }
                    state.detective.investigate(
                        combo: newValue,
                        knownClaims: state.result.claims,
                        probeReport: state.result.probeReport
                    )
                }

            if let error = state.detective.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Techniques

    private var techniques: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Techniques")
                .font(.headline)

            TechniqueCard(
                title: "Live capture",
                symbol: "dot.radiowaves.left.and.right",
                summary: "Attaches listen-only taps to every process that could take a keystroke, "
                    + "then waits for you to press it. When WindowServer matches a hotkey it "
                    + "delivers a system-defined event to exactly one process — that process is "
                    + "your answer, by name.",
                requirement: "Needs Input Monitoring."
            ) {
                HStack {
                    if state.detective.isCapturing {
                        Button("Stop listening") { state.detective.stopCapture() }
                            .buttonStyle(.borderedProminent)
                        ProgressView().controlSize(.small)
                        Text("Listening on "
                            + Plural.count(state.detective.capturedProcessCount, "process")
                            + " — press the shortcut now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Start listening") { state.startDetectiveCapture() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            TechniqueCard(
                title: "Blackout test",
                symbol: "power",
                summary: "Turns every WindowServer hotkey off for a few seconds and asks you to "
                    + "try again. If the shortcut suddenly works, a hotkey registered with "
                    + "WindowServer was eating it. If it still doesn't, the cause is an event tap, "
                    + "a Karabiner remap, secure input, or the app itself.",
                requirement: state.detective.blackout.isSupported
                    ? "Accessibility shortcuts stay enabled throughout."
                    : "Unavailable — the required SkyLight symbols are missing on this macOS build."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Disable hotkeys for \(Int(blackoutDuration))s") {
                            state.detective.startBlackout(duration: blackoutDuration)
                        }
                        .disabled(!state.detective.blackout.isSupported
                            || state.detective.blackoutActive)

                        Slider(value: $blackoutDuration, in: 5...30, step: 5)
                            .frame(width: 140)
                    }

                    // Disabled until a blackout has actually run and restored.
                    // These record a finding at 0.85 confidence, and answering
                    // "It worked" about a test that never happened puts a
                    // confident, wrong conclusion into the verdict panel.
                    HStack {
                        Text("After trying it:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("It worked") {
                            state.detective.reportBlackoutResult(shortcutWorked: true)
                        }
                        .controlSize(.small)
                        Button("Still broken") {
                            state.detective.reportBlackoutResult(shortcutWorked: false)
                        }
                        .controlSize(.small)
                    }
                    .disabled(!hasCompletedBlackout)

                    if !hasCompletedBlackout {
                        Text("Available once a blackout has run and hotkeys are back on.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            TechniqueCard(
                title: "Identify by restart",
                symbol: "arrow.triangle.2.circlepath",
                summary: "When nothing live works, Shortking narrows the owner down by watching "
                    + "which combinations free up as apps quit. It binary-searches the suspects, "
                    + "so it takes log₂(n) restarts rather than one per app. Suspending a process "
                    + "does not work — WindowServer registrations are held by the connection, not "
                    + "the running thread — so the apps have to actually quit.",
                requirement: "No permissions needed."
            ) {
                IdentificationPlan(combo: combo ?? state.detective.combo)
            }
        }
    }

    // MARK: - Verdict

    private var verdict: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Findings")
                .font(.headline)

            if state.detective.findings.isEmpty {
                Text("Nothing yet. Run one of the techniques above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.detective.findings) { finding in
                    FindingRow(finding: finding)
                }
            }
        }
    }

    private var blackoutBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Global hotkeys are disabled")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Restoring automatically in \(state.detective.blackoutRemaining)s. "
                    + "Accessibility shortcuts are unaffected.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
            Button("Restore now") { state.detective.endBlackout() }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.red)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red))
    }
}

struct TechniqueCard<Controls: View>: View {
    let title: String
    let symbol: String
    let summary: String
    let requirement: String
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))

            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(requirement)
                .font(.caption)
                .foregroundStyle(.tertiary)

            controls()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

struct FindingRow: View {
    let finding: DetectiveSession.Finding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(finding.headline)
                        .font(.callout.weight(.medium))
                    Spacer()
                    ConfidenceMeter(confidence: finding.confidence, showLabel: false)
                }
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }

    private var symbol: String {
        switch finding.kind {
        case .named:          return "checkmark.seal.fill"
        case .classification: return "arrow.triangle.branch"
        case .sideChannel:    return "waveform"
        case .blackout:       return "power"
        case .inventory:      return "list.bullet"
        case .note:           return "info.circle"
        }
    }

    private var color: Color {
        switch finding.kind {
        case .named:          return .green
        case .classification: return .blue
        case .sideChannel:    return .purple
        case .blackout:       return .orange
        case .inventory:      return .secondary
        case .note:           return .secondary
        }
    }
}

/// The restart plan for the differential search.
struct IdentificationPlan: View {
    @EnvironmentObject private var state: AppState
    let combo: KeyCombo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let combo {
                let step = DifferentialEngine.planIdentification(combo: combo, suspects: suspects)
                Text(step.instruction)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if step.remainingRestarts > 0 {
                    Text("Estimated "
                        + Plural.count(step.remainingRestarts, "quit/relaunch cycle")
                        + " across " + Plural.count(suspects.count, "suspect") + ".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Shortking also learns this passively: every time an app launches or quits it "
                    + "re-probes and records what changed, so this map fills itself in over a few "
                    + "days of ordinary use.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Choose a shortcut first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var suspects: [Owner] {
        var seen = Set<String>()
        var owners: [Owner] = []
        for claim in state.capabilityClaims {
            guard let owner = claim.owner, seen.insert(owner.identity).inserted else { continue }
            owners.append(owner)
        }
        return owners.sorted { $0.name < $1.name }
    }
}
