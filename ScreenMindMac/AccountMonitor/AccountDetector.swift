// =============================================================================
//  AccountDetector.swift
//  ScreenMindMac — Mac 端主应用
// =============================================================================
//
//  【里程碑 M5-Mac：账号检测器 + 综合评分合并器】
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenMind 不仅要评估"这条内容让我焦虑吗"（AnxietyPipeline 已经做了），
//  还要评估"我正在看的这个账号，整体内容风格是高焦虑的吗？"
//
//  比如：
//    - 用户正在看一条"今天天气很好"的抖音视频，内容本身不焦虑（分 0.3）
//    - 但发布者是"末日财经大V"，账号风格极度焦虑（分 0.9）
//    - 综合评分 = 0.3 × 60% + 0.9 × 40% = 0.18 + 0.36 = 0.54
//    - 合并后才能更准确地判断"用户是否处于焦虑内容环境"
//
//  AccountDetector 就是负责"从屏幕文字里找到账号名 → 触发评估 → 合并两路分数"的模块。
//
//  【与 MacAccountMonitor.swift 的关系】
//  MacAccountMonitor（旧文件）：功能简单，只发通知，不参与评分管道，后续废弃。
//  AccountDetector（本文件 M5）：深度集成到 AnxietyPipeline，参与综合评分计算。
//
//  【数据流（M5 新增路径）】
//  ┌───────────────────────────────────────────────────────────────────────┐
//  │                  M5 账号检测数据流（新增）                              │
//  │                                                                       │
//  │  AnxietyPipeline.onScore（每帧评分完成后触发）                         │
//  │       ↓                                                               │
//  │  AccountDetector.process(pipeline: scored.pipeline,                   │
//  │                          contentAnxietyScore: scored.anxiety.score)   │
//  │       ↓ 用 OCR 文字 + App Bundle ID 识别账号名                        │
//  │  extractAccount(from:bundleID:) → (accountName, platform) or nil      │
//  │       ↓ 命中账号                                                       │
//  │  检查 sessionCache（本次会话内同一账号只评估一次）                      │
//  │       ↓ 缓存未命中                                                     │
//  │  AccountAssessor.assess(accountName:platform:)                        │
//  │   （内部先查 Core Data 缓存 → 豆包 API → Ollama fallback）             │
//  │       ↓ 评估完成                                                       │
//  │  computeCombinedScore(contentScore, accountScore)                     │
//  │   combinedScore = contentScore × 0.6 + accountScore × 0.4            │
//  │       ↓                                                               │
//  │  onAccountDetected?(AccountDetectionResult)                           │
//  │       ↓ （StatusBarController 接收）                                  │
//  │  更新菜单栏图标 / 发通知 / 写调试日志                                  │
//  └───────────────────────────────────────────────────────────────────────┘
//
//  【部署位置】
//  ScreenMindMac/AccountMonitor/AccountDetector.swift
//  仅 Mac 端使用（因为账号识别依赖 macOS OCR 管道的 PipelineResult）
//
// =============================================================================

import Foundation      // 基础类型（UUID、Date、NSRegularExpression 等）
import ScreenMindCore  // 共享包，提供 AccountAssessor、AccountAssessment、AccountPlatform 等
import OSLog           // Apple 结构化日志（比 print 更好，有分类和级别）

// 创建专属日志器（每个模块一个，方便在 Console.app 里按类别过滤）
private let logger = Logger(subsystem: "com.screenmind.mac", category: "AccountDetector")

// =============================================================================
// MARK: - 数据结构：账号检测+合并评分结果
// =============================================================================

/// 一次账号检测 + 综合评分计算的完整结果。
///
/// 当 AccountDetector 在屏幕文字中识别到一个平台账号，
/// 并且对该账号完成焦虑倾向评估后，就会产生这个结果。
///
/// 【为什么要把这么多字段打包在一起？】
/// StatusBarController 需要用这些信息做 4 件事：
///   1. 更新菜单栏图标（用 combinedScore）
///   2. 发系统通知（用 detectedAccountName + styleNotes）
///   3. 写调试日志（用 accountScore + contentScore + combinedScore）
///   4. 存 Core Data（未来扩展）
/// 打包成一个 struct，一次回调传递所有信息，清晰易读。
///
/// Sendable：Swift 并发安全标记，表示这个 struct 可以安全地在线程间传递。
/// 因为所有属性都是值类型（Double、String 等），天然满足 Sendable。
public struct AccountDetectionResult: Sendable {

