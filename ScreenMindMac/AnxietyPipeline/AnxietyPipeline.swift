// =============================================================================
//  AnxietyPipeline.swift
//  ScreenMindMac — Mac 端主应用
// =============================================================================
//
//  【里程碑 M3：焦虑评分引擎】
//  这是 M3 阶段新增的核心文件。
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenMindMac 的 OCR 管道（CaptureCoordinator）已经能识别屏幕文字（M2 完成）。
//  M3 的任务是："拿到这些文字后，判断它们是否让人焦虑，并把结果存起来。"
//
//  AnxietyPipeline 就是这个"判断 + 存储"的调度中心（Pipeline = 管道/流水线）。
//
//  【完整数据流】
//  ┌─────────────────────────────────────────────────────────────────────────┐
//  │                          ScreenMindMac 数据流                           │
//  │                                                                         │
//  │  屏幕截图                                                               │
//  │     ↓ (ScreenCaptureManager, 每30秒)                                   │
//  │  CVPixelBuffer（原始图像帧）                                            │
//  │     ↓ (OCREngine, Vision 框架)                                         │
//  │  OCRResult（识别出的文字 + 去重）                                       │
//  │     ↓ (CaptureCoordinator.onResult)                                    │
//  │  PipelineResult（文字 + 当前 App 名）                                  │
//  │     ↓ (StatusBarController → AnxietyPipeline.process)  ← 本文件入口    │
//  │  AnxietyScorer.analyze()  ← 两阶段评分（Stage 1: NL, Stage 2: LLM）   │
//  │     ↓                                                                  │
//  │  AnxietyPipelineResult（评分 + 动态阈值 + 是否触发提醒）                │
//  │     ↓ 持久化               ↓ 调试窗口            ↓ 焦虑提醒            │
//  │  Core Data               DebugWindow           通知 + 图标变红          │
//  └─────────────────────────────────────────────────────────────────────────┘
//
//  【AnxietyPipeline 在其中的角色】
//  它是"中间层"：上游拿 PipelineResult，下游推 3 路输出（存储/显示/提醒）。
//  所有时序控制（冷却、动态阈值）都在这里管理。
//
//  【部署位置】
//  ScreenMindMac/AnxietyPipeline/AnxietyPipeline.swift
//  这个文件只属于 Mac 端（因为依赖 AppKit 和 ScreenCaptureKit）。
//
// =============================================================================

import Foundation  // 提供 Date、Timer、UUID、TimeInterval 等基础类型
import AppKit      // macOS 界面框架（虽然 AnxietyPipeline 本身不直接画 UI，
                   // 但它调用的 NotificationManager 间接依赖 AppKit）
import ScreenMindCore  // 我们自己的共享包，提供 AnxietyScorer、AnxietyResult、PersistenceController 等
import OSLog       // Apple 的结构化日志框架（比 print() 更好：有分类、有级别、Instruments 可分析）

// 创建一个日志器，subsystem 是反向域名格式的 App 标识，category 表示这是哪个模块的日志
private let logger = Logger(subsystem: "com.screenmind.mac", category: "AnxietyPipeline")

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 数据结构：单帧完整分析结果
// MARK: ──────────────────────────────────────────────────────────────────────

/// 一帧 OCR 完整分析后的结果包，包含 5 个维度的信息。
///
/// 【为什么要把这 5 个东西打包成一个 struct？】
/// 因为调试窗口、通知系统、Core Data 都需要这些信息，
/// 打包成一个结构体可以用一次回调传递所有数据，避免回调参数太多（超过 3 个参数就很难读懂）。
///
/// 【M4 新增 hrvMultiplier 字段】
/// M4 阶段接入了 HealthKit HRV 数据，动态阈值现在受 HRV 影响。
/// 把 HRV 乘数也打包进来，方便调试窗口显示"这次阈值是怎么算出来的"。
///
/// struct 是值类型，在 Swift 的 async/await 并发环境中传递更安全（不用担心竞争条件）。
struct AnxietyPipelineResult {
    /// 原始 OCR 管道结果（包含文字内容、时间戳、App 名称）
    let pipeline: PipelineResult

