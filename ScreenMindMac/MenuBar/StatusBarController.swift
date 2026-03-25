// =============================================================================
//  StatusBarController.swift
//  ScreenMindMac — Mac 端主应用
// =============================================================================
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenMind 是一个 macOS MenuBar App（菜单栏 App）。
//  它没有主窗口，只在菜单栏右上角显示一个小图标（大脑图标）。
//
//  StatusBarController 就是这个菜单栏图标的"总控制器"，负责：
//    1. 创建并持有菜单栏图标（NSStatusItem）
//    2. 提供右键菜单（暂停/调试/设置/退出）
//    3. 启动整个监控管道（屏幕截图 → OCR → 焦虑评分）
//    4. 根据监控状态更新图标颜色（正常/暂停/焦虑中/错误）
//    5. 当焦虑分超过阈值，触发系统通知 + 图标短暂变红
//
//  【App 的整体架构】
//  ScreenMindApp（入口）
//       └── StatusBarController（总控制器，本文件）
//              ├── CaptureCoordinator（截屏 + OCR，M2）
//              │      ├── ScreenCaptureManager（ScreenCaptureKit 截屏）
//              │      └── OCREngine（Vision 文字识别）
//              ├── AnxietyPipeline（焦虑评分 + 持久化，M3）
//              │      ├── AnxietyScorer（NL + LLM 两阶段评分）
//              │      └── PersistenceController（Core Data 存储）
//              ├── HRVIntegrator（HealthKit HRV 轮询 + 动态阈值，M4）
//              ├── AccountDetector（账号识别 + 综合评分，M5）← 本次 M5 新增
//              │      └── AccountAssessor（豆包 API + Ollama 评估账号风格）
//              ├── NotificationManager（系统通知）
//              └── DebugWindowController（调试窗口）
//
//  【@MainActor 说明】
//  所有 UI 操作必须在主线程执行。@MainActor 标注整个 class，
//  表示这个类的所有方法都只在主线程运行。
//  当异步结果（如 OCR 完成）需要更新 UI 时，Swift 会自动切换到主线程。
//
//  【部署位置】
//  ScreenMindMac/MenuBar/StatusBarController.swift
//
// =============================================================================

import AppKit          // macOS 界面框架，提供 NSStatusBar、NSMenu、NSImage 等
import ScreenMindCore  // 共享包，提供 AnxietyScorer、PersistenceController 等
import OSLog           // 结构化日志框架

private let logger = Logger(subsystem: "com.screenmind.mac", category: "StatusBar")

/// 菜单栏图标总控制器。
/// 它是 ScreenMindMac 的"大脑中枢"：启动所有子系统，协调各模块之间的通信。
///
/// 生命周期：
///   1. ScreenMindApp.swift 的 AppDelegate 里创建一个 StatusBarController 实例
///   2. 实例创建时自动初始化所有子系统
///   3. App 退出时实例销毁，所有子系统随之停止
@MainActor
final class StatusBarController {

    // MARK: - 菜单栏图标 ──────────────────────────────────────────────────

    /// macOS 菜单栏图标对象（右上角那个图标）。
    ///
    /// NSStatusItem 是 macOS 菜单栏上的一个"槽位"，
    /// 可以设置图标、颜色、点击菜单等。
    /// withLength: .squareLength 表示图标占一个标准方块大小的空间。
    private let statusItem: NSStatusItem

    // MARK: - 子系统（M2）──────────────────────────────────────────────────

    /// 截屏 + OCR 管道（M2 完成）。
    ///
    /// CaptureCoordinator 封装了整个"截图→OCR→回调"流程，
    /// StatusBarController 只需要监听它的 onResult 回调。
    private let coordinator = CaptureCoordinator()

    // MARK: - 子系统（M3 新增）────────────────────────────────────────────

    /// 焦虑评分引擎（M3 本次新增）。
    ///
    /// 接收 OCR 文本，输出焦虑分，持久化到 Core Data，
    /// 并在阈值触发时通过 onAlert 回调通知 StatusBarController。
    private let anxietyPipeline = AnxietyPipeline()

    /// 系统通知管理器（M3 接入）。
    ///
    /// 负责发送 UNUserNotification（系统推送），
    /// 在 Notification Center 里显示"检测到焦虑内容"的提醒。
    private let notificationManager = NotificationManager()

    // MARK: - 子系统（M4 新增）────────────────────────────────────────────