    /// 本次检测到的账号名（去掉 "@" 符号后的纯名称，如 "某某财经"）
    public let detectedAccountName: String

    /// 账号所在平台（抖音 / 微信公众号）
    public let platform: AccountPlatform

    /// 账号风格焦虑分（由 AccountAssessor 评估，0.0–1.0）
    /// 0.0 = 账号内容完全不焦虑（旅游、美食、正能量）
    /// 1.0 = 账号内容极度焦虑（末日财经、社会负面事件）
    public let accountScore: Double

    /// 本帧 OCR 内容焦虑分（由 AnxietyPipeline 提供，0.0–1.0）
    /// 这是"当前这条内容"的分数，与账号整体风格无关
    public let contentScore: Double

    /// 综合焦虑分 = contentScore × contentWeight + accountScore × accountWeight
    /// 默认权重：内容 60%，账号 40%
    /// 这个分数供 StatusBarController 决定是否触发更高级别提醒
    public let combinedScore: Double

    /// AccountAssessor 对账号内容风格的文字描述（LLM 生成）
    /// 例如："该账号主要发布财经末日预警类内容，情绪渲染强烈，焦虑信息密度高。"
    public let styleNotes: String

    /// 这次账号评估由哪个引擎完成（豆包 / Ollama / Core Data 缓存）
    public let assessmentSource: AssessmentSource
}

// =============================================================================
// MARK: - 核心类：AccountDetector
// =============================================================================

/// M5 账号检测器：从 OCR 文字中识别平台账号，触发评估，合并两路焦虑分数。
///
/// 【@MainActor 说明】
/// @MainActor 表示这个类的所有方法都在主线程（UI 线程）执行。
/// 原因：
///   1. onAccountDetected 回调后，StatusBarController 要更新 UI（必须主线程）
///   2. sessionCache 的读写不需要锁（主线程天然串行，没有并发问题）
///   3. 与 StatusBarController（同样是 @MainActor）交互更方便
///
/// 内部使用 Task {} 异步调用 AccountAssessor（AccountAssessor 是 async 方法），
/// 评估完成后用 await MainActor.run {} 切回主线程触发回调。
@MainActor
final class AccountDetector {

    // MARK: - 可配置参数 ──────────────────────────────────────────────────────

    /// 内容焦虑分在综合分中的权重（默认 60%）。
    ///
    /// 【为什么内容权重更高？】
    /// "当前内容"反映的是用户此刻接收的信息，
    /// "账号风格"是一种背景/趋势，不一定每条都体现。
    /// 60/40 权重平衡了实时性（内容分）和历史规律（账号分）。
    var contentWeight: Double = 0.6

    /// 账号焦虑分在综合分中的权重（默认 40%）。
    ///
    /// contentWeight + accountWeight 应该 = 1.0（但 AccountDetector 内部不强制校验，
    /// 调用方可以根据实验调整，比如改成 50/50 或 70/30）。
    var accountWeight: Double = 0.4

    /// 综合分触发额外提醒的阈值（默认 0.70）。
    ///
    /// 当 combinedScore >= alertThreshold 时，onAccountDetected 回调里的 combinedScore
    /// 会让 StatusBarController 考虑发出"账号级别"的特殊提醒（比 单条内容提醒 更严重）。
    var alertThreshold: Double = 0.70

    // MARK: - 回调闭包 ────────────────────────────────────────────────────────

    /// 账号检测完成并计算出综合分后的回调。
    ///
    /// 触发时机：
    ///   1. OCR 文字里识别到支持平台的账号名
    ///   2. AccountAssessor 完成评估（或命中 sessionCache）
    ///   3. 综合分计算完成
    ///
    /// 由 StatusBarController 在 setupPipelineCallbacks() 里设置：
    ///   accountDetector.onAccountDetected = { [weak self] result in
    ///       self?.handleAccountDetection(result)
    ///   }
    var onAccountDetected: ((AccountDetectionResult) -> Void)?

