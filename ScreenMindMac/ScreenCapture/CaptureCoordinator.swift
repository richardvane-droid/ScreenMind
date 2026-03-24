import Foundation
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.screenmind.mac", category: "Coordinator")

// MARK: - Pipeline Result

struct PipelineResult {
    let ocrResult: OCRResult
    let frontAppBundleID: String?
    let frontAppName: String?
}

// MARK: - CaptureCoordinator

/// 串联 ScreenCaptureKit → OCR 管道。
/// 下游（StatusBarController）只需监听 onResult 回调。
///
/// 流程：
///   SCStream 帧 → ScreenCaptureManager.onFrame
///     → OCREngine.recognizeText（去噪 / 去重）
///       → onResult（仅在有有效文本时触发）
@MainActor
final class CaptureCoordinator: ObservableObject {

    // MARK: - Public state
    @Published var isRunning: Bool = false
    @Published var isPaused: Bool = false
    @Published var permissionGranted: Bool = false
    @Published var lastOCRText: String = ""
    @Published var frameCount: Int = 0       // 调试用

    // MARK: - Callback
    var onResult: ((PipelineResult) -> Void)?

    // MARK: - Internals
    private let captureManager = ScreenCaptureManager()
    private let ocrEngine = OCREngine()
    private let processingQueue = DispatchQueue(label: "com.screenmind.pipeline", qos: .utility)
    private var pauseTimer: Timer?

    // MARK: - Init

    init() {
        captureManager.onFrame = { [weak self] frame in
            self?.processingQueue.async {
                self?.handleFrame(frame)
            }
        }
    }

    // MARK: - Permission check

    func checkAndRequestPermission() async {
        permissionGranted = await ScreenCaptureManager.authorizationStatus()
        if !permissionGranted {
            await ScreenCaptureManager.requestPermission()
            // 给用户时间在系统设置里授权，再检查一次
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            permissionGranted = await ScreenCaptureManager.authorizationStatus()
        }
        logger.info("Screen recording permission: \(self.permissionGranted)")
    }

    // MARK: - Start / Stop / Pause

    func start() async {
        guard !isRunning else { return }
        await checkAndRequestPermission()
        guard permissionGranted else {
            logger.warning("Cannot start: screen recording permission denied")
            return
        }
        captureManager.start()
        isRunning = true
        isPaused = false
        logger.info("CaptureCoordinator started")
    }

    func stop() {
        captureManager.stop()
        isRunning = false
        isPaused = false
        pauseTimer?.invalidate()
        pauseTimer = nil
        ocrEngine.resetDeduplication()
        logger.info("CaptureCoordinator stopped")
    }

    func pause(minutes: Int = 15) {
        guard isRunning else { return }
        isPaused = true
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60),
                                          repeats: false) { [weak self] _ in
            self?.isPaused = false
            logger.info("Pause expired, resuming capture")
        }
        logger.info("Capture paused for \(minutes) min")
    }

    func resume() {
        isPaused = false
        pauseTimer?.invalidate()
        pauseTimer = nil
    }

    // MARK: - Config passthrough

    func updateSamplingInterval(_ seconds: TimeInterval) {
        captureManager.config.samplingInterval = seconds
    }

    func updateAppFilter(mode: CaptureConfig.AppFilterMode, bundleIDs: Set<String>) {
        captureManager.config.filterMode = mode
        captureManager.config.filteredBundleIDs = bundleIDs
    }

    // MARK: - Frame processing

    private func handleFrame(_ frame: CaptureFrame) {
        guard !isPaused else { return }

        Task {
            guard let ocr = await ocrEngine.recognizeText(in: frame) else { return }

            await MainActor.run {
                self.lastOCRText = ocr.text
                self.frameCount += 1
            }

            let result = PipelineResult(
                ocrResult: ocr,
                frontAppBundleID: frame.frontAppBundleID,
                frontAppName: frame.frontAppName
            )

            await MainActor.run {
                self.onResult?(result)
            }
        }
    }
}
