// =============================================================================
//  CaptureCoordinator.swift
//  ScreenMindMac — Mac 端主应用
// =============================================================================
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenCaptureManager 负责截图，OCREngine 负责识别文字。
//  这两个组件是相互独立的，CaptureCoordinator 把它们"串联"起来，
//  形成完整的"截图 → OCR"管道。
//
//  同时，CaptureCoordinator 还管理监控状态（运行/暂停/停止），
//  让上层（StatusBarController）不需要直接操作底层组件，只通过 Coordinator 就能控制一切。
//
//  【设计模式：Coordinator 模式】
//  Coordinator（协调者）是一种设计模式：
//  当多个组件需要协同工作时，用一个"协调者"来管理它们的交互，
//  而不是让它们直接互相引用（避免耦合）。
//
//  本文件中：
//    CaptureCoordinator = 协调者
//    ScreenCaptureManager = 截图工人
//    OCREngine = 文字识别工人
//    StatusBarController = 老板（只和协调者打交道）
//
//  【数据流】
//  ScreenCaptureManager.onFrame
//      ↓ (在 processingQueue 后台队列)
//  OCREngine.recognizeText（去噪/去重）
//      ↓ (切回主线程)
//  CaptureCoordinator.onResult（回调给 StatusBarController）
//      ↓
//  AnxietyPipeline.process（M3 焦虑评分）
//
//  【部署位置】
//  ScreenMindMac/ScreenCapture/CaptureCoordinator.swift
//
// =============================================================================

import Foundation  // 基础类型
import AppKit      // macOS 界面框架（ObservableObject 用于 SwiftUI 绑定）
import OSLog

private let logger = Logger(subsystem: "com.screenmind.mac", category: "Coordinator")

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 数据结构：管道最终结果
// MARK: ──────────────────────────────────────────────────────────────────────

/// 一帧 OCR 管道的完整输出（OCR 文字 + 前景 App 信息）。
///
/// 这是 CaptureCoordinator 向下游（StatusBarController → AnxietyPipeline）传递的数据。
///
/// 命名为"PipelineResult"而不是"OCRResult"：
///   因为它已经不只是 OCR 的结果了，还附带了"这段文字来自哪个 App"的上下文。
///   这个上下文对焦虑评分很有价值（比如：同样的文字来自微信 vs 来自游戏 App，解读不同）。
struct PipelineResult {
    let ocrResult: OCRResult           // OCREngine 识别出的文字 + 元信息
    let frontAppBundleID: String?      // 截图时前景 App 的 Bundle ID（可用于过滤和统计）
    let frontAppName: String?          // 截图时前景 App 的显示名称（供 UI 显示）
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 核心类：CaptureCoordinator
// MARK: ──────────────────────────────────────────────────────────────────────

/// 截图 + OCR 管道协调者。
///
/// 【ObservableObject 是什么？】
/// SwiftUI 的数据绑定机制：
///   当 @Published 标注的属性变化时，所有订阅了这个对象的 SwiftUI 视图自动刷新。
/// 比如 isRunning 变成 true 时，SwiftUI 里显示"监控中"的文字会自动更新。
/// 即使现在没有 SwiftUI 视图用到这些属性，也先标注好，为将来的 UI 做好准备。
///
/// 【@MainActor 说明】
/// CaptureCoordinator 持有 UI 相关状态（@Published），必须在主线程更新这些状态。
/// @MainActor 确保所有方法都在主线程执行。
/// 注意：帧处理（handleFrame）在 processingQueue 后台队列执行，
///      OCR 完成后用 await MainActor.run {} 切回主线程更新状态。
@MainActor
final class CaptureCoordinator: ObservableObject {

    // MARK: - 公开状态（可绑定到 SwiftUI UI）────────────────────────────

    /// 是否正在运行（截图中）。
    @Published var isRunning: Bool = false

    /// 是否处于暂停状态。
    @Published var isPaused: Bool = false

    /// 屏幕录制权限是否已获得。
    @Published var permissionGranted: Bool = false

    /// 最近一次 OCR 识别出的文字（供调试/设置页面显示）。
    @Published var lastOCRText: String = ""

    /// 总共处理了多少帧（从启动到现在，用于调试）。
    @Published var frameCount: Int = 0

    // MARK: - 下游回调 ────────────────────────────────────────────────────

    /// OCR 管道有新结果时的回调。
    ///
    /// 调用时机：每次 OCREngine 成功识别出新内容（通过去重过滤后）。
    /// 设置方：StatusBarController（在 setupPipelineCallbacks 里设置）。
    ///
    /// 类型：((PipelineResult) -> Void)?
    ///   - (PipelineResult) -> Void：接受 PipelineResult 参数，无返回值的函数类型
    ///   - ? 表示可选，没有设置时为 nil（不会崩溃）
    var onResult: ((PipelineResult) -> Void)?

    // MARK: - 内部组件 ────────────────────────────────────────────────────

    /// 截图组件（底层 ScreenCaptureKit 封装）。
    private let captureManager = ScreenCaptureManager()

    /// OCR 识别引擎（Vision 框架封装 + 去重）。
    private let ocrEngine = OCREngine()

    /// 帧处理队列（串行队列，保证帧按顺序处理，不会并发）。
    ///
    /// 【为什么要串行队列？】
    /// OCR 是有状态的（去重需要记住上一帧），如果多帧并发处理，
    /// 状态会被多个线程同时读写，导致数据不一致。
    /// 串行队列保证"上一帧处理完，再处理下一帧"，线程安全。
    ///
    /// qos: .utility：实用优先级（不影响 UI 流畅度，但也不会被完全饿死）
    private let processingQueue = DispatchQueue(label: "com.screenmind.pipeline", qos: .utility)