    // MARK: - 内部组件 ────────────────────────────────────────────────────────

    /// 账号评估引擎（Core 层，双引擎：豆包 API + 本地 Ollama）。
    ///
    /// 负责判断一个账号的内容风格是否高焦虑。
    /// 内部有 Core Data 缓存（豆包结果 30 天，Ollama 结果 7 天），
    /// 所以 "最终触发真实 API 调用" 的概率很低。
    private let assessor = AccountAssessor()

    // MARK: - 内部状态 ────────────────────────────────────────────────────────

    /// 本次 App 运行期间的评估缓存（内存级别，SessionCache）。
    ///
    /// 【为什么除了 Core Data 缓存还需要这个内存缓存？】
    /// AccountAssessor 内部已经有 Core Data 缓存（30天/7天），
    /// 但 Core Data 的 fetch 本身也需要一次磁盘 I/O。
    /// sessionCache 存在内存里，命中时连磁盘都不用访问，速度最快（< 0.1ms）。
    ///
    /// 生命周期：App 运行期间一直有效。App 退出后清空（内存释放）。
    /// 如果账号内容风格临时改变，重启 App 才会重新评估（属于可接受的延迟）。
    ///
    /// Key: accountName（账号名，全小写去空格标准化）
    /// Value: AccountAssessment（评估结果）
    private var sessionCache: [String: AccountAssessment] = [:]

