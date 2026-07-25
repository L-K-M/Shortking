import ShortkingKit
import SwiftUI

@main
struct ShortkingApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Reachable from anywhere, not just onboarding: a permission grant made
            // while Shortking is running needs a fresh process before it takes
            // effect, and that shouldn't require hunting for the right screen.
            CommandGroup(after: .appInfo) {
                Button("Quit and Reopen") { state.relaunch() }
            }

            CommandGroup(after: .toolbar) {
                Button("Rescan") { state.rescan() }
                    .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Copy inventory as Markdown") { state.copyExportToPasteboard() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Reveal data folder") { state.revealStoreFolder() }
            }

            CommandGroup(replacing: .newItem) {}
        }
    }
}
