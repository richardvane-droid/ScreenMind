import AppKit
import ScreenMindCore

/// Owns the NSStatusItem and drives the monitoring pipeline.
@MainActor
final class StatusBarController {

    // MARK: - Status item
    private let statusItem: NSStatusItem
    private var statusMenu: NSMenu?

    // MARK: - Core services (injected / shared)
    private let anxietyScorer = AnxietyScorer()
    private let hrvManager = HRVManager()
    private let suggestionEngine = SuggestionEngine()
    private let accountAssessor = AccountAssessor()
    private let screenCaptureManager = ScreenCaptureManager()
    private let notificationManager = NotificationManager()

    // MARK: - State
    private var currentAnxietyScore: Double = 0.0
    private var isMonitoring: Bool = false
    private var isPaused: Bool = false   // e.g. paused via iPhone Action Button notification

    // Dynamic threshold = baseThreshold × HRV multiplier
    private var baseThreshold: Double = 0.6
    private var dynamicThreshold: Double = 0.6

    // Cooldown: skip notifications for N minutes after last one
    private var lastNotificationDate: Date?
    private var cooldownMinutes: Int = 5

    // MARK: - Init

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setupMenu()
        updateIcon(anxious: false)
    }

    // MARK: - Monitoring lifecycle

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        updateIcon(anxious: false)

        Task {
            // Request HRV baseline (non-fatal if HealthKit unavailable on Mac)
            try? await hrvManager.requestAuthorization()
            try? await hrvManager.refreshBaseline()
        }

        screenCaptureManager.onFrame = { [weak self] ocrText in
            guard let self, !self.isPaused else { return }
            Task { await self.processFrame(text: ocrText) }
        }
        screenCaptureManager.start()
    }

    func stopMonitoring() {
        isMonitoring = false
        screenCaptureManager.stop()
        updateIcon(anxious: false)
    }

    func pauseMonitoring(minutes: Int = 15) {
        isPaused = true
        updateIcon(anxious: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(minutes * 60)) { [weak self] in
            self?.isPaused = false
        }
    }

    // MARK: - Frame processing

    private func processFrame(text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Update dynamic threshold from latest HRV
        if let hrv = try? await hrvManager.latestHRV() {
            let multiplier = hrvManager.dynamicMultiplier(currentSDNN: hrv.sdnn)
            dynamicThreshold = min(max(baseThreshold * multiplier, 0.2), 0.9)
        }

        let result = await anxietyScorer.analyze(text: text)
        currentAnxietyScore = result.score

        await MainActor.run {
            updateIcon(anxious: result.score > dynamicThreshold)
        }

        // Trigger notification if score exceeds threshold and cooldown has passed
        if result.score > dynamicThreshold, shouldNotify() {
            let suggestions = await suggestionEngine.enabledSuggestions()
            await notificationManager.sendAnxietyAlert(score: result.score,
                                                       keywords: result.dominantKeywords,
                                                       suggestions: suggestions)
            lastNotificationDate = Date()
        }
    }

    private func shouldNotify() -> Bool {
        guard let last = lastNotificationDate else { return true }
        return Date().timeIntervalSince(last) > Double(cooldownMinutes * 60)
    }

    // MARK: - Menu setup

    private func setupMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "ScreenMind", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "暂停 15 分钟", action: #selector(pauseTapped), keyEquivalent: "p")
            .target = self
        menu.addItem(withTitle: "偏好设置...", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ScreenMind", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusMenu = menu
    }

    // MARK: - Icon

    private func updateIcon(anxious: Bool) {
        let name = anxious ? "brain.head.profile.fill" : "brain.head.profile"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "ScreenMind")
        statusItem.button?.contentTintColor = anxious ? .systemRed : .controlTextColor
    }

    // MARK: - Actions

    @objc private func pauseTapped() {
        pauseMonitoring(minutes: 15)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
    }
}