    /// AnxietyScorer 的分析结果（焦虑分 + 关键词 + 来源 + 耗时）
    let anxiety: AnxietyResult

    /// 本帧使用的动态阈值（M4 后 = M3文本阈值 × HRV乘数，钳位在 [0.35, 0.90]）
    let dynamicThreshold: Double

    /// 本帧是否触发了焦虑提醒（超过阈值 + 冷却时间已过）
    let didTriggerAlert: Bool

    /// 本帧使用的 HRV 乘数（M4 新增）。
    ///
    /// 范围通常在 [0.4, 1.6] 附近，经新鲜度混合后可能更接近 1.0。
    /// 值为 1.0 表示：没有 HRV 数据（Level 4），或 HRV 和基线持平。
    /// 供调试窗口显示"HRV × 乘数"，帮助开发者理解阈值变化原因。
    let hrvMultiplier: Double
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 核心类：AnxietyPipeline
// MARK: ──────────────────────────────────────────────────────────────────────

/// M3 焦虑评分引擎——连接 OCR 输出与下游（存储/提醒/显示）的调度中心。
///
/// 【@MainActor 是什么意思？】
/// @MainActor 是 Swift Concurrency 的一个关键字，表示这个类的所有方法都在主线程运行。
/// 为什么要在主线程？
///   - UI 操作（更新调试窗口、改菜单栏图标）必须在主线程
///   - 菜单栏 App 的大部分状态管理在主线程最安全
///   - AnxietyScorer.analyze() 是 async 函数，它会在后台线程运行后自动回到主线程
///
/// 【final 是什么意思？】
/// 不允许其他类继承 AnxietyPipeline。这是一个设计决策：
///   - 不需要子类化（没有"MacAnxietyPipeline" vs "iOSAnxietyPipeline"的区分）
///   - final 还能让编译器做优化（方法调用更快）
@MainActor
final class AnxietyPipeline {

    // MARK: - 可配置参数 ────────────────────────────────────────────────────

    /// 静态基准阈值（范围 0.0–1.0）。
    ///
    /// 当历史帧数据不足（< 5 帧）时，直接用这个值判断是否触发提醒。
    /// 默认 0.60 意思是：焦虑分超过 60% 就认为是需要提醒的内容。
    ///
    /// 为什么是 0.60？
    /// 实际测试中，纯正面内容（新闻、天气）评分约 0.4–0.5，
    /// 明确负面内容（股市崩盘、社会事件）评分约 0.65–0.85。
    /// 0.60 在两者之间，既不会漏报，也不会误报。
    var baseThreshold: Double = 0.60

    /// 两次提醒之间的最短间隔（秒）。默认 300 秒 = 5 分钟。
    ///
    /// 产品需求：用户被提醒后，如果一直在看焦虑内容，不要每 30 秒就推一条通知（那样很烦）。
    /// 5 分钟冷却可以在提醒有效性和减少骚扰之间取得平衡。
    var cooldownSeconds: TimeInterval = 300

    /// 动态阈值的计算窗口大小（帧数）。
    ///
    /// 程序会记住最近 N 帧的焦虑分，计算均值，然后以"均值 + 偏移"作为动态阈值。
    /// 需要至少 5 帧数据才启用动态阈值，不足时使用 baseThreshold。
    var rollingWindowSize: Int = 20

    /// 动态阈值 = 近 N 帧均值 + 此偏移量。
    ///
    /// 【为什么要有动态阈值？】
    /// 问题：用户在刷"财经负面新闻 App"时，每帧都是 0.65，一直超过 0.60，一直提醒。
    /// 解决：动态阈值会自适应上升（均值 0.65 + 偏移 0.15 = 阈值 0.80），
    ///       只有更加极端的内容（超过 0.80）才触发提醒。
    ///       这样用户在"轻度负面信息场景"里不会被频繁打扰。
    var dynamicOffsetAboveMean: Double = 0.15

