import AppKit
import SwiftUI

@main
struct SnipikoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Snipiko", systemImage: "viewfinder") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        HotKeyManager.shared.registerAll()
        AppController.shared.refreshPermission()
        if !ScreenPermission.isGranted {
            WindowManager.shared.showPermission()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppController.shared.refreshPermission()
    }
}