    /// HRV 轮询器 + 动态阈值乘数提供者（M4 本次新增）。
    ///
    /// 每 5 分钟从 HealthKit 获取最新 HRV，
    /// 计算出"HRV乘数"（0.4–1.6）并注入 AnxietyPipeline，
    /// 让焦虑阈值随用户的生理状态自适应调整。
    ///
    /// 【为什么在 StatusBarController 里持有，而不是在 AnxietyPipeline 里？】
    /// 单一职责原则：AnxietyPipeline 只负责"评分+判断"，
    /// HRVIntegrator 负责"从 HealthKit 采集数据"。
    /// StatusBarController 作为协调者，把两者连接起来。
    private let hrvIntegrator = HRVIntegrator()

    // MARK: - 子系统（M5 新增）────────────────────────────────────────────

    /// 账号检测器 + 综合评分合并器（M5 本次新增）。
    ///
    /// 职责：
    ///   1. 从每帧 OCR 文字中识别抖音/微信公众号账号名
    ///   2. 调用 AccountAssessor（豆包 API + Ollama）评估账号焦虑风格
    ///   3. 计算综合评分 = 内容分 × 60% + 账号分 × 40%
    ///   4. 通过 onAccountDetected 回调通知 StatusBarController
    ///
    /// 【为什么这里创建而不是放在 AnxietyPipeline 里？】
    /// AccountDetector 需要访问 PipelineResult（账号识别用到 Bundle ID），
    /// 而 AnxietyPipeline 不持有 PipelineResult 的 App 上下文。
    /// 保持 AnxietyPipeline 单一职责（只做焦虑评分），
    /// 账号检测作为平行管道在 StatusBarController 里协调。
    private let accountDetector = AccountDetector()

    // MARK: - 调试窗口 ──────────────────────────────────────────────────────

    /// 调试窗口控制器（可选）。
    ///
    /// 用 var + Optional（?），因为调试窗口不是一直开着的：
    ///   - 菜单里点"调试窗口"时创建（lazy creation）
    ///   - 关闭窗口时不销毁（保留以便再次打开，isReleasedWhenClosed = false）
    private var debugWindowController: DebugWindowController?

    // MARK: - 子系统（M9 新增）────────────────────────────────────────────

    /// 实时监控 Dashboard 广播器（M9 本次新增）。
    ///
    /// 职责：
    ///   1. 在 localhost:9527 启动一个轻量 HTTP 服务器
    ///   2. 订阅 AnxietyPipeline / HRVIntegrator / AccountDetector 的输出
    ///   3. 通过 Server-Sent Events（SSE）把实时数据推送给浏览器 Dashboard
    ///
    /// 副屏全屏使用方法：
    ///   在菜单里点「实时监控 Dashboard」打开 http://localhost:9527，
    ///   把浏览器窗口拖到副屏并按 F 键（全屏）即可。
    private let webMonitor = WebMonitorBroadcaster()

    // MARK: - 子系统（M10 新增）────────────────────────────────────────────

    /// 16×16 LED 矩阵情绪表情控制器（M10 本次新增）。
    ///
    /// 通过 USB 串口（POSIX I/O）与 Arduino Nano 通信，
    /// 根据当前焦虑分数在 WS2812B LED 矩阵上显示对应情绪表情：
    ///   焦虑分 < 0.40 → 大笑脸（绿色）
    ///   焦虑分 0.40–0.60 → 微笑脸（绿色）
    ///   焦虑分 0.60–0.70 → 中性脸（黄色）
    ///   焦虑分 0.70–0.85 → 担忧脸（橙色）
    ///   焦虑分 ≥ 0.85   → 痛苦脸（红色）
    ///
    /// 【硬件可选性】
    ///   如果没有 Arduino + LED 矩阵，App 正常运行，只是不显示表情。
    ///   LEDMatrixController 在找不到串口设备时会安静地进入 .error 状态，
    ///   不影响其他功能。
    private let ledMatrix = LEDMatrixController()

    // MARK: - 子系统（M8 新增）────────────────────────────────────────────

    /// 焦虑提醒浮窗控制器（M8 本次新增）。
    ///
    /// 当焦虑分超过阈值时，从菜单栏图标弹出 AlertPanel SwiftUI 浮窗，
    /// 展示双模块放松建议（Module 1 个人预设 + Module 2 达人推荐）。
    private let alertPanelController = AlertPanelController()

