import ShortkingKit
import SwiftUI

/// First-run flow.
///
/// The first pane deliberately explains what Shortking *cannot* know, before the
/// user ever meets an "unknown owner" row. A tool that sets that expectation up
/// front reads as honest; one that doesn't reads as broken.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @Binding var isPresented: Bool
    @State private var pageIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $pageIndex) {
                intro.tag(0)
                accessibility.tag(1)
                inputMonitoring.tag(2)
            }
            .tabViewStyle(.automatic)
            .frame(height: 380)

            Divider()

            HStack {
                Button("Skip") { finish() }
                Spacer()
                Text("\(pageIndex + 1) of 3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if pageIndex < 2 {
                    Button("Next") { pageIndex += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Start scanning") { finish() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
        }
        .frame(width: 620)
    }

    private var intro: some View {
        page(
            symbol: "crown",
            title: "Shortking",
            body: "Shortking answers two questions: what key combinations are claimed on this "
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
            body: "Reading other apps' menu bars needs the Accessibility permission. Without it "
                + "the inventory is missing every menu key equivalent on the system."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: AXBridge.isTrusted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(AXBridge.isTrusted ? .green : .secondary)
                    Text(AXBridge.isTrusted ? "Granted" : "Not granted yet")
                }
                Button("Open Accessibility settings…") { state.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                Text("You may need to quit and reopen Shortking after granting it. macOS ties the "
                    + "grant to the app's code signature, so it also lapses after some updates — "
                    + "the Health screen detects that and tells you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var inputMonitoring: some View {
        page(
            symbol: "dot.radiowaves.left.and.right",
            title: "Input Monitoring (optional)",
            body: "Detective Mode's live capture watches which process receives a hotkey at the "
                + "moment you press it. That needs Input Monitoring."
        ) {
            VStack(alignment: .leading, spacing: 10) {
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

    private func page<Content: View>(
        symbol: String,
        title: String,
        body: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.title2.weight(.semibold))
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
            Spacer()
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
