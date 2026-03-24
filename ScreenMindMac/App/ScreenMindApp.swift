import SwiftUI
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.screenmind.mac", category: "App")

@main
struct ScreenMindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏专用 app，不出现在 Dock
        NSApp.setActivationPolicy(.accessory)

        // 初始化状态栏控制器（内含 CaptureCoordinator）
        statusBarController = StatusBarController()

        // 启动监控（内部会检查屏幕录制权限）
        statusBarController?.startMonitoring()

        logger.info("ScreenMind launched (M2)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.stopMonitoring()
    }
}

// MARK: - Permission helper (shared utility)

enum PermissionHelper {
    /// 打开系统设置 -> 隐私与安全 -> 屏幕录制
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 显示权限被拒绝的提示 Alert
    static func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "ScreenMind 需要屏幕录制权限才能分析屏幕内容。\n请前往「系统设置 → 隐私与安全 → 屏幕录制」，启用 ScreenMind，然后重启应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }
}