    // MARK: - 回调闭包（Callback）──────────────────────────────────────────

    /// 每帧评分完成后的回调，主要用于更新调试窗口。
    ///
    /// 【什么是回调闭包？】
    /// 闭包（Closure）是可以当变量传递的函数片段。
    /// 回调（Callback）意思是："你来帮我做一件事，做完了调用这个函数通知我"。
    ///
    /// 这里：
    ///   var onScore: ((AnxietyPipelineResult) -> Void)?
    ///   - ((AnxietyPipelineResult) -> Void) 是类型：接受 AnxietyPipelineResult 参数、无返回值的函数
    ///   - ? 表示可选（Optional），没有设置时是 nil，调用时不会崩溃
    ///
    /// 设置示例（在 StatusBarController.swift 里）：
    ///   anxietyPipeline.onScore = { result in
    ///       debugWindowController?.appendEntry(result)
    ///   }
    var onScore: ((AnxietyPipelineResult) -> Void)?

    /// 焦虑阈值触发时的回调，用于更新菜单栏图标 + 发送系统通知。
    ///
    /// 只有满足两个条件才触发：
    ///   1. 本帧焦虑分 >= 动态阈值
    ///   2. 上次提醒到现在已经超过 cooldownSeconds（冷却结束）
    var onAlert: ((AnxietyPipelineResult) -> Void)?

    // MARK: - 内部组件 ──────────────────────────────────────────────────────

    /// AnxietyScorer 实例（两阶段评分引擎）。
    /// 这里直接 new 一个，不需要依赖注入（因为 AnxietyScorer 没有外部副作用）。
    private let scorer = AnxietyScorer()

    /// Core Data 存储控制器（单例）。
    /// .shared 表示整个 App 共用一个实例，不重复初始化数据库。
    private let persistence = PersistenceController.shared

    // MARK: - M4 新增：HRV 动态阈值乘数 ──────────────────────────────────

    /// HRV 乘数提供者（M4 新增）。可选：没有接入时阈值不受 HRV 影响。
    ///
    /// 设计为可选（Optional）的原因：
    ///   - HealthKit 权限可能被用户拒绝
    ///   - 单元测试时不需要 HealthKit（可以注入 nil）
    ///   - 未来 iOS 端可以统一用同一个 AnxietyPipeline，但 HRVIntegrator 是独立的
    ///
    /// 设置方：StatusBarController.setupPipelineCallbacks() 里注入
    ///   anxietyPipeline.hrvIntegrator = self.hrvIntegrator
    var hrvIntegrator: HRVIntegrator?

    // MARK: - 内部状态 ──────────────────────────────────────────────────────

    /// 上一次触发提醒的时间。初始值 nil 表示从未提醒过。
    /// 用于判断冷却时间是否已过。
    private var lastAlertTime: Date?

