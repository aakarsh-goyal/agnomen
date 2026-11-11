import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Folder dropped on the Dock icon, or `open -a Agnomen <folder>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let u = urls.first else { return }
        Task { @MainActor in _ = AppModel.shared.handleDrop(u) }
    }
}

struct AgnomenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Agnomen", id: "main") {
            ContentView()
        }
        .defaultSize(width: 940, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { AppModel.shared.chooseFolder() }.keyboardShortcut("o")
                Button("Undo Last Rename") { AppModel.shared.undoLastBatch() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
            }
        }
    }
}