    /// 最近一次账号检测结果（供 AlertPanel 展示账号信息）。
    private var lastAccountDetectionResult: AccountDetectionResult? = nil

    // MARK: - 初始化 ──────────────────────────────────────────────────────────

    init() {
        // 创建菜单栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // 设置右键菜单
        setupMenu()

        // 初始图标状态：空闲（灰色大脑）
        updateIcon(state: .idle)

        // 连接所有管道回调（把各子系统的输出接在一起）
        setupPipelineCallbacks()

        // 请求系统通知权限（App 首次运行时弹出"是否允许通知"对话框）
        Task {
            await notificationManager.requestAuthorization()
        }

        // M9：启动实时 Dashboard 广播服务器（localhost:9527）
        // 在 init 阶段就启动，这样即使用户还没开始监控，Dashboard 也能访问
        webMonitor.start()

        // M10：连接 LED 矩阵（自动扫描 /dev/cu.usbserial-* 设备）
        // 如果没接 Arduino，connect() 会安静失败，不影响 App 正常运行
        ledMatrix.connect()
        // 状态变化回调：用于在调试菜单里显示硬件连接状态
        ledMatrix.onStateChanged = { [weak self] state in
            self?.updateLEDStatusMenuItem(state: state)
        }

        // M4：申请 HealthKit HRV 权限 + 启动后台轮询
        // Task { } 里的代码异步执行，不阻塞 StatusBarController 的初始化
        Task {
            // 申请 HealthKit 读取权限（会弹出"是否允许访问健康数据"对话框）
            await hrvIntegrator.requestAuthorization()
            // 权限处理完毕后立刻开始轮询（第一次轮询会马上执行，不等 5 分钟）
            await hrvIntegrator.startPolling()
        }
    }

    // MARK: - 管道回调设置 ────────────────────────────────────────────────────

    /// 把各子系统连接起来（类似电路板上的"接线"）。
    ///
    /// 设计原则：StatusBarController 是"连线者"，不是"实现者"。
    /// 每个子系统只知道自己的输入输出，不知道彼此。
    /// StatusBarController 负责把它们的输出接到正确的输入上。
    private func setupPipelineCallbacks() {

        // ── M4 新增：把 HRVIntegrator 注入 AnxietyPipeline ───────────────
        // 这样 AnxietyPipeline.computeDynamicThreshold() 就能访问 HRV 乘数
        // 注入的是 hrvIntegrator 实例（不是副本），AnxietyPipeline 持有弱引用即可
        // 注意：AnxietyPipeline 里 hrvIntegrator 是 var（可选），可以随时更换
        anxietyPipeline.hrvIntegrator = hrvIntegrator

        // ── 连线 1：CaptureCoordinator → AnxietyPipeline ─────────────────
        // 每次 OCR 有新结果，直接转交给 AnxietyPipeline 评分
        // [weak self] 避免循环引用（闭包持有 self，self 持有闭包 → 相互持有 → 内存泄漏）
        coordinator.onResult = { [weak self] result in
            self?.handleOCRResult(result)
        }

        // ── 连线 2：AnxietyPipeline → 调试窗口 + M5 账号检测 ────────────
        // 每帧评分完成后：
        //   a) 把结果推给调试窗口（即使没触发提醒也推，方便开发者观察）
        //   b) M5 新增：把 PipelineResult + 内容焦虑分转给 AccountDetector
        //      AccountDetector 会尝试识别账号，触发评估，计算综合分
        anxietyPipeline.onScore = { [weak self] scored in
            guard let self else { return }

            // a) 调试窗口：?. 是可选链，窗口没开时直接跳过
            self.debugWindowController?.appendEntry(scored)

            // b) M5 账号检测：把这帧的 OCR 管道结果 + 内容焦虑分送给 AccountDetector
            //    AccountDetector 内部判断是否是目标 App、是否有账号名，不满足条件直接忽略
            self.accountDetector.process(
                pipeline: scored.pipeline,                // OCR 结果（含 Bundle ID、App 名、文字）
                contentAnxietyScore: scored.anxiety.score // AnxietyPipeline 给出的内容焦虑分
            )

            // c) M9 实时 Dashboard：把焦虑分广播给所有 SSE 客户端（副屏浏览器实时更新）
            let appName = scored.pipeline.frontAppName ?? "未知"
            self.webMonitor.recordAnxiety(score: scored.anxiety.score, appName: appName)

            // e) M10 LED 矩阵：根据最新焦虑分切换表情（连接失败时静默忽略）
            self.ledMatrix.showFace(for: scored.anxiety.score)

            // d) M9：记录 Pipeline 延迟（OCR 耗时作为此阶段延迟的代理指标）
            self.webMonitor.recordLatency(
                totalMs: scored.pipeline.ocrResult.durationMs,
                stage: "ocr"
            )
        }

        // ── 连线 3：AnxietyPipeline → 提醒处理 ───────────────────────────
        // 当焦虑分超过动态阈值且冷却结束时，触发提醒
        anxietyPipeline.onAlert = { [weak self] scored in
            self?.handleAnxietyAlert(scored)
        }

        // ── 连线 4（M5）：AccountDetector → 账号级别提醒处理 ─────────────
        // 当 AccountDetector 计算出综合评分后，通知 StatusBarController
        // 触发比"单帧内容提醒"更深层的"账号风格提醒"
        accountDetector.onAccountDetected = { [weak self] result in
            guard let self else { return }
            self.handleAccountDetection(result)
            // M9：账号检测结果也推送到 Dashboard 热力图
            self.webMonitor.recordAccountDetection(
                accountName: result.detectedAccountName,
                platform: result.platform.rawValue,
                combinedScore: result.combinedScore
            )
        }

        // ── 连线 5（M9）：HRVIntegrator → Dashboard HRV 图表 ─────────────
        // HRV 更新时同步广播到 Dashboard（HRVIntegrator 的 onUpdate 回调在 M4 中定义）
        // 如果 HRVIntegrator 暴露了 onUpdate 闭包，在这里接入
        hrvIntegrator.onHRVUpdate = { [weak self] sdnn, rmssd in
            self?.webMonitor.recordHRV(sdnn: sdnn, rmssd: rmssd)
        }
    }

