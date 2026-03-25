// =============================================================================
//  ScreenCaptureManager.swift
//  ScreenMindMac — Mac 端主应用
// =============================================================================
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenMind 需要周期性地"看"屏幕，才能知道用户在浏览什么内容。
//  ScreenCaptureManager 负责：
//    1. 向 macOS 请求屏幕录制权限
//    2. 定期截取屏幕画面（每 30 秒一帧）
//    3. 过滤掉不需要分析的 App（比如用户主动加入黑名单的 App）
//    4. 把帧数据交给 OCREngine 处理
//
//  【ScreenCaptureKit 是什么？】
//  macOS 12.3 苹果新推出的高性能屏幕捕获框架（简称 SCK）。
//  比旧的 CGDisplayStream 更现代、更省电，并且有更精细的权限控制。
//  特点：
//    - 可以选择只捕获某些窗口/应用，不捕获其他内容
//    - 支持排除自身窗口（防止 ScreenMind 分析自己的调试窗口）
//    - macOS 系统级别的 API，不需要第三方库
//
//  【隐私设计说明】
//  屏幕录制是非常敏感的权限，以下设计保护用户隐私：
//    1. 降低分辨率（scaleFactor = 0.5）：捕获时只取半分辨率，足够 OCR 但不是高清截图
//    2. 不捕获音频（capturesAudio = false）
//    3. 隐藏光标（showsCursor = false）：截图里看不到鼠标位置
//    4. 本地处理：截图不上传到任何服务器，OCR 在本机完成
//    5. App 黑名单：用户可以设置某些 App 的内容永不分析
//
//  【部署位置】
//  ScreenMindMac/ScreenCapture/ScreenCaptureManager.swift
//
// =============================================================================

import Foundation        // 基础类型
import ScreenCaptureKit  // macOS 12.3+ 屏幕捕获框架（SCStream、SCShareableContent 等）
import CoreMedia         // 提供 CMSampleBuffer（视频帧的标准表示格式）
import OSLog

private let logger = Logger(subsystem: "com.screenmind.mac", category: "ScreenCapture")

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 配置结构体
// MARK: ──────────────────────────────────────────────────────────────────────

/// 屏幕捕获的可配置参数。
///
/// 这些参数用户可以在"偏好设置"里修改（M5 阶段接入设置 UI）。
/// 这里的默认值是经过测试的"最佳实践"组合。
struct CaptureConfig {
    /// 两次截图之间的最短间隔（秒）。
    ///
    /// 默认 30 秒的考量：
    ///   - 用户阅读一屏内容平均需要 20–40 秒
    ///   - 30 秒足以捕捉到内容变化，但不会过于频繁（太频繁耗电）
    ///   - 每次 OCR + 评分约需 50–100ms（NL 路径），影响可忽略
    var samplingInterval: TimeInterval = 30.0

    /// 截图时的缩放比例（相对于屏幕原始分辨率）。
    ///
    /// 默认 0.5（半分辨率）：
    ///   - Vision OCR 在 50% 分辨率下识别效果和 100% 基本相同
    ///   - 内存占用减少 75%（面积减半 = 像素数减为 1/4）
    ///   - 传给 OCREngine 的 CVPixelBuffer 体积更小，处理更快
    var scaleFactor: Double = 0.5

    /// 是否排除 ScreenMind 自身的窗口（调试窗口、设置窗口等）。
    ///
    /// 默认 true：防止 App 分析自己的调试窗口文字（会产生噪声数据）。
    var excludeSelf: Bool = true

    /// App 过滤模式：白名单（只分析列表内 App）或黑名单（跳过列表内 App）。
    ///
    /// 默认 .blacklist：用户只需要把"不想分析"的 App 加入黑名单即可，
    /// 比白名单（需要枚举所有想分析的 App）更方便。
    var filterMode: AppFilterMode = .blacklist