    /// 最近 N 帧的焦虑分数组（滑动窗口）。
    ///
    /// 每帧处理完后，把焦虑分 append 进来。
    /// 超过 rollingWindowSize 时删掉最旧的那个。
    /// 用这个数组的均值来计算动态阈值（M3 文本驱动部分）。
    private var recentScores: [Double] = []

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 公开入口：处理一帧 OCR 结果
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 处理一帧 OCR 输出。这是整个 AnxietyPipeline 的唯一入口。
    ///
    /// 调用时机：每次 CaptureCoordinator 有新的 OCR 结果时，
    ///           StatusBarController 会调用这个方法。
    ///
    /// 设计说明：
    ///   1. 立刻在 Task {} 里开始异步执行（不阻塞主线程）
    ///   2. AnxietyScorer.analyze() 可能需要几秒（LLM 路径），用 await 等待
    ///   3. 结果出来后用 await MainActor.run {} 切回主线程更新 UI
    ///
    /// - Parameter result: CaptureCoordinator 产生的 OCR 结果
    func process(_ result: PipelineResult) {
        // Task {} 创建一个新的并发任务（在后台线程）
        // [weak self] 避免循环引用（AnxietyPipeline 持有闭包，闭包不能强持有 AnxietyPipeline）
        Task { [weak self] in
            guard let self else { return }  // 如果 self 已经被释放了，直接退出

            // 调用两阶段评分（可能需要最多 15 秒，如果走 LLM 路径）
            // await 表示：先暂停这个 Task，等 analyze() 完成后再继续
            let anxietyResult = await scorer.analyze(text: result.ocrResult.text)

            // 评分完成，切回主线程处理结果（UI 更新必须在主线程）
            await MainActor.run {
                self.handleScoredResult(anxietyResult, pipelineResult: result)
            }
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 内部：处理评分结果（主线程）
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 在主线程上处理评分结果：更新窗口、判断提醒、写入数据库。
    ///
    /// 这个函数是私有的（private），只有 process() 调用它。
    /// 把逻辑分开的原因：process() 处理"异步调度"，这里处理"结果处理"，职责清晰。
    private func handleScoredResult(_ anxietyResult: AnxietyResult,
                                    pipelineResult: PipelineResult) {
        // ── 步骤 1：更新滑动窗口 ──────────────────────────────────────
        recentScores.append(anxietyResult.score) // 把本帧分数加入历史记录

        // 如果超过窗口大小，删掉最旧的那个（FIFO 队列）
        if recentScores.count > rollingWindowSize {
            recentScores.removeFirst()
        }

        // ── 步骤 2：计算动态阈值（M4：文本阈值 × HRV乘数）────────────
        // computeDynamicThreshold() 已经把 HRV 乘数应用进去了
        // 同时返回 (最终阈值, HRV乘数) 供结果打包
        let (threshold, hrvMult) = computeDynamicThreshold()

        // ── 步骤 3：判断是否触发提醒 ──────────────────────────────────
        let shouldAlert = checkShouldAlert(score: anxietyResult.score, threshold: threshold)

        // ── 步骤 4：打包本帧完整结果（M4：新增 hrvMultiplier 字段）───
        let result = AnxietyPipelineResult(
            pipeline: pipelineResult,
            anxiety: anxietyResult,
            dynamicThreshold: threshold,
            didTriggerAlert: shouldAlert,
            hrvMultiplier: hrvMult  // M4 新增：HRV 乘数（供调试窗口显示）
        )

        // ── 步骤 5：写入 Core Data（后台线程，不阻塞 UI）────────────
        persistRecord(result)

        // ── 步骤 6：通知调试窗口（每帧都推，不管是否触发提醒）───────
        onScore?(result) // ? 表示：如果 onScore 是 nil（没设置回调），就什么都不做

        // ── 步骤 7：触发提醒（仅当 shouldAlert = true 时）────────────
        if shouldAlert {
            lastAlertTime = Date() // 更新冷却时间戳（从现在开始计算冷却）
            onAlert?(result)       // 通知 StatusBarController 去改图标 + 发通知

            // 打印一条醒目的日志（.notice 级别会在 Console.app 里以黄色显示）
            logger.notice(
                "⚠️ 焦虑触发！score=\(String(format: "%.2f", anxietyResult.score)) " +
                "threshold=\(String(format: "%.2f", threshold)) " +
                "app=[\(pipelineResult.frontAppName ?? "?")]"
            )
        } else {
            // 普通 debug 日志（.debug 级别默认不在 Console 里显示，需要手动开启）
            logger.debug(
                "score=\(String(format: "%.2f", anxietyResult.score)) " +
                "threshold=\(String(format: "%.2f", threshold)) " +
                "source=\(anxietyResult.source.rawValue) " +
                "app=[\(pipelineResult.frontAppName ?? "?")]"
            )
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 动态阈值计算
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 计算本帧应该使用的动态阈值（M4 版本：结合文本滑动窗口 + HRV 乘数）。
    ///
    /// 【两阶段算法详解】
    ///
    /// 阶段 1（M3，文本驱动）：
    ///   情景：用户打开了财经 App，近 20 帧均值 ≈ 0.65
    ///   M3 文本阈值 = 0.65 + 0.15（偏移）= 0.80
    ///   → 只有极端内容（> 0.80）才触发提醒（避免频繁打扰）
    ///
    /// 阶段 2（M4，HRV 调整）：
    ///   今天用户 HRV 低（压力大），HRV 乘数 = 0.75
    ///   最终阈值 = 0.80 × 0.75 = 0.60（阈值降低，更容易触发提醒）
    ///   → 身体已经很紧张了，应该更积极地提醒用户休息
    ///
    ///   如果 HRV 高（放松），HRV 乘数 = 1.2
    ///   最终阈值 = 0.80 × 1.2 = 0.90 → clamp 到 0.90
    ///   → 身体很放松，可以承受更多信息，不那么容易触发
    ///
    /// 返回值：(最终阈值, HRV乘数)
    ///   两个值都打包返回，避免重复计算（调用方同时需要两个值）
    ///
    /// - Returns: (finalThreshold 最终阈值 [0.35, 0.90], hrvMultiplier HRV乘数)
    private func computeDynamicThreshold() -> (threshold: Double, hrvMultiplier: Double) {
        // ── 步骤 1：M3 文本驱动阈值 ──────────────────────────────────
        // 数据不足 5 帧时用静态 baseThreshold（初始期没有历史数据）
        let textThreshold: Double
        if recentScores.count >= 5 {
            // reduce(0.0, +)：把数组所有元素加在一起
            let mean = recentScores.reduce(0.0, +) / Double(recentScores.count)
            // 动态偏移：均值 + 偏移量，限制在 [0.45, 0.85]
            textThreshold = min(max(mean + dynamicOffsetAboveMean, 0.45), 0.85)
        } else {
            textThreshold = baseThreshold  // 数据不足，用静态基准
        }

        // ── 步骤 2：M4 HRV 乘数调整 ──────────────────────────────────
        // 如果没有接入 HRVIntegrator（未授权/单元测试），乘数 = 1.0（不调整）
        let hrvMult = hrvIntegrator?.currentMultiplier ?? 1.0

        // 最终阈值 = 文本阈值 × HRV乘数，钳位在 [0.35, 0.90]
        // 注意：这里不用 HRVIntegrator.adjustedThreshold()，
        //       因为我们需要拿到 hrvMult 供打包到 AnxietyPipelineResult
        let finalThreshold = min(max(textThreshold * hrvMult, 0.35), 0.90)

        return (finalThreshold, hrvMult)
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 提醒门控：阈值 + 冷却
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 判断本帧是否应该触发提醒（两个条件必须同时满足）。
    ///
    /// 条件 1：焦虑分 >= 动态阈值
    ///   → 内容确实够负面
    ///
    /// 条件 2：冷却时间已过（或从未提醒过）
    ///   → 上次提醒 5 分钟前已经结束，不会立刻再推一条
    ///
    /// - Parameters:
    ///   - score: 本帧焦虑分（0.0–1.0）
    ///   - threshold: 本帧动态阈值
    /// - Returns: true 表示应该触发提醒，false 表示不触发
    private func checkShouldAlert(score: Double, threshold: Double) -> Bool {
        // 第一关：分数不达标，直接返回 false
        guard score >= threshold else { return false }

        // 第二关：检查冷却
        // 如果 lastAlertTime 是 nil（从未提醒过），说明可以触发
        guard let last = lastAlertTime else { return true }

        // 计算距上次提醒过了多少秒
        let elapsed = Date().timeIntervalSince(last)
        // 只有超过 cooldownSeconds 才允许再次提醒
        return elapsed >= cooldownSeconds
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: Core Data 持久化
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 把本帧分析结果写入 Core Data 数据库（异步后台执行）。
    ///
    /// 【为什么要存数据库？】
    /// 产品功能（M5 之后）：
    ///   - "我今天的焦虑指数趋势图"
    ///   - "哪个 App 最让我焦虑？"
    ///   - 和 HealthKit HRV 数据做关联分析
    /// 这些都需要历史数据，所以每帧都要存。
    ///
    /// 【为什么要用 background context？】
    /// Core Data 有两种 context：
    ///   - viewContext（主线程）：用于读取数据给 UI 显示
    ///   - backgroundContext（后台线程）：用于写入数据（写操作耗时，不能阻塞 UI）
    /// 这里用 background context 写入，保证 UI 丝滑不卡顿。
    ///
    /// 【数据写入的线程安全保证】
    /// ctx.perform {} 是 Core Data 的线程安全调用方式：
    ///   "在这个 context 对应的队列上执行这段代码"。
    ///   不直接在当前线程执行，避免数据竞争。
    private func persistRecord(_ result: AnxietyPipelineResult) {
        // 获取一个新的后台 context（每次写入用独立的 context，避免状态污染）
        let ctx = persistence.newBackgroundContext()

        // 提取所有需要写入的值（值类型，可以安全跨线程传递）
        // 如果直接在 ctx.perform 里访问 result.xxx，会有 actor 隔离问题
        let id          = UUID()                                  // 生成唯一 ID
        let timestamp   = result.pipeline.ocrResult.timestamp    // OCR 发生的时间
        let score       = result.anxiety.score                   // 焦虑分
        let rawText     = String(result.pipeline.ocrResult.text.prefix(500)) // 前 500 字
        let appName     = result.pipeline.frontAppName            // 当时的前景 App
        let threshold   = result.dynamicThreshold                 // 使用的阈值
        let alerted     = result.didTriggerAlert                  // 是否触发了提醒

        // 在 background context 的线程上执行写入
        ctx.perform {
            // 创建一个新的 AnxietyRecord 对象（Core Data 会自动追踪这个对象的变化）
            let record                 = AnxietyRecord(context: ctx)
            record.id                  = id
            record.timestamp           = timestamp
            record.anxietyScore        = score
            record.rawText             = rawText
            record.appName             = appName
            record.platform            = "mac"             // 写死为 "mac"
            record.dynamicThreshold    = threshold
            record.notificationSent    = alerted           // 是否发过通知

            // 保存到数据库（写磁盘）
            do {
                try ctx.save()
            } catch {
                // 写入失败（磁盘满了？文件损坏？）记录错误，但不崩溃
                logger.error("Core Data save failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 对外暴露的统计数据（供设置/调试 UI 读取）
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 最近 N 帧的平均焦虑分。
    ///
    /// 供设置窗口显示"当前焦虑基线"，帮助用户理解动态阈值是怎么计算的。
    /// 如果还没有任何历史数据，返回 nil（UI 可以显示 "—"）。
    var recentMeanScore: Double? {
        guard !recentScores.isEmpty else { return nil }
        return recentScores.reduce(0.0, +) / Double(recentScores.count)
    }

    /// 当前正在使用的动态阈值（实时值，每帧都可能变化）。
    ///
    /// 调试窗口用这个值在每条日志旁边显示 "threshold=0.72"，
    /// 方便开发者验证动态阈值逻辑是否正确。
    var currentDynamicThreshold: Double {
        computeDynamicThreshold().threshold // 每次访问都重新计算
    }

    /// 距下次允许触发提醒还需要等多少秒。
    ///
    /// 值为 0 表示冷却已结束，可以立即触发提醒。
    /// 调试时可以打印这个值，验证冷却逻辑是否正确。
    var cooldownRemainingSeconds: TimeInterval {
        guard let last = lastAlertTime else { return 0 } // 从未提醒过，不需要等
        let elapsed = Date().timeIntervalSince(last)
        return max(0, cooldownSeconds - elapsed)         // 不返回负数
    }
}