    /// 正在评估中的账号 Set（防止对同一账号发起多次并发请求）。
    ///
    /// 场景：用户一直在看同一个账号，每 30 秒来一帧 OCR，
    /// 每帧都识别出同一个账号名，但第一次评估可能还没完成（LLM 需要 2-5 秒）。
    /// 这个 Set 确保同一账号在任何时刻最多只有一个评估请求在飞。
    private var pendingAssessments: Set<String> = []

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 公开入口：处理一帧 OCR 结果
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 处理一帧来自 AnxietyPipeline 的评分结果，尝试识别其中的账号。
    ///
    /// 调用时机：StatusBarController 的 anxietyPipeline.onScore 回调里，
    ///           每帧评分完成后都会调用这个方法。
    ///
    /// 内部处理流程：
    ///   1. 检查 Bundle ID：不是目标平台（抖音/微信）立刻返回
    ///   2. 从 OCR 文字里提取账号名
    ///   3. 没有账号名 → 返回（不是所有帧都有账号信息）
    ///   4. 命中 sessionCache → 直接计算综合分，触发回调
    ///   5. 正在评估中 → 跳过（等上一次评估结果）
    ///   6. 新账号 → 加入 pending，调用 AccountAssessor，完成后触发回调
    ///
    /// - Parameters:
    ///   - pipeline: CaptureCoordinator 产生的 OCR 管道结果（文字 + App 信息）
    ///   - contentAnxietyScore: AnxietyPipeline 给出的本帧内容焦虑分（0.0–1.0）
    func process(pipeline: PipelineResult, contentAnxietyScore: Double) {
        // ── 步骤 1：过滤非目标 App ──────────────────────────────────────────
        // 只有用户在用抖音、微信时才有"账号"的概念
        guard let bundleID = pipeline.frontAppBundleID,
              isSupportedApp(bundleID: bundleID) else {
            return  // 非目标 App（Safari、微信读书、游戏等），跳过
        }

        // ── 步骤 2：从 OCR 文字中提取账号名 ──────────────────────────────
        // 不同平台的账号名出现在不同位置，用专门的解析逻辑处理
        guard let (accountName, platform) = extractAccount(
            from: pipeline.ocrResult.text,
            bundleID: bundleID
        ) else {
            // 没有找到账号名（用户可能在看主页 feed 而不是某个具体账号的视频）
            logger.debug("No account detected in \(pipeline.frontAppName ?? bundleID)")
            return
        }

        logger.info("账号检测命中: \(accountName) [\(platform.rawValue)]")

        // ── 步骤 3：标准化账号名（用于缓存 key）──────────────────────────
        // 去掉前后空格、全部小写，确保"某某财经"和"某某财经 "指向同一个缓存条目
        let cacheKey = normalizeKey(accountName)

        // ── 步骤 4：检查内存缓存（最快路径）──────────────────────────────
        if let cached = sessionCache[cacheKey] {
            // 缓存命中：不需要任何 API 调用，直接计算综合分
            logger.debug("sessionCache 命中: \(accountName) score=\(cached.anxietyScore)")
            emitResult(
                accountName: accountName,
                platform: platform,
                assessment: cached,
                contentAnxietyScore: contentAnxietyScore
            )
            return
        }

        // ── 步骤 5：防止对同一账号发起多个并发评估请求 ─────────────────
        // 如果已经在评估中，等那次完成就好，这次跳过
        guard !pendingAssessments.contains(cacheKey) else {
            logger.debug("评估进行中，跳过重复请求: \(accountName)")
            return
        }

        // ── 步骤 6：标记为"评估中"，发起异步评估 ─────────────────────────
        pendingAssessments.insert(cacheKey)

        // Task {} 创建一个异步任务（在后台线程调用 AccountAssessor）
        // [weak self] 避免循环引用（如果 AccountDetector 被释放，Task 里的 self 也不应继续持有）
        Task { [weak self] in
            guard let self else { return }  // self 已被释放，退出

            // 调用 AccountAssessor（内部先查 Core Data → 豆包 API → Ollama fallback）
            // await 暂停当前 Task，等评估完成后继续（评估可能需要 1-5 秒）
            let assessment = await assessor.assess(accountName: accountName, platform: platform)

            // 评估完成，切回主线程处理结果
            await MainActor.run { [weak self] in
                guard let self else { return }

                // 把结果存入内存缓存（下次同一账号秒响应）
                self.sessionCache[cacheKey] = assessment

                // 从 pending 集合里移除（评估已完成）
                self.pendingAssessments.remove(cacheKey)

                // 触发综合评分回调
                self.emitResult(
                    accountName: accountName,
                    platform: platform,
                    assessment: assessment,
                    contentAnxietyScore: contentAnxietyScore
                )
            }
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 手动清空会话缓存（供调试/设置界面调用）
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 清空本次会话的内存缓存，下次遇到同一账号会重新评估。
    ///
    /// 使用场景：
    ///   - 调试时想强制重新评估
    ///   - 用户在设置界面点击"刷新账号数据"
    ///   - 用户切换了 API Key（评估结果来源变了）
    func clearSessionCache() {
        sessionCache.removeAll()
        pendingAssessments.removeAll()
        logger.info("AccountDetector sessionCache 已清空")
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 内部：触发综合评分回调
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 用已完成的评估结果计算综合分，然后通过 onAccountDetected 通知外部。
    ///
    /// 这个函数在主线程上被调用（无论是 sessionCache 命中还是评估完成路径）。
    ///
    /// - Parameters:
    ///   - accountName: 识别到的账号名（原始，未标准化）
    ///   - platform: 平台枚举
    ///   - assessment: AccountAssessor 的评估结果
    ///   - contentAnxietyScore: 本帧内容焦虑分（来自 AnxietyPipeline）
    private func emitResult(
        accountName: String,
        platform: AccountPlatform,
        assessment: AccountAssessment,
        contentAnxietyScore: Double
    ) {
        // 综合评分公式：contentScore × contentWeight + accountScore × accountWeight
        // 默认：内容 60% + 账号 40%
        let combinedScore = contentAnxietyScore * contentWeight
                          + assessment.anxietyScore * accountWeight

        // 钳位到 [0.0, 1.0]，防止权重配置错误时超界
        let clampedCombined = min(max(combinedScore, 0.0), 1.0)

        // 打包结果
        let result = AccountDetectionResult(
            detectedAccountName: accountName,
            platform: platform,
            accountScore: assessment.anxietyScore,
            contentScore: contentAnxietyScore,
            combinedScore: clampedCombined,
            styleNotes: assessment.styleNotes,
            assessmentSource: assessment.source
        )

        // 记录日志（info 级别，供调试时在 Console.app 里看到）
        logger.info(
            "综合评分完成: account=\(accountName) " +
            "content=\(String(format: "%.2f", contentAnxietyScore)) × " +
            "\(String(format: "%.0f%%", contentWeight * 100)) + " +
            "acct=\(String(format: "%.2f", assessment.anxietyScore)) × " +
            "\(String(format: "%.0f%%", accountWeight * 100)) = " +
            "combined=\(String(format: "%.2f", clampedCombined))"
        )

        // 触发外部回调（StatusBarController 在这里处理）
        // ? 表示：如果 onAccountDetected 未设置（nil），什么都不做（不崩溃）
        onAccountDetected?(result)
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 内部：账号名提取（多平台多场景）
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 从 OCR 文字中识别平台账号名。
    ///
    /// 【各平台的账号名位置规律】
    ///
    /// 抖音（Douyin）：
    ///   - 视频播放页：账号名通常以 "@" 开头，紧跟在视频描述文字下方
    ///   - 例如：OCR 文字里有 "@某某财经" → 提取 "某某财经"
    ///   - 备选：如果 @ 不存在，查找"关注"按钮旁边的文字（通常是账号名）
    ///
    /// 微信公众号（WeChat MP）：
    ///   - 文章阅读页：公众号名在页面顶部，通常是第一行简短文字（2-20字）
    ///   - 发布时间、阅读数等会过滤掉（数字+汉字混合的行）
    ///
    /// - Parameters:
    ///   - text: OCR 识别出的全部屏幕文字
    ///   - bundleID: 当前前景 App 的 Bundle ID（用于区分平台）
    /// - Returns: 识别出的 (账号名, 平台)，没有找到时返回 nil
    private func extractAccount(from text: String,
                                bundleID: String) -> (name: String, platform: AccountPlatform)? {
        // 把文字按行分割，去掉空行和前后空格
        // compactMap({ $0.isEmpty ? nil : $0 }) 等效于 filter({ !$0.isEmpty })，但更 Swift
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 根据 Bundle ID 判断平台，调用对应的提取逻辑
        if bundleID.lowercased().contains("douyin") ||
           bundleID.lowercased().contains("com.ss.iphone") {  // 抖音国内版 Bundle ID 前缀
            return extractDouyinAccount(from: lines).map { ($0, .douyin) }
        }

        if bundleID.lowercased().contains("wechat") ||
           bundleID.lowercased().contains("tencent") {
            return extractWeChatMPAccount(from: lines).map { ($0, .wechatMP) }
        }

        return nil  // 不支持的平台
    }

    /// 从抖音 OCR 文字行中提取账号名。
    ///
    /// 策略 1（首选）：查找以 "@" 开头的行 → 截取 "@" 后面的内容
    ///   场景：用户在看视频时，视频左侧会显示 "@某某" 格式的账号名
    ///
    /// 策略 2（备选）：如果没有 "@"，查找夹在"关注"按钮附近的短字符串
    ///   场景：部分界面布局 "@" 可能被遮挡，但账号名在"关注"按钮旁
    ///
    /// - Parameter lines: 已按行分割并去空的 OCR 文字数组
    /// - Returns: 提取出的账号名（不含 "@"），没找到返回 nil
    private func extractDouyinAccount(from lines: [String]) -> String? {
        // 策略 1：查找 "@" 开头的行
        // hasPrefix("@")：检查字符串是否以 "@" 开头
        // dropFirst()：去掉第一个字符（也就是 "@"），返回剩余部分
        if let atLine = lines.first(where: { $0.hasPrefix("@") }) {
            let name = String(atLine.dropFirst())  // 去掉 "@"

            // 过滤：账号名通常 2-30 个字符，太短或太长可能是误识别
            if name.count >= 2 && name.count <= 30 {
                return name
            }
        }

        // 策略 2：查找"关注"按钮相邻的账号名
        // OCR 文字是按位置顺序排列的，"关注"按钮旁边的文字通常就是账号名
        for (index, line) in lines.enumerated() {
            if line == "关注" || line == "+ 关注" || line == "+关注" {
                // 查找"关注"按钮前面紧邻的那行（通常就是账号名）
                if index > 0 {
                    let candidate = lines[index - 1]
                    // 账号名不会包含数字+冒号（排除"点赞:10万"这类行）
                    if candidate.count >= 2 && candidate.count <= 25
                       && !candidate.contains(":")
                       && !candidate.contains("：") {
                        return candidate
                    }
                }
            }
        }

        return nil  // 没找到
    }

    /// 从微信公众号 OCR 文字行中提取公众号名称。
    ///
    /// 策略：文章阅读页的第一行通常就是公众号名称。
    ///   但需要过滤掉：
    ///   - 单个汉字（太短，可能是标点符号误识别）
    ///   - 包含大量数字的行（阅读量、点赞数等）
    ///   - 包含时间格式的行（"2024年10月"、"3天前"等）
    ///   - 超过 20 字的行（文章标题或正文，不是账号名）
    ///
    /// - Parameter lines: 已按行分割并去空的 OCR 文字数组
    /// - Returns: 提取出的公众号名称，没找到返回 nil
    private func extractWeChatMPAccount(from lines: [String]) -> String? {
        for line in lines {
            // 字符数：2-20 之间（公众号名通常比账号昵称更正式，不会太短）
            guard line.count >= 2 && line.count <= 20 else { continue }

            // 过滤包含大量数字的行（统计数据行，如 "阅读 12345"）
            let digitCount = line.filter { $0.isNumber }.count
            guard Double(digitCount) / Double(line.count) < 0.4 else { continue }

            // 过滤时间类行（包含"年"、"月"、"日"、"前"、"分钟"、"小时"）
            let timeKeywords = ["年", "月", "日", "前", "分钟", "小时", "昨天", "今天"]
            let hasTimeWord = timeKeywords.contains(where: { line.contains($0) })
            guard !hasTimeWord else { continue }

            // 过滤导航类行（标签栏或顶部导航的文字）
            let navKeywords = ["首页", "发现", "我", "搜索", "消息", "通讯录"]
            let isNavItem = navKeywords.contains(where: { line == $0 })
            guard !isNavItem else { continue }

            // 过滤包含冒号（可能是"来源："、"作者："这类标签）
            guard !line.contains(":") && !line.contains("：") else { continue }

            // 通过所有过滤条件的第一行，认为是公众号名称
            return line
        }

        return nil  // 没找到合适的候选行
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 内部：工具方法
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 判断一个 App 的 Bundle ID 是否属于我们支持的内容平台。
    ///
    /// 目前支持：抖音、微信（含不同版本的 Bundle ID 格式）。
    /// 为什么用 contains 而不是 == ？
    ///   抖音有多个版本（抖音、抖音国际版、抖音极速版），Bundle ID 前缀不同，
    ///   用 contains 可以一次性匹配所有变种。
    ///
    /// - Parameter bundleID: 待判断的 Bundle ID 字符串
    /// - Returns: true 表示是支持的平台，false 表示不支持（不需要账号检测）
    private func isSupportedApp(bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        // 抖音相关 Bundle ID 片段
        let douyinPatterns = ["douyin", "com.ss.iphone.ugc", "com.zhiliaoapp"]
        // 微信相关 Bundle ID 片段
        let wechatPatterns = ["wechat", "tencent.xin", "tencent.wechat"]

        let allPatterns = douyinPatterns + wechatPatterns
        return allPatterns.contains(where: { lower.contains($0) })
    }

    /// 标准化账号名，生成用于缓存 Key 的字符串。
    ///
    /// 处理逻辑：
    ///   - 去掉前后空白字符（OCR 可能识别出多余空格）
    ///   - 转为小写（"某某财经" 和 "某某财经" 视为同一账号）
    ///   - 去掉 "@" 前缀（如果调用方没有提前去掉）
    ///
    /// 中文字符不区分大小写，lowercased() 对中文无影响，但对含英文的账号名有效。
    ///
    /// - Parameter name: 原始账号名
    /// - Returns: 标准化后的缓存 key
    private func normalizeKey(_ name: String) -> String {
        var result = name
            .trimmingCharacters(in: .whitespaces)  // 去前后空格
            .lowercased()                           // 英文部分小写
        if result.hasPrefix("@") {                  // 去掉可能存在的 "@"
            result = String(result.dropFirst())
        }
        return result
    }
}