    /// 过滤列表，存储 App 的 Bundle ID（唯一标识符）。
    ///
    /// Bundle ID 格式：com.公司名.应用名（如 "com.apple.Safari"）
    /// 每个 App 的 Bundle ID 可以在 Xcode 或终端 ls /Applications 查到。
    var filteredBundleIDs: Set<String> = []

    /// App 过滤模式枚举。
    enum AppFilterMode {
        case whitelist // 白名单：只处理列表里有的 App（其他 App 忽略）
        case blacklist // 黑名单：跳过列表里有的 App（其他 App 正常处理）
    }
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 数据结构：一帧捕获数据
// MARK: ──────────────────────────────────────────────────────────────────────

/// 一帧屏幕截图的数据包（由 ScreenCaptureManager 创建，传给 OCREngine）。
///
/// 包含像素数据 + 上下文信息（时间、当前前景 App）。
struct CaptureFrame {
    let pixelBuffer: CVPixelBuffer    // 原始像素数据（图像内容）
    let timestamp: Date               // 截图时间
    let frontAppBundleID: String?     // 截图时前景 App 的 Bundle ID（可选）
    let frontAppName: String?         // 截图时前景 App 的显示名称（可选）
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 核心类：ScreenCaptureManager
// MARK: ──────────────────────────────────────────────────────────────────────

/// 通过 ScreenCaptureKit 周期性捕获屏幕帧。
///
/// 职责：
///   1. 权限管理（检查/请求屏幕录制权限）
///   2. 建立 SCStream 流（底层屏幕捕获连接）
///   3. 节流（不是每帧都处理，按 samplingInterval 控制频率）
///   4. App 过滤（黑名单/白名单）
///   5. 把合格的帧通过 onFrame 回调传出去
///
/// 继承 NSObject 的原因：
///   SCStreamOutput 和 SCStreamDelegate 协议（苹果 ObjC 协议）要求实现者是 NSObject 子类。
final class ScreenCaptureManager: NSObject, @unchecked Sendable {

    // MARK: - 公开接口 ────────────────────────────────────────────────────

    /// 捕获配置（可动态修改；修改后调用 updateConfig 生效）。
    var config = CaptureConfig()

    /// 新帧就绪回调。
    ///
    /// 只有通过节流+过滤检查的帧才会触发这个回调。
    /// 调用方（CaptureCoordinator）在这里接收帧并提交给 OCREngine。
    var onFrame: ((CaptureFrame) -> Void)?

    // MARK: - 内部状态 ────────────────────────────────────────────────────

    /// 当前运行的 SCStream 实例（屏幕捕获流）。
    private var stream: SCStream?

    /// 是否正在运行（用于防止重复启动和控制重连逻辑）。
    private var isRunning = false

    /// 上一帧被处理的时间（用于节流：控制采样间隔）。
    private var lastFrameDate: Date?

    /// SCStream 回调队列（串行队列，保证帧处理顺序正确）。
    ///
    /// DispatchQueue：Apple 的任务队列系统（GCD，Grand Central Dispatch）。
    /// label：队列名称（方便调试时识别）
    /// qos: .utility：实用工具级别优先级（比 background 高，比 userInteractive 低）
    private let queue = DispatchQueue(label: "com.screenmind.capture", qos: .utility)

    // MARK: - 权限管理 ────────────────────────────────────────────────────

    /// 检查屏幕录制权限是否已授予。
    ///
    /// static：类方法，不需要实例就能调用（ScreenCaptureManager.authorizationStatus()）。
    /// async：权限检查是异步的（需要与系统通信）。
    ///
    /// 工作原理：
    ///   尝试获取可共享内容列表（SCShareableContent.excludingDesktopWindows）。
    ///   如果成功，说明有权限；如果抛出异常（error），说明没有权限。
    static func authorizationStatus() async -> Bool {
        do {
            // excludingDesktopWindows: false = 包含桌面窗口
            // onScreenWindowsOnly: true = 只列出当前显示在屏幕上的窗口
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true  // 没有抛出异常 = 有权限
        } catch {
            return false // 抛出异常 = 没有权限
        }
    }