    // MARK: - 监控生命周期 ────────────────────────────────────────────────────

    /// 启动整个监控管道（屏幕录制权限检查 → 截图 → OCR → 评分）。
    ///
    /// 调用时机：App 启动时（ScreenMindApp.swift 里调用）。
    /// 权限检查是异步的（需要等用户在系统设置里授权），所以放在 Task 里。
    func startMonitoring() {
        Task {
            await coordinator.start() // 等待权限确认 + 启动截图流
            // 根据权限结果更新图标
            // 三目表达式：条件 ? 成立时的值 : 不成立时的值
            updateIcon(state: coordinator.permissionGranted ? .monitoring : .error)
        }
    }

    /// 停止监控（用户退出 App 前调用，或者手动停止时）。
    func stopMonitoring() {
        coordinator.stop()              // 停止截图流
        hrvIntegrator.stopPolling()     // M4：停止 HRV 后台轮询（避免 App 退出后任务泄漏）
        accountDetector.clearSessionCache() // M5：清空账号会话缓存（下次启动重新评估）
        webMonitor.stop()               // M9：停止 Dashboard HTTP 服务器
        ledMatrix.clear()               // M10：熄灭 LED 矩阵（全部灯关掉）
        ledMatrix.disconnect()          // M10：关闭串口连接
        updateIcon(state: .idle)        // 图标变灰（空闲状态）
    }

    /// 暂停监控 N 分钟（用于"我要专心工作，不要打扰我"场景）。
    ///
    /// 暂停期间不截图、不评分，N 分钟后自动恢复。
    /// - Parameter minutes: 暂停时长，默认 15 分钟
    func pauseMonitoring(minutes: Int = 15) {
        coordinator.pause(minutes: minutes) // CaptureCoordinator 内部有 Timer 管理恢复
        updateIcon(state: .paused)           // 图标变橙色（暂停状态）
    }

    // MARK: - OCR 结果处理（M3 入口）─────────────────────────────────────────

