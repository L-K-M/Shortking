import AppKit
import ShortkingKit
import SwiftUI

/// Press the keys instead of describing them.
///
/// This is the fastest path from "⌘⇧G did the wrong thing" to an answer, so it
/// appears both in the inventory search field and at the top of Detective Mode.
///
/// One caveat is surfaced to the user rather than hidden: a combination held at the
/// WindowServer layer never reaches this window, so recording it here may fail —
/// and that failure is itself a finding. When recording times out we say so and
/// offer the manual path.
struct ComboRecorder: View {

    @Binding var combo: KeyCombo?
    var prompt: String = "Record shortcut"

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var didTimeOut = false
    @State private var timeoutTask: Task<Void, Never>?

    /// How long to listen before giving up.
    ///
    /// Long enough to switch focus and press deliberately; short enough that a
    /// forgotten recorder does not sit swallowing every keystroke in the app.
    private static let recordingTimeout: TimeInterval = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Group {
                    if let combo {
                        KeyComboBadge(combo: combo, size: .large)
                    } else {
                        Text(isRecording ? "Press the shortcut now — ⎋ cancels" : "No shortcut selected")
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 180, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isRecording ? Color.accentColor : Color.primary.opacity(0.15),
                            lineWidth: isRecording ? 2 : 1
                        )
                )

                Button(isRecording ? "Stop" : prompt) {
                    if isRecording { stopRecording() } else { startRecording() }
                }
                .keyboardShortcut(isRecording ? .cancelAction : .defaultAction)

                if combo != nil {
                    Button("Clear") {
                        combo = nil
                        didTimeOut = false
                    }
                }
            }

            if didTimeOut {
                Label(
                    "Nothing arrived. A shortcut claimed at the WindowServer layer never reaches "
                        + "this window — which already tells you it is claimed globally. Search for "
                        + "it by name instead, or run the Blackout test.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        didTimeOut = false
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Escape cancels rather than being recorded.
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stopRecording()
                return nil
            }

            let modifiers = Modifiers(cocoa: UInt64(event.modifierFlags.rawValue))
            guard !modifiers.isEmpty else {
                // A bare key is a keystroke, not a shortcut. Ignore and keep waiting.
                return nil
            }

            combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
            stopRecording()
            return nil  // swallow it so we do not also trigger something in our own UI
        }

        // `@MainActor` is load-bearing. `startRecording()` is an ordinary method on a
        // `View` struct, so it is not actor-isolated — only `body` is — and a bare
        // `Task` here would run the timeout on the cooperative pool. That path calls
        // `NSEvent.removeMonitor`, which is not thread-safe, and mutates `@State`
        // from off the main thread.
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.recordingTimeout * 1_000_000_000))
            guard !Task.isCancelled, isRecording else { return }
            didTimeOut = true
            stopRecording()
        }
    }

    private func stopRecording() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }
}