    /// 触发系统权限请求对话框（弹出"允许录制屏幕"提示）。
    ///
    /// 注意：这个函数不等待用户的回答。
    /// 用户授权/拒绝后，下次调用 authorizationStatus() 会返回正确的结果。
    static func requestPermission() async {
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // try? 表示：不管成功还是失败，都不抛出（请求权限本身可能失败，但我们不在乎这里的结果）
    }

    // MARK: - 启动/停止/配置更新 ──────────────────────────────────────────

    /// 启动屏幕捕获（设置好 SCStream 后开始接收帧）。
    func start() {
        guard !isRunning else { return } // 防止重复启动
        isRunning = true
        // Task(priority:)：创建后台异步任务（priority .utility 表示低优先级，不占前台资源）
        Task(priority: .utility) { await self.setupStream() }
    }

    /// 停止屏幕捕获（关闭 SCStream，释放资源）。
    func stop() {
        isRunning = false
        Task {
            try? await stream?.stopCapture() // 告诉 SCStream 停止捕获
            stream = nil                     // 释放 SCStream 对象
            logger.info("ScreenCapture stopped")
        }
    }

    /// 动态更新配置（比如用户在设置里改了采样间隔）。
    ///
    /// 需要重启 stream 才能使新配置生效（SCStream 不支持热更新配置）。
    func updateConfig(_ newConfig: CaptureConfig) {
        config = newConfig
        if isRunning {
            stop()  // 先停止
            start() // 再以新配置重新启动
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 建立捕获流
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 异步配置并启动 SCStream。
    ///
    /// 这个函数比较长，因为 ScreenCaptureKit 的配置步骤比较多：
    ///   1. 获取可捕获内容列表（SCShareableContent）
    ///   2. 确定要捕获的显示器
    ///   3. 设置排除窗口（自身窗口）
    ///   4. 创建 SCContentFilter（决定捕获什么）
    ///   5. 创建 SCStreamConfiguration（决定怎么捕获）
    ///   6. 建立 SCStream 并启动
    private func setupStream() async {
        do {
            // 获取当前屏幕上所有可共享的内容（显示器、App、窗口列表）
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)

            // 取第一个显示器（多显示器情况下，目前只捕获主屏幕）
            guard let display = content.displays.first else {
                logger.error("No display found")
                return
            }

            // ── 排除自身窗口 ─────────────────────────────────────────────
            var excludedWindows: [SCWindow] = []
            if config.excludeSelf {
                // processIdentifier：当前进程的 PID（Process ID，操作系统分配的进程编号）
                let selfPID = ProcessInfo.processInfo.processIdentifier
                // 找到 App 列表中属于自己的那个 App 条目
                if let selfApp = content.applications.first(where: { $0.processID == selfPID }) {
                    // 过滤出属于自己的所有窗口
                    excludedWindows = content.windows.filter {
                        $0.owningApplication?.processID == selfApp.processID
                    }
                }
            }

            // SCContentFilter：定义"捕获哪个显示器，排除哪些窗口"
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            // ── 捕获配置 ─────────────────────────────────────────────────
            let cfg = SCStreamConfiguration()
            // 按 scaleFactor 计算捕获分辨率（0.5 = 半分辨率）
            cfg.width  = Int(Double(display.width)  * config.scaleFactor)
            cfg.height = Int(Double(display.height) * config.scaleFactor)
            // minimumFrameInterval：最快每秒捕获 1 帧（我们不需要视频帧率，1fps 够了）
            // CMTime(value: 1, timescale: 1) = 1/1 秒 = 1fps
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.queueDepth = 3      // 内部帧队列深度（3 帧缓冲，处理慢时不丢帧）
            cfg.capturesAudio = false // 不捕获音频（隐私保护 + 节省资源）
            cfg.showsCursor = false   // 截图里不显示鼠标光标

            // ── 创建并启动 SCStream ──────────────────────────────────────
            // delegate: self = 出错时回调 ScreenCaptureManager 的 SCStreamDelegate 方法
            let newStream = SCStream(filter: filter, configuration: cfg, delegate: self)
            // addStreamOutput：注册帧接收回调（屏幕有新帧时调用我们的 SCStreamOutput 方法）
            // sampleHandlerQueue: queue = 在我们的串行队列上处理帧（保证顺序）
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await newStream.startCapture() // 开始捕获！
            stream = newStream

            logger.info("ScreenCapture started — \(cfg.width)x\(cfg.height), interval=\(self.config.samplingInterval)s")
        } catch {
            logger.error("Failed to start capture: \(error.localizedDescription)")
            isRunning = false
        }
    }

    // MARK: - 节流 + App 过滤 ──────────────────────────────────────────────

    /// 判断当前帧是否应该处理（节流 + App 过滤的组合检查）。
    ///
    /// - Returns: true = 应该处理，false = 应该丢弃
    private func shouldProcessFrame() -> Bool {
        // ── 节流检查：距上次处理时间是否足够长 ─────────────────────────
        if let last = lastFrameDate,
           Date().timeIntervalSince(last) < config.samplingInterval {
            return false // 还没到采样时间，跳过
        }

        // ── App 过滤检查 ───────────────────────────────────────────────
        guard let bundleID = frontmostBundleID() else {
            return true // 无法获取前景 App 信息，默认处理
        }
        switch config.filterMode {
        case .whitelist:
            return config.filteredBundleIDs.contains(bundleID) // 白名单：只处理列表里的
        case .blacklist:
            return !config.filteredBundleIDs.contains(bundleID) // 黑名单：跳过列表里的
        }
    }

    /// 获取当前前景 App 的 Bundle ID（如 "com.apple.Safari"）。
    private func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 获取当前前景 App 的显示名称（如 "Safari"）。
    private func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: SCStreamOutput 协议实现：接收屏幕帧
// MARK: ──────────────────────────────────────────────────────────────────────

/// SCStream 每次有新帧时，调用这个协议方法。
///
/// extension 语法：把协议实现放在单独的 extension 里，让代码更有条理。
/// SCStreamOutput 是苹果定义的协议，我们实现它的方法来接收帧。
extension ScreenCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {

        // 只处理屏幕帧（过滤掉音频帧等其他类型）
        guard type == .screen,
              isRunning,
              shouldProcessFrame() else { return }

        // 从 CMSampleBuffer 提取图像数据（CVPixelBuffer）
        // CMSampleBufferGetImageBuffer：标准 CoreMedia API，从视频帧中提取像素数据
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastFrameDate = Date() // 更新上次处理时间（节流使用）

        // 打包成我们自己的 CaptureFrame，附带上下文信息
        let frame = CaptureFrame(
            pixelBuffer: imageBuffer,
            timestamp: Date(),
            frontAppBundleID: frontmostBundleID(),
            frontAppName: frontmostAppName()
        )

        // 通过回调把帧传出去（OCREngine 在另一个队列里处理）
        onFrame?(frame)
    }
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: SCStreamDelegate 协议实现：错误处理 + 自动重连
// MARK: ──────────────────────────────────────────────────────────────────────

/// SCStream 出现错误时（比如用户锁屏、权限被撤销），会调用这个代理方法。
extension ScreenCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error: \(error.localizedDescription)")
        isRunning = false

        // ── 自动重连：5 秒后尝试重新建立捕获流 ─────────────────────────
        // 场景：用户短暂锁屏后解锁，App 应该自动恢复工作，不需要用户手动重启。
        // DispatchQueue.main.asyncAfter：在主线程上延迟 5 秒执行
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.isRunning == false else { return }
            // 检查：如果 5 秒内已经被重新启动了（比如用户点了"重新开始"），就不重复启动
            self.isRunning = true
            Task(priority: .utility) { await self.setupStream() }
        }
    }
}
