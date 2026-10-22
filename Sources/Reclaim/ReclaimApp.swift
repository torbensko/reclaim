import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ReclaimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: ReclaimStore
    @StateObject private var updates: UpdateController

    init() {
        let store = ReclaimStore()
        _store = StateObject(wrappedValue: store)
        _updates = StateObject(wrappedValue: UpdateController(store: store))
    }
    var body: some Scene {
        Window(BuildInformation.current.name, id: "reclaim") {
            ContentView(store: store)
                .frame(minWidth: 960, minHeight: 560)
                .task { await store.refresh() }
        }
        .defaultSize(width: 1100, height: 660)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(BuildInformation.current.name)") { BuildInformation.current.showAboutPanel() }
            }
            UpdateCommands(updates: updates, store: store)
            CommandGroup(after: .newItem) {
                Button("Refresh Storage") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(store.isBusy)
            }
        }
    }
}
