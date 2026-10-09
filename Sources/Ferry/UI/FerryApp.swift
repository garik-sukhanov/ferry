import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новый сервер…") { state.newServer() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Обновить") { state.currentSession?.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(state.currentSession == nil)
                Button("Наверх") { state.currentSession?.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(state.currentSession == nil)
            }
        }
    }
}
