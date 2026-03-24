import AppKit
import ScreenMindCore
import OSLog

private let logger = Logger(subsystem: "com.screenmind.mac", category: "StatusBar")

/// 持有 NSStatusItem 并驱动完整监控管道。
/// M2: 接入 CaptureCoordinator，验证 OCR 输出。
/// M3: AnxietyScorer 将在此接入。
@MainActor
final class StatusBarController {

    // MARK: - Status item
    private let statusItem: NSStatusItem

    // MARK: - Pipeline
    private let coordinator = CaptureCoordinator()

    // MARK: - 调试窗口（M2 用）
    private var debugWindowController: DebugWindowController?

    // MARK: - Init

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setupMenu()
        updateIcon(state: .idle)

        // 监听 OCR 结果（M3 会在这里接入焦虑分析）
        coordinator.onResult = { [weak self] result in
            self?.handlePipelineResult(result)
        }
    }

    // MARK: - Monitoring lifecycle

    func startMonitoring() {
        Task {
            await coordinator.start()
            updateIcon(state: coordinator.permissionGranted ? .monitoring : .error)
        }
    }

    func stopMonitoring() {
        coordinator.stop()
        updateIcon(state: .idle)
    }

    func pauseMonitoring(minutes: Int = 15) {
        coordinator.pause(minutes: minutes)
        updateIcon(state: .paused)
    }

    // MARK: - Pipeline result handler

    private func handlePipelineResult(_ result: PipelineResult) {
        let app = result.frontAppName ?? "未知应用"
        let chars = result.ocrResult.text.count
        let lang = result.ocrResult.language.rawValue
        logger.info("OCR [\(app)] \(chars) chars, lang=\(lang), \(result.ocrResult.durationMs)ms")

        // 转发到调试窗口（如已打开）
        debugWindowController?.appendLog(result)

        // TODO M3: 传给 AnxietyScorer
    }

    // MARK: - Menu

    private func setupMenu() {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "ScreenMind", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let pauseItem = NSMenuItem(title: "暂停 15 分钟",
                                   action: #selector(pauseTapped),
                                   keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let debugItem = NSMenuItem(title: "OCR 调试窗口",
                                   action: #selector(openDebug),
                                   keyEquivalent: "d")
        debugItem.target = self
        menu.addItem(debugItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "偏好设置…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ScreenMind",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        statusItem.menu = menu
    }

    // MARK: - Icon states

    enum IconState { case idle, monitoring, paused, error, anxious }

    private func updateIcon(state: IconState) {
        let (symbolName, color): (String, NSColor) = switch state {
        case .idle:       ("brain.head.profile",      .secondaryLabelColor)
        case .monitoring: ("brain.head.profile",      .controlTextColor)
        case .paused:     ("brain.head.profile",      .systemOrange)
        case .error:      ("exclamationmark.triangle", .systemRed)
        case .anxious:    ("brain.head.profile.fill",  .systemRed)
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbolName,
                                           accessibilityDescription: "ScreenMind")
        statusItem.button?.contentTintColor = color
    }

    // MARK: - Actions

    @objc private func pauseTapped() {
        pauseMonitoring(minutes: 15)
    }

    @objc private func openDebug() {
        if debugWindowController == nil {
            debugWindowController = DebugWindowController()
        }
        debugWindowController?.showWindow(nil)
        debugWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
