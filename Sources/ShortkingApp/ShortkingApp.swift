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