    /// 收到 OCR 结果后的处理函数——M3 的核心入口。
    ///
    /// M2 阶段：这里只打日志，什么都不做。
    /// M3 阶段：把 OCR 结果转交给 AnxietyPipeline，触发评分 + 存储 + 可能的提醒。
    ///
    /// 注意：AnxietyPipeline.process() 是非阻塞的（内部用 Task {} 异步执行评分）。
    /// 所以这个函数会立刻返回，不会等评分完成。
    private func handleOCRResult(_ result: PipelineResult) {
        let app = result.frontAppName ?? "未知应用"
        let chars = result.ocrResult.text.count
        // 打印一条 info 级别日志（在 Console.app 里可以看到）
        logger.info("OCR [\(app)] \(chars) chars, \(result.ocrResult.durationMs)ms → sending to AnxietyPipeline")

        // 把 OCR 结果交给 AnxietyPipeline 评分
        // 这一行替代了原来的 "TODO M3: 传给 AnxietyScorer"
        anxietyPipeline.process(result)
    }

    // MARK: - 焦虑提醒处理 ────────────────────────────────────────────────────

    /// 当 AnxietyPipeline 检测到高焦虑内容时，执行两件事：
    ///   1. 菜单栏图标变红（5 秒后自动恢复）
    ///   2. 发送 UNUserNotification（系统通知，出现在 Mac 右上角）
    ///
    /// 这个函数是 anxietyPipeline.onAlert 回调的实现。
    private func handleAnxietyAlert(_ result: AnxietyPipelineResult) {
        // ── 图标变红 ──────────────────────────────────────────────────────
        updateIcon(state: .anxious) // .anxious = 实心红色大脑图标

        // 5 秒后自动恢复正常图标（避免红色持续太久让用户紧张）
        Task {
            // Task.sleep：异步等待，不阻塞主线程
            // nanoseconds: 5_000_000_000 = 5 秒（1秒 = 10^9 纳秒）
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            // 根据当前实际状态决定恢复成哪个图标
            if coordinator.isPaused {
                updateIcon(state: .paused)     // 还在暂停中 → 橙色
            } else if coordinator.isRunning {
                updateIcon(state: .monitoring) // 正常运行中 → 白色
            }
        }

        let score    = result.anxiety.score
        let keywords = result.anxiety.dominantKeywords

        // ── M9：广播告警事件到 Dashboard ─────────────────────────────────
        webMonitor.recordAlertTriggered(
            reason: "内容焦虑分超阈值",
            threshold: result.dynamicThreshold
        )

        // ── M8：弹出 AlertPanel 浮窗 ─────────────────────────────────────
        // 从菜单栏图标弹出 SwiftUI 提醒浮窗（展示双模块放松建议）
        if let button = statusItem.button {
            alertPanelController.show(
                from: button,
                anxietyScore: score,
                threshold: result.dynamicThreshold,
                hrvMultiplier: result.hrvMultiplier,
                accountResult: lastAccountDetectionResult  // 最近的账号检测结果（可能是 nil）
            )
        }

        // ── 发送系统通知（AlertPanel 弹窗的补充，确保用户在全屏时也能看到） ─
        Task {
            await notificationManager.sendAnxietyAlert(
                score: score,
                keywords: keywords,
                suggestions: []  // M8 已通过 AlertPanel 展示建议，这里保持轻量通知
            )
        }

        logger.notice(
            "Alert sent: score=\(String(format: "%.2f", score)) " +
            "threshold=\(String(format: "%.2f", result.dynamicThreshold)) " +
            "keywords=\(keywords)"
        )
    }

    // MARK: - 账号检测结果处理（M5）────────────────────────────────────────────

    /// 当 AccountDetector 识别到账号并计算出综合评分后的处理函数。
    ///
    /// 触发条件：
    ///   - 当前 App 是抖音/微信
    ///   - OCR 文字里识别到账号名
    ///   - AccountAssessor 评估完成（或命中缓存）
    ///   - combinedScore >= accountDetector.alertThreshold（默认 0.70）
    ///
    /// 处理逻辑：
    ///   - 综合分低于阈值：只记日志，不打扰用户
    ///   - 综合分高于阈值：发送"账号风格提醒"通知（与普通内容提醒区分，给出账号说明）
    ///
    /// 【为什么不直接复用 handleAnxietyAlert？】
    /// 账号提醒和内容提醒是不同级别的信息：
    ///   - 内容提醒：这条内容很焦虑，建议休息一下
    ///   - 账号提醒：这个账号整体风格焦虑，可以考虑取关/减少刷
    /// 通知的文案和后续建议不同，分开处理更清晰。
    private func handleAccountDetection(_ result: AccountDetectionResult) {
        // M8：缓存最新账号检测结果，供下次 AlertPanel 展示时使用
        // 只缓存最近一次（AlertPanel 总是展示最新状态）
        lastAccountDetectionResult = result

        // 记录日志（每次账号检测都记录，方便调试）
        logger.info(
            "M5 账号检测: account=\(result.detectedAccountName) " +
            "[\(result.platform.rawValue)] " +
            "acct=\(String(format: "%.2f", result.accountScore)) " +
            "content=\(String(format: "%.2f", result.contentScore)) " +
            "combined=\(String(format: "%.2f", result.combinedScore)) " +
            "source=\(result.assessmentSource.rawValue)"
        )

        // 综合分低于阈值：不触发提醒，只记日志
        guard result.combinedScore >= accountDetector.alertThreshold else {
            logger.debug("综合分 \(String(format: "%.2f", result.combinedScore)) 未超阈值，跳过通知")
            return
        }

        // 综合分超过阈值：图标变红（视觉反馈）
        updateIcon(state: .anxious)

        // 5 秒后恢复正常图标
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if coordinator.isPaused {
                updateIcon(state: .paused)
            } else if coordinator.isRunning {
                updateIcon(state: .monitoring)
            }
        }

