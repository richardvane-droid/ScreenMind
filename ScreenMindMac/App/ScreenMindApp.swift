import SwiftUI
import AppKit

/// macOS app entry point.
/// Configured as a menu-bar-only app (LSUIElement = YES in Info.plist).
@main
struct ScreenMindApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window — the UI lives in the status bar menu.
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock (belt-and-suspenders alongside Info.plist LSUIElement)
        NSApp.setActivationPolicy(.accessory)

        statusBarController = StatusBarController()
        statusBarController?.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.stopMonitoring()
    }
}
