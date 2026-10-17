import SwiftUI

@main
struct GHWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore.shared

    var body: some Scene {
        Window("GH Watcher", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh All") { store.refreshAll() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            CommandMenu("Go") {
                Button("Overview") { store.selection = .overview }.keyboardShortcut("1")
                Button("Inbox") { store.selection = .inbox }.keyboardShortcut("2")
                Button("My Pull Requests") { store.selection = .myPRs }.keyboardShortcut("3")
                Button("Review Requests") { store.selection = .reviews }.keyboardShortcut("4")
                Button("Live Feed") { store.selection = .feed }.keyboardShortcut("5")
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if SelfTest.requested {
                NSApp.setActivationPolicy(.prohibited)
                Task { await SelfTest.run() }
                return
            }
            if Snapshot.requested {
                Task { await Snapshot.run() }
                return
            }
            let store = AppStore.shared
            store.notifier.activate()
            store.applyDockPreference()
            Task { await store.bootstrap() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppStore.shared.activateMainWindow() } }
        return true
    }
}
