import AppKit
import ShortkingKit
import SwiftUI

/// First-run flow.
///
/// The first pane deliberately explains what Shortking *cannot* know, before the
/// user ever meets an "unknown owner" row. A tool that sets that expectation up
/// front reads as honest; one that doesn't reads as broken.
///
/// Two things here are load-bearing rather than cosmetic:
///
/// - **Every pane offers a way out.** Skip, Quit and — on the Accessibility pane —
///   Quit and Reopen. An onboarding sheet that tells you to relaunch the app while
///   giving you no way to do it is a trap, and this one used to be one.
/// - **The Accessibility state is live.** It polls a real menu read rather than the
///   permission bit, so the pane can tell "granted and working" apart from "granted
///   but this process still can't see anything", which is the state that actually
///   requires a relaunch.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @Binding var isPresented: Bool

    @State private var pageIndex = 0
    @State private var accessibilityWorks = false
    @State private var isTrusted = false
    @State private var didRequestGrant = false

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            // A plain switch rather than a TabView: on macOS a TabView draws its own
            // paging chrome, which competed with the buttons below and made the real
            // controls hard to find.
            Group {
                switch pageIndex {
                case 0: intro
                case 1: accessibility
                default: inputMonitoring
                }
            }
            .frame(height: 400, alignment: .top)

            Divider()
            footer
        }
        .frame(width: 640)
        // A `.task` loop rather than a Timer publisher: SwiftUI cancels it when the
        // sheet goes away, where a publisher stored on the struct would be
        // reconnected on every re-render and never torn down.
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func refresh() async {
        // `isTrusted` is a cheap TCC lookup and stays here; the functional check is
        // an Accessibility round trip with a one-second timeout, so it is awaited off
        // the main actor rather than blocking the sheet once a second.
        isTrusted = AXBridge.isTrusted
        accessibilityWorks = await state.accessibilityWorks
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Quit") { state.quit() }
                .help("Quit Shortking")

            Button("Skip") { finish() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            Text("\(pageIndex + 1) of \(pageCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if pageIndex > 0 {
                Button("Back") { pageIndex -= 1 }
            }

            if pageIndex < pageCount - 1 {
                Button("Next") { pageIndex += 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Start scanning") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    // MARK: - Pages

    private var intro: some View {
        page(
            symbol: "crown",
            title: "Shortking",
            summary: "Shortking answers two questions: what key combinations are claimed on this "
                + "machine, by whom and at what layer — and, when you press one and the wrong "
                + "thing happens, who ate it."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Label("It reads menus, system shortcuts, Services, user overrides and the config "
                    + "files of the usual suspects.", systemImage: "list.bullet")
                Label("It probes for combinations that are claimed but appear nowhere — the blind "
                    + "spot no other tool covers.", systemImage: "questionmark.circle")
                Label("What it cannot do: name the owner of every claim. Apps register hotkeys "
                    + "inside WindowServer with no way to list them, and event-tap tools register "
                    + "nothing at all. Shortking says “claimed, owner unknown” rather than "
                    + "quietly leaving those out — and then offers to find out.",
                    systemImage: "exclamationmark.circle")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibility: some View {
        page(
            symbol: "figure.wave",
            title: "Accessibility",
            summary: "Reading other apps' menu bars needs the Accessibility permission. Without it "
                + "the inventory is missing every menu key equivalent on the system."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                    Text(statusMessage)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout.weight(.medium))

                HStack(spacing: 10) {
                    prominent(!accessibilityWorks && !needsRelaunch) {
                        Button("Open Accessibility settings…") {
                            didRequestGrant = true
                            state.requestAccessibility()
                            state.openSettingsPane("Privacy_Accessibility")
                        }
                    }

                    // The way out of the state where the grant is ticked but this
                    // process still cannot use it.
                    prominent(needsRelaunch) {
                        Button("Quit and Reopen") { state.relaunch() }
                    }
                }

                if needsRelaunch {
                    Text("The permission is granted, but this copy of Shortking still can't read "
                        + "menus — macOS decides once per process and caches the answer. Reopening "
                        + "fixes it, and Shortking will come back to this screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The grant is tied to the app's code signature, so it can also lapse after "
                        + "an update. The Health screen checks this by actually reading a menu, not "
                        + "just by asking macOS, and tells you when the two disagree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var inputMonitoring: some View {
        page(
            symbol: "dot.radiowaves.left.and.right",
            title: "Input Monitoring (optional)",
            summary: "Detective Mode's live capture watches which process receives a hotkey at the "
                + "moment you press it. That needs Input Monitoring."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Everything else — the inventory, conflicts, the probe map, the suspect list "
                    + "— works without it. You can grant it later from the Health screen.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Input Monitoring settings…") {
                    state.openSettingsPane("Privacy_ListenEvent")
                }
            }
        }
    }

    // MARK: - Accessibility status

    /// Granted according to TCC, but this process cannot actually use it.
    private var needsRelaunch: Bool {
        isTrusted && !accessibilityWorks
    }

    private var statusSymbol: String {
        if accessibilityWorks { return "checkmark.circle.fill" }
        if needsRelaunch { return "arrow.clockwise.circle.fill" }
        return "circle"
    }

    private var statusColor: Color {
        if accessibilityWorks { return .green }
        if needsRelaunch { return .orange }
        return .secondary
    }

    private var statusMessage: String {
        if accessibilityWorks { return "Granted and working." }
        if needsRelaunch { return "Granted — reopen Shortking to start using it." }
        if didRequestGrant { return "Waiting for the grant. Tick Shortking in the list." }
        return "Not granted yet."
    }

    // MARK: - Layout

    /// Applies the prominent button style conditionally.
    ///
    /// `.bordered` and `.borderedProminent` are different types, so they cannot be
    /// selected with a ternary — this branches at the view level instead.
    @ViewBuilder
    private func prominent<Content: View>(
        _ isProminent: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isProminent {
            content().buttonStyle(.borderedProminent)
        } else {
            content().buttonStyle(.bordered)
        }
    }

    private func page<Content: View>(
        symbol: String,
        title: String,
        summary: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.title2.weight(.semibold))
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func finish() {
        state.settings.hasCompletedOnboarding = true
        isPresented = false
        state.rescan()
    }
}