    /// 暂停恢复计时器（N 分钟后自动解除暂停）。
    private var pauseTimer: Timer?

    // MARK: - 初始化 ────────────────────────────────────────────────────────

    init() {
        // 设置截图回调：ScreenCaptureManager 每次有新帧，提交到后台队列处理
        captureManager.onFrame = { [weak self] frame in
            // 注意：这个闭包在 SCStream 的回调队列里被调用
            // 我们把它转发到 processingQueue 确保串行处理
            self?.processingQueue.async {
                self?.handleFrame(frame)
            }
        }
    }

    // MARK: - 权限检查 ────────────────────────────────────────────────────────

    /// 检查并请求屏幕录制权限。
    ///
    /// 第一次启动时：
    ///   1. 先检查权限状态
    ///   2. 如果没有权限，触发系统权限对话框
    ///   3. 等待 2 秒（给用户时间在系统设置里授权）
    ///   4. 再次检查权限状态
    func checkAndRequestPermission() async {
        permissionGranted = await ScreenCaptureManager.authorizationStatus()
        if !permissionGranted {
            await ScreenCaptureManager.requestPermission() // 弹出系统授权对话框
            // 等待用户操作：2 秒内用户可能去系统设置里授权
            // Task.sleep 是异步等待，不阻塞主线程
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
            permissionGranted = await ScreenCaptureManager.authorizationStatus() // 再次检查
        }
        logger.info("Screen recording permission: \(self.permissionGranted)")
    }

    // MARK: - 生命周期控制 ────────────────────────────────────────────────────

    /// 启动监控（检查权限 → 开始截图）。
    ///
    /// 调用方：StatusBarController.startMonitoring()
    func start() async {
        guard !isRunning else { return } // 已经在运行，不重复启动
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

    /// 停止监控。
    ///
    /// 调用方：StatusBarController.stopMonitoring()
    func stop() {
        captureManager.stop()
        isRunning = false
        isPaused = false
        pauseTimer?.invalidate() // 取消暂停计时器（如果存在）
        pauseTimer = nil
        ocrEngine.resetDeduplication() // 重置去重状态（下次启动时重新开始）
        logger.info("CaptureCoordinator stopped")
    }

    /// 暂停监控 N 分钟，到期后自动恢复。
    ///
    /// 实现方式：设置一个 Timer，N 分钟后把 isPaused 设为 false。
    /// OCR 帧处理里检查 isPaused，暂停期间收到帧会立刻丢弃。
    ///
    /// - Parameter minutes: 暂停分钟数，默认 15 分钟
    func pause(minutes: Int = 15) {
        guard isRunning else { return } // 没有运行就不需要暂停
        isPaused = true
        pauseTimer?.invalidate() // 取消上一个暂停计时器（防止重复）
        pauseTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(minutes * 60), // 转换为秒
            repeats: false // 只触发一次（不是循环计时器）
        ) { [weak self] _ in
            self?.isPaused = false // 时间到，自动恢复
            logger.info("Pause expired, resuming capture")
        }
        logger.info("Capture paused for \(minutes) min")
    }

    /// 手动恢复（取消暂停）。
    func resume() {
        isPaused = false
        pauseTimer?.invalidate()
        pauseTimer = nil
    }

    // MARK: - 配置透传（Config Passthrough）──────────────────────────────

    /// 更新采样间隔（用户在设置里修改后调用）。
    /// "透传"意思是：CaptureCoordinator 不直接处理这个配置，直接转发给 captureManager。
    func updateSamplingInterval(_ seconds: TimeInterval) {
        captureManager.config.samplingInterval = seconds
    }

    /// 更新 App 过滤规则。
    func updateAppFilter(mode: CaptureConfig.AppFilterMode, bundleIDs: Set<String>) {
        captureManager.config.filterMode = mode
        captureManager.config.filteredBundleIDs = bundleIDs
    }

    // MARK: - 帧处理（在 processingQueue 后台队列执行）──────────────────────

    /// 处理一帧截图：提交给 OCREngine，如有有效结果则回调上游。
    ///
    /// 这个方法在 processingQueue（后台队列）上执行。
    /// 但它内部的 await 会让 Task 在合适的时机切换线程。
    private func handleFrame(_ frame: CaptureFrame) {
        // 如果暂停中，立刻丢弃这帧
        guard !isPaused else { return }

        // 创建异步任务来执行 OCR（OCR 是 async 函数，需要在 Task 里调用）
        Task {
            // 执行 OCR 识别，可能返回 nil（重复帧或内容太少）
            guard let ocr = await ocrEngine.recognizeText(in: frame) else { return }

            // 切回主线程更新状态（@Published 属性必须在主线程修改）
            await MainActor.run {
                self.lastOCRText = ocr.text // 更新最近 OCR 文本（供调试用）
                self.frameCount += 1        // 帧计数 +1
            }

            // 打包成 PipelineResult
            let result = PipelineResult(
                ocrResult: ocr,
                frontAppBundleID: frame.frontAppBundleID,
                frontAppName: frame.frontAppName
            )

            // 切回主线程触发回调（StatusBarController 的 onResult 在主线程执行）
            await MainActor.run {
                self.onResult?(result) // 如果 onResult 是 nil，什么都不做
            }
        }
    }
}
