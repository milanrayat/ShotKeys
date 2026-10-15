import AppKit
import SwiftUI

@main
struct ShotKeysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            Image(systemName: state.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run(engine: AppState.shared.engine)
            return
        }
        AppState.shared.start()
    }
}