        // 发送"账号风格"通知（与普通内容提醒用不同文案，让用户知道这是账号级别警告）
        let accountName = result.detectedAccountName
        let notes = result.styleNotes
        let score = result.combinedScore

        Task {
            // 通知标题：告诉用户是账号级别的提醒（不是单条内容）
            // 这里传 styleNotes 作为通知正文，让用户了解账号内容风格
            await notificationManager.sendAnxietyAlert(
                score: score,
                keywords: ["账号：@\(accountName)", notes.isEmpty ? "高焦虑内容风格" : notes],
                suggestions: [] // M6 后接入 SuggestionEngine 提供真实建议
            )
        }

        logger.notice(
            "⚠️ M5 账号级提醒: account=@\(accountName) " +
            "combined=\(String(format: "%.2f", score))"
        )
    }

    // MARK: - 右键菜单 ────────────────────────────────────────────────────────

    /// 设置菜单栏图标的右键菜单（点击图标时显示）。
    ///
    /// 菜单项结构：
    ///   ScreenMind（禁用，仅作标题）
    ///   ─────────
    ///   暂停 15 分钟   [P]
    ///   OCR / 焦虑调试窗口  [D]
    ///   ─────────
    ///   偏好设置…  [,]
    ///   ─────────
    ///   退出 ScreenMind  [Q]
    private func setupMenu() {
        let menu = NSMenu()

        // 标题行（isEnabled = false 表示不可点击，只用来显示 App 名）
        let titleItem = NSMenuItem(title: "ScreenMind", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator()) // 分隔线

        // 暂停菜单项：点击时调用 pauseTapped()
        // action 是 ObjC selector（响应者模式），keyEquivalent 是键盘快捷键
        let pauseItem = NSMenuItem(title: "暂停 15 分钟",
                                   action: #selector(pauseTapped),
                                   keyEquivalent: "p")
        pauseItem.target = self // 告诉 NSMenu：点击时调用 self 的方法
        menu.addItem(pauseItem)

        // 调试窗口菜单项（M3 更新了标题，加上了"焦虑"字样）
        let debugItem = NSMenuItem(title: "OCR / 焦虑调试窗口",
                                   action: #selector(openDebug),
                                   keyEquivalent: "d")
        debugItem.target = self
        menu.addItem(debugItem)

        // M9 新增：实时监控 Dashboard 菜单项
        // 点击后在默认浏览器打开 http://localhost:9527
        // 建议把浏览器窗口拖到副屏并按 F 键全屏，实现科幻副屏效果
        let dashboardItem = NSMenuItem(title: "实时监控 Dashboard…",
                                       action: #selector(openDashboard),
                                       keyEquivalent: "m")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        // M10 新增：LED 矩阵状态显示（不可点击，只显示连接状态）
        // 格式：LED 矩阵：未连接 / 已连接 / 连接错误
        let ledStatusItem = NSMenuItem(title: "LED 矩阵：检测中…", action: nil, keyEquivalent: "")
        ledStatusItem.isEnabled = false
        ledStatusItem.tag = 1001  // 用 tag 在 updateLEDStatusMenuItem 里找到它
        menu.addItem(ledStatusItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "偏好设置…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        // 退出菜单：action 直接指向 NSApplication.terminate，不需要自定义方法
        menu.addItem(withTitle: "退出 ScreenMind",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        statusItem.menu = menu // 把菜单绑定到状态栏图标
    }

    // MARK: - M10 LED 矩阵菜单项更新 ──────────────────────────────────────────

    /// 更新菜单里"LED 矩阵"状态显示文字。
    /// 在 LEDMatrixController.onStateChanged 回调里被调用（主线程安全）。
    private func updateLEDStatusMenuItem(state: LEDConnectionState) {
        // 通过 tag=1001 找到对应菜单项
        // statusItem.menu?.item(withTag:) 遍历菜单找 tag 匹配的项
        guard let item = statusItem.menu?.item(withTag: 1001) else { return }
        item.title = "LED 矩阵：\(state.rawValue)"
    }

    // MARK: - 图标状态 ────────────────────────────────────────────────────────

    /// 菜单栏图标的视觉状态枚举。
    ///
    /// 每个 case 对应一种 App 状态，有不同的图标和颜色：
    ///   idle:       灰色大脑        → App 已启动但未开始监控
    ///   monitoring: 白色大脑        → 正常监控中
    ///   paused:     橙色大脑        → 已暂停（用户主动暂停）
    ///   error:      红色感叹号三角  → 权限被拒绝或系统错误
    ///   anxious:    红色实心大脑    → 刚检测到焦虑内容（5秒后恢复）
    enum IconState { case idle, monitoring, paused, error, anxious }

    /// 根据状态更新菜单栏图标的图案和颜色。
    ///
    /// SF Symbols：苹果提供的矢量图标库，通过名称字符串引用。
    /// brain.head.profile = 侧脸大脑图标（空心）
    /// brain.head.profile.fill = 侧脸大脑图标（实心，用于焦虑状态）
    /// exclamationmark.triangle = 感叹号三角（错误状态）
    private func updateIcon(state: IconState) {
        // Swift 的 switch 表达式（可以直接赋值）
        let (symbolName, color): (String, NSColor) = switch state {
        case .idle:       ("brain.head.profile",      .secondaryLabelColor) // 灰色
        case .monitoring: ("brain.head.profile",      .controlTextColor)    // 白色/黑色（跟随系统主题）
        case .paused:     ("brain.head.profile",      .systemOrange)        // 橙色
        case .error:      ("exclamationmark.triangle", .systemRed)           // 红色感叹号
        case .anxious:    ("brain.head.profile.fill",  .systemRed)           // 红色实心
        }

        // 用 SF Symbols 名称创建图标
        statusItem.button?.image = NSImage(systemSymbolName: symbolName,
                                           accessibilityDescription: "ScreenMind")
        // 设置图标染色
        statusItem.button?.contentTintColor = color
    }

    // MARK: - 菜单动作（@objc 方法）─────────────────────────────────────────

    /// 暂停 15 分钟的菜单动作。
    ///
    /// @objc 表示这个方法暴露给 Objective-C 运行时，
    /// 这样 NSMenuItem 的 action 机制（基于 ObjC）才能调用到它。
    @objc private func pauseTapped() {
        pauseMonitoring(minutes: 15)
    }

    /// M9：在默认浏览器中打开实时监控 Dashboard。
    ///
    /// http://localhost:9527 是 WebMonitorServer 监听的本地地址。
    /// 建议把浏览器窗口拖到副屏，按 F 键全屏，享受科幻副屏效果。
    @objc private func openDashboard() {
        // NSWorkspace.shared.open 会用系统默认浏览器打开 URL
        if let url = webMonitor.dashboardURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开调试窗口。
    ///
    /// 使用懒加载（lazy creation）：
    ///   - 第一次点击时创建 DebugWindowController
    ///   - 之后复用同一个实例（窗口关闭但不销毁）
    @objc private func openDebug() {
        // 如果还没有调试窗口，先创建一个
        if debugWindowController == nil {
            debugWindowController = DebugWindowController()
        }
        debugWindowController?.showWindow(nil) // 显示窗口
        debugWindowController?.window?.makeKeyAndOrderFront(nil) // 把窗口置到最前面
        NSApp.activate(ignoringOtherApps: true) // 让 App 获得焦点（在其他 App 上面弹出来）
    }

    /// 打开偏好设置窗口。
    ///
    /// SettingsWindowController.shared：设置窗口也是单例（全 App 只有一个）。
    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
