import Foundation
import ScreenCaptureKit
import CoreMedia
import OSLog

private let logger = Logger(subsystem: "com.screenmind.mac", category: "ScreenCapture")

// MARK: - Capture Configuration

struct CaptureConfig {
    /// 两次截图之间的最短间隔（秒）
    var samplingInterval: TimeInterval = 30.0
    /// 捕获分辨率缩放比例（0.5 = 半分辨率，OCR 够用，省内存）
    var scaleFactor: Double = 0.5
    /// 排除 ScreenMind 自身窗口
    var excludeSelf: Bool = true
    /// App 过滤模式
    var filterMode: AppFilterMode = .blacklist
    /// 过滤列表（bundle IDs）
    var filteredBundleIDs: Set<String> = []

    enum AppFilterMode { case whitelist, blacklist }
}

// MARK: - Capture Frame

struct CaptureFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: Date
    let frontAppBundleID: String?
    let frontAppName: String?
}

// MARK: - ScreenCaptureManager

/// 负责通过 ScreenCaptureKit 持续捕获屏幕帧。
/// 每帧通过 onFrame 回调交给 OCREngine 处理。
/// 内部做节流（samplingInterval）避免过度触发。
final class ScreenCaptureManager: NSObject, @unchecked Sendable {

    // MARK: - Public interface
    var config = CaptureConfig()
    var onFrame: ((CaptureFrame) -> Void)?

    // MARK: - State
    private var stream: SCStream?
    private var isRunning = false
    private var lastFrameDate: Date?
    private let queue = DispatchQueue(label: "com.screenmind.capture", qos: .utility)

    // MARK: - Permission

    static func authorizationStatus() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    static func requestPermission() async {
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task(priority: .utility) { await self.setupStream() }
    }

    func stop() {
        isRunning = false
        Task {
            try? await stream?.stopCapture()
            stream = nil
            logger.info("ScreenCapture stopped")
        }
    }

    func updateConfig(_ newConfig: CaptureConfig) {
        config = newConfig
        if isRunning { stop(); start() }
    }

    // MARK: - Stream setup

    private func setupStream() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                logger.error("No display found")
                return
            }

            // 排除自身窗口
            var excludedWindows: [SCWindow] = []
            if config.excludeSelf {
                let selfPID = ProcessInfo.processInfo.processIdentifier
                if let selfApp = content.applications.first(where: { $0.processID == selfPID }) {
                    excludedWindows = content.windows.filter { $0.owningApplication?.processID == selfApp.processID }
                }
            }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            let cfg = SCStreamConfiguration()
            cfg.width  = Int(Double(display.width)  * config.scaleFactor)
            cfg.height = Int(Double(display.height) * config.scaleFactor)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.queueDepth = 3
            cfg.capturesAudio = false
            cfg.showsCursor = false

            let newStream = SCStream(filter: filter, configuration: cfg, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await newStream.startCapture()
            stream = newStream
            logger.info("ScreenCapture started — \(cfg.width)x\(cfg.height), interval=\(self.config.samplingInterval)s")
        } catch {
            logger.error("Failed to start capture: \(error.localizedDescription)")
            isRunning = false
        }
    }

    // MARK: - Throttle + app filter

    private func shouldProcessFrame() -> Bool {
        if let last = lastFrameDate,
           Date().timeIntervalSince(last) < config.samplingInterval { return false }
        guard let bundleID = frontmostBundleID() else { return true }
        switch config.filterMode {
        case .whitelist: return config.filteredBundleIDs.contains(bundleID)
        case .blacklist:  return !config.filteredBundleIDs.contains(bundleID)
        }
    }

    private func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}

// MARK: - SCStreamOutput

extension ScreenCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, isRunning, shouldProcessFrame() else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastFrameDate = Date()
        let frame = CaptureFrame(
            pixelBuffer: imageBuffer,
            timestamp: Date(),
            frontAppBundleID: frontmostBundleID(),
            frontAppName: frontmostAppName()
        )
        onFrame?(frame)
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error: \(error.localizedDescription)")
        isRunning = false
        // 5 秒后自动重连
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.isRunning == false else { return }
            self.isRunning = true
            Task(priority: .utility) { await self.setupStream() }
        }
    }
}
