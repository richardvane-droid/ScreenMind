// =============================================================================
//  InfluencerTracker.swift
//  ScreenMindCore — 跨平台共享层
// =============================================================================
//
//  【里程碑 M7-Mac：养生达人追踪器（Module 2 放松建议）】
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenMind 的放松建议有两个模块：
//
//    Module 1（SuggestionEngine，M6）：用户自己预设的建议列表（个人偏好）
//    Module 2（本文件 M7）：自动追踪养生达人的最新实验和建议，形成动态推荐
//
//  模块 2 解决的问题：
//    "我不知道该怎么放松，但 Bryan Johnson 这类人一直在实验和分享有效方法，
//     我只需要跟着最新的建议做就好了。"
//
//  【追踪的达人列表（初始版本）】
//    - Bryan Johnson (@bryan_johnson) — 科技富豪，Project Blueprint 实验，极致抗衰
//    - Andrew Huberman (@hubermanlab) — 斯坦福神经科学家，大量实验性健康协议
//    - Peter Attia (@PeterAttiaMD) — 长寿医学医生，专注代谢健康
//    - 张展 (@zhangzhan_fitness) — 中文健身科普 V（占位，可替换为活跃中文达人）
//    - 精进学堂（微博/X） — 中文养生/冥想类账号（示例）
//
//  【数据采集路径】
//    X.com（Twitter）：通过 Chrome MCP 抓取公开帖子 API 或网页
//    微博：通过 Chrome MCP 抓取公开搜索结果
//    输出：原始帖子文字 + URL + 发布时间
//
//  【AI 加工流程】
//    拿到原始帖子后，调用本地 Ollama LLM（qwen2.5:3b）：
//      Prompt："以下是养生达人的最新帖子，请提取其中的抗焦虑/放松建议，
//               用 50-100 字中文总结，输出为 JSON 格式"
//    输出：{ actionTitle, processedTip, category, confidenceScore }
//
//  【抓取频率】
//    通过 M8-Mac 中的 ScheduledTask 控制，默认每天一次（凌晨 4 点）。
//    也可以在用户主动触发时手动刷新。
//
//  【存储】
//    每条处理后的建议存入 Core Data 的 InfluencerTip 表。
//    展示时 StatusBarController/AlertPanel 读取最近 7 天内、未展示的 tip。
//
//  【关于 Chrome MCP】
//    本文件不直接包含抓取代码（Chrome MCP 是 Cowork 层的能力）。
//    Swift 代码负责：
//      1. 定义达人列表和抓取配置（InfluencerProfile）
//      2. 调用 Ollama 做 AI 加工
//      3. 把结果存入 Core Data
//
//    抓取层（Chrome MCP 调用）由 Claude Cowork 的定时任务脚本负责，
//    把抓到的原始内容通过 NSDistributedNotification 或共享文件传给本 Swift 代码。
//
//  【部署位置】
//  ScreenMindCore/Sources/ScreenMindCore/InfluencerTracker/InfluencerTracker.swift
//  在共享包里，Mac 端和 iOS 端都能用同一个处理逻辑。
//
// =============================================================================

import Foundation  // 基础类型
import CoreData    // NSManagedObjectContext，Core Data 操作
import OSLog       // 结构化日志

private let logger = Logger(subsystem: "com.screenmind", category: "InfluencerTracker")

// =============================================================================
// MARK: - 数据结构：达人配置
// =============================================================================

/// 一位养生达人的抓取配置（静态定义，不存 Core Data）。
///
/// 这个 struct 描述"去哪里找某位达人的内容"，
/// 是 InfluencerTracker 的工作清单。
///
/// 【Sendable 说明】
/// 所有属性都是值类型（String、[String]），天然 Sendable。
public struct InfluencerProfile: Sendable {

    /// 唯一标识符（用于 Core Data 的 influencerKey 字段，也用于日志）
    ///
    /// 命名规范：小写英文 + 下划线，如 "bryan_johnson"
    public let key: String

    /// 显示名称（中英文均可，在 AlertPanel 里展示给用户）
    public let displayName: String

    /// X.com（Twitter）账号 handle（不含 @）
    /// nil 表示这位达人没有活跃的 X.com 账号
    public let twitterHandle: String?

    /// 微博账号名（不含 @）
    /// nil 表示没有微博账号
    public let weiboHandle: String?

    /// 这位达人主要关注的领域（用于 AI Prompt 提示，提高提取相关性）
    ///
    /// 例如：["睡眠优化", "抗压", "饮食", "运动协议"]
    public let focusAreas: [String]

    /// 这位达人建议内容的主要语言（影响 AI 处理策略）
    public let primaryLanguage: Language

    /// 内容主要语言
    public enum Language: String, Sendable {
        case english = "en"  // 全英文（Bryan Johnson、Huberman、Peter Attia）
        case chinese = "zh"  // 中文（国内达人）
        case bilingual = "bi" // 中英双语
    }
}

// =============================================================================
// MARK: - 数据结构：原始抓取结果（由 Chrome MCP / Cowork 层提供）
// =============================================================================

/// Chrome MCP 抓取到的一条达人原始帖子。
///
/// 这个 struct 是 Cowork 层（Chrome MCP 抓取脚本）和 Swift 层之间的数据契约。
/// Cowork 把抓取结果序列化成 JSON，写入共享文件或剪贴板，
/// Swift 代码读取并反序列化为这个 struct。
///
/// Codable：支持 JSON 序列化/反序列化（进程间通信的数据格式）。
public struct RawInfluencerPost: Codable, Sendable {

    /// 帖子所属达人的 key（对应 InfluencerProfile.key）
    public let influencerKey: String

    /// 帖子原始文字内容（未经 AI 处理的原文）
    public let rawContent: String

    /// 帖子的 URL（用于用户点击查看原帖）
    public let sourceURL: String

    /// 帖子发布时间（ISO 8601 格式字符串，由 Cowork 层提供）
    public let postedAtISO: String?

    /// 帖子语言（"en" / "zh"），由 Cowork 层检测
    public let language: String?

    /// 把 postedAtISO 转换为 Date 对象（方便代码使用）
    public var postedAt: Date? {
        guard let iso = postedAtISO else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }
}

// =============================================================================
// MARK: - 数据结构：AI 加工后的建议
// =============================================================================

/// Ollama 处理原始帖子后输出的结构化建议。
///
/// AI Prompt 要求 LLM 输出这个结构的 JSON，
/// 然后 InfluencerTracker 解析它并存入 Core Data 的 InfluencerTip 表。
///
/// Codable：方便从 LLM 的 JSON 输出直接解码。
struct ProcessedInfluencerTip: Codable {

    /// 建议的行动标题（20 字以内，适合卡片标题）
    /// 例如："每天 10 分钟晨晒"、"睡前降低室温至 18°C"
    let actionTitle: String

    /// 详细的中文建议摘要（50–150 字）
    /// 包含"为什么这样做"和"具体怎么做"两部分
    let processedTip: String

    /// 归类到哪个放松建议分类（对应 SuggestionCategory.rawValue）
    /// LLM 根据帖子内容自动分类
    let category: String

    /// AI 对这条建议可靠性的评分（0.0–1.0）
    /// 基于：帖子有无引用研究数据（0.9+）、纯主观分享（0.5–0.7）、广告嫌疑（< 0.4）
    let confidenceScore: Double
}

// =============================================================================
// MARK: - 核心类：InfluencerTracker
// =============================================================================

/// M7 养生达人追踪器：抓取达人最新内容 → AI 加工 → 存入 InfluencerTip 数据库。
///
/// 【@unchecked Sendable 说明】
/// 持有 PersistenceController，其内部 NSPersistentContainer 非标准 Sendable。
/// 所有 Core Data 操作均通过 ctx.perform {} 保证线程安全。
public final class InfluencerTracker: @unchecked Sendable {

    // MARK: - 预设达人列表 ────────────────────────────────────────────────────

    /// 默认追踪的养生达人列表（内置于 App，用户可以在设置里调整）。
    ///
    /// 【为什么用静态属性而不是存 Core Data？】
    /// 达人列表是 App 功能的一部分，随版本迭代（不是用户数据）。
    /// 静态定义便于版本管理，Core Data 只存处理结果（InfluencerTip）。
    public static let defaultInfluencers: [InfluencerProfile] = [

        InfluencerProfile(
            key: "bryan_johnson",
            displayName: "Bryan Johnson",
            twitterHandle: "bryan_johnson",
            weiboHandle: nil,
            focusAreas: ["生物黑客", "抗衰", "睡眠优化", "饮食协议", "运动"],
            primaryLanguage: .english
        ),

        InfluencerProfile(
            key: "huberman",
            displayName: "Andrew Huberman",
            twitterHandle: "hubermanlab",
            weiboHandle: nil,
            focusAreas: ["神经科学", "睡眠", "压力管理", "冥想", "日光暴露"],
            primaryLanguage: .english
        ),

        InfluencerProfile(
            key: "peter_attia",
            displayName: "Peter Attia",
            twitterHandle: "PeterAttiaMD",
            weiboHandle: nil,
            focusAreas: ["长寿医学", "代谢健康", "有氧运动", "睡眠质量", "心理健康"],
            primaryLanguage: .english
        ),

        InfluencerProfile(
            key: "chinese_wellness",
            displayName: "中文养生精选",
            twitterHandle: nil,
            weiboHandle: "养生研究所",  // 示例，可替换为实际活跃账号
            focusAreas: ["冥想", "中医调理", "正念", "压力释放", "睡眠"],
            primaryLanguage: .chinese
        )
    ]

    // MARK: - 组件 ────────────────────────────────────────────────────────────

    /// Core Data 控制器（用于读写 InfluencerTip 表）
    private let persistence: PersistenceController

    /// Ollama 本地 LLM 端点（与 AccountAssessor 共用同一 Ollama 实例）
    ///
    /// qwen2.5:3b：支持中英文，对提取和总结任务效果好
    private let ollamaEndpoint = URL(string: "http://127.0.0.1:11434/api/generate")!
    private let ollamaModel    = "qwen2.5:3b"

    // MARK: - 初始化 ──────────────────────────────────────────────────────────

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 公开方法 1：处理一批原始帖子（Cowork 层调用）
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 接收 Cowork/Chrome MCP 抓取的原始帖子，经 AI 加工后存入 Core Data。
    ///
    /// 这是 Swift 层的"数据入口"：
    ///   Cowork 抓取脚本 → JSON 文件 / 剪贴板 → Swift 解析 → 本方法处理
    ///
    /// 处理流程：
    ///   1. 对每条原始帖子调用 processPost() 做 AI 处理
    ///   2. 过滤掉低置信度的建议（< 0.5）
    ///   3. 写入 Core Data InfluencerTip 表
    ///
    /// - Parameter posts: Cowork 层提供的原始帖子数组
    public func ingest(posts: [RawInfluencerPost]) async {
        logger.info("开始处理 \(posts.count) 条原始帖子")

        var successCount = 0
        var failCount = 0

        for post in posts {
            do {
                // 查找对应达人配置（用于提供上下文给 AI）
                let profile = Self.defaultInfluencers.first { $0.key == post.influencerKey }

                // 调用 AI 加工（Ollama LLM）
                if let processed = await processPost(post, profile: profile) {
                    // 低置信度建议过滤（广告嫌疑 / AI 没有提取出有效建议）
                    guard processed.confidenceScore >= 0.5 else {
                        logger.debug("置信度 \(processed.confidenceScore) 过低，跳过: \(post.sourceURL)")
                        continue
                    }

                    // 写入 Core Data
                    await saveTip(post: post, processed: processed)
                    successCount += 1
                } else {
                    failCount += 1
                }
            }
        }

        logger.info("帖子处理完成：成功 \(successCount) 条，失败 \(failCount) 条")
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 公开方法 2：读取最新未展示的建议（AlertPanel 调用）
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 返回最近 7 天内、尚未展示给用户的达人建议（最多 N 条）。
    ///
    /// AlertPanel（M8）展示 Module 2 时调用这个方法。
    /// 展示后调用 markAsShown() 避免重复展示。
    ///
    /// - Parameter limit: 最多返回几条，默认 3 条（避免 AlertPanel 太长）
    /// - Returns: InfluencerTip Core Data 对象数组（按置信度降序）
    public func freshTips(limit: Int = 3) async -> [InfluencerTip] {
        let ctx = persistence.container.viewContext

        // 查询条件：
        //   1. hasBeenShown == NO（未展示）
        //   2. fetchedAt >= 7 天前（近期数据）
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 86400)
        let request = InfluencerTip.fetchRequest()
        request.predicate = NSPredicate(
            format: "hasBeenShown == NO AND fetchedAt >= %@",
            sevenDaysAgo as NSDate
        )
        // 按置信度降序 + 发布时间降序
        request.sortDescriptors = [
            NSSortDescriptor(key: "confidenceScore", ascending: false),
            NSSortDescriptor(key: "postedAt", ascending: false)
        ]
        request.fetchLimit = limit

        return (try? ctx.fetch(request)) ?? []
    }

    /// 标记一批建议为"已展示"，避免重复推送。
    ///
    /// 在 AlertPanel 展示完毕后调用（用户看到了就标记）。
    ///
    /// - Parameter tips: 要标记的 InfluencerTip 对象数组
    public func markAsShown(_ tips: [InfluencerTip]) async {
        guard !tips.isEmpty else { return }

        let ctx = persistence.newBackgroundContext()
        // 提前捕获 objectID 数组（Core Data objectID 是线程安全的）
        let ids = tips.map { $0.objectID }

        ctx.perform {
            for objectID in ids {
                // 在后台 context 里找到对应对象
                if let tip = try? ctx.existingObject(with: objectID) as? InfluencerTip {
                    tip.hasBeenShown = true
                }
            }
            try? ctx.save()
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 公开方法 3：从共享文件读取 Cowork 抓取结果
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 从 ScreenMind 数据目录读取 Cowork 定时任务写入的原始帖子 JSON 文件。
    ///
    /// 【文件通信协议】
    /// Cowork 的 Chrome MCP 抓取脚本把结果写成 JSON 文件：
    ///   路径：~/Library/Application Support/ScreenMind/influencer_posts.json
    ///   格式：[RawInfluencerPost] 数组的 JSON
    ///   写入时机：定时任务完成抓取后立即写入
    ///
    /// Swift App 启动时（或接到 NSDistributedNotification 时）调用这个方法读取。
    ///
    /// 读取成功后删除文件（避免下次重复处理同一批数据）。
    ///
    /// - Returns: 解析出的原始帖子数组，读取失败返回空数组
    public func loadPostsFromSharedFile() -> [RawInfluencerPost] {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return [] }

        let fileURL = appSupport
            .appendingPathComponent("ScreenMind")
            .appendingPathComponent("influencer_posts.json")

        guard let data = try? Data(contentsOf: fileURL) else {
            // 文件不存在（正常情况，如果还没有抓取过）
            return []
        }

        let posts = (try? JSONDecoder().decode([RawInfluencerPost].self, from: data)) ?? []
        logger.info("从共享文件读取到 \(posts.count) 条原始帖子")

        // 读取成功后删除文件（防止重复处理）
        try? FileManager.default.removeItem(at: fileURL)

        return posts
    }

    /// 获取供 Cowork 抓取脚本使用的达人配置列表 JSON。
    ///
    /// Cowork 定时任务在开始前读取这个文件，知道要去抓哪些达人的内容。
    ///
    /// 写入路径：~/Library/Application Support/ScreenMind/influencer_config.json
    public func exportConfigForCowork() {
        // 构造 Cowork 需要的配置格式
        let config = Self.defaultInfluencers.map { profile -> [String: Any] in
            var dict: [String: Any] = [
                "key": profile.key,
                "displayName": profile.displayName,
                "focusAreas": profile.focusAreas,
                "language": profile.primaryLanguage.rawValue
            ]
            if let twitter = profile.twitterHandle {
                dict["twitterHandle"] = twitter
            }
            if let weibo = profile.weiboHandle {
                dict["weiboHandle"] = weibo
            }
            return dict
        }

        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        let jsonData = try? JSONSerialization.data(withJSONObject: config,
                                                   options: .prettyPrinted) else { return }

        let dirURL  = appSupport.appendingPathComponent("ScreenMind")
        let fileURL = dirURL.appendingPathComponent("influencer_config.json")

        // 创建目录（如果不存在）
        try? FileManager.default.createDirectory(at: dirURL,
                                                  withIntermediateDirectories: true)
        try? jsonData.write(to: fileURL)
        logger.info("达人配置已写入 Cowork 共享文件")
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 内部：AI 加工（Ollama LLM 提取建议）
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 用本地 Ollama LLM 把原始帖子加工成结构化建议。
    ///
    /// 【Prompt 设计原则】
    ///   1. 明确说明输出格式（JSON），避免 LLM 加入多余文字
    ///   2. 限制字数（避免 LLM 输出太长）
    ///   3. 给出分类选项（避免 LLM 自创分类）
    ///   4. 要求置信度评分（让 LLM 自我评估可靠性）
    ///
    /// - Parameters:
    ///   - post: 原始帖子数据
    ///   - profile: 达人配置（提供上下文，帮助 LLM 理解帖子背景）
    /// - Returns: 处理后的建议，无法提取有效建议时返回 nil
    private func processPost(_ post: RawInfluencerPost,
                              profile: InfluencerProfile?) async -> ProcessedInfluencerTip? {
        // 构造 Prompt
        let focusContext = profile.map { p in
            "该达人主要关注：\(p.focusAreas.joined(separator: "、"))"
        } ?? ""

        // 可用分类说明（和 SuggestionCategory 对应）
        let categoryOptions = """
        place（去某个地方），fitness（健身运动），course（学习课程），
        food（饮食调整），entertainment（娱乐放松），home_service（到家服务）
        """

        let prompt = """
        你是一个健康建议提取器。以下是一位养生达人的帖子原文，请提取其中最有价值的抗焦虑/放松建议。
        \(focusContext)

        【帖子原文】
        \(post.rawContent.prefix(800))

        【要求】
        1. 用中文输出（无论原文是英文还是中文）
        2. actionTitle：不超过 20 字的行动标题，适合作为卡片标题
        3. processedTip：50–120 字，包含"为什么有效"和"怎么操作"
        4. category：从以下选一个：\(categoryOptions)
        5. confidenceScore：0.0–1.0，评估建议的科学可靠性（有研究引用=高分，广告嫌疑=低分）
        6. 如果帖子没有有效健康建议，输出 confidenceScore=0.0

        【输出格式（仅 JSON，不要其他文字）】
        {"actionTitle":"...","processedTip":"...","category":"...","confidenceScore":0.8}
        """

        // 构造 Ollama API 请求体
        let requestBody: [String: Any] = [
            "model": ollamaModel,
            "prompt": prompt,
            "stream": false
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        // 发送 HTTP 请求到本地 Ollama
        var request = URLRequest(url: ollamaEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 30  // Ollama 小模型应该在 30 秒内完成

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            logger.warning("Ollama 请求失败（帖子 URL: \(post.sourceURL)）")
            return nil
        }

        // 解析 Ollama 响应（外层是 {response: "..."，内层是 LLM 的 JSON 文字}）
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let llmText = outer["response"] as? String else {
            return nil
        }

        // 从 LLM 文字中提取 JSON（LLM 可能在 JSON 前后加上说明文字）
        return extractProcessedTip(from: llmText)
    }

    /// 用正则表达式从 LLM 输出文字中提取 JSON，并解码为 ProcessedInfluencerTip。
    ///
    /// 与 AccountAssessor 的 parseAssessmentResponse 类似的做法：
    /// LLM 有时在 JSON 前后加上"好的，以下是..."这类说明，需要用正则找到 JSON 边界。
    ///
    /// - Parameter text: LLM 的原始输出文字
    /// - Returns: 解码后的 ProcessedInfluencerTip，失败返回 nil
    private func extractProcessedTip(from text: String) -> ProcessedInfluencerTip? {
        // 正则：匹配花括号括起来的 JSON 对象（支持嵌套内容）
        // \{[\s\S]*?\}：非贪婪匹配最小的花括号对
        // 注意：这里用非贪婪模式，适合 LLM 输出通常只有一个 JSON 对象的情况
        guard let range = text.range(of: #"\{[\s\S]*?\}"#,
                                     options: .regularExpression) else {
            logger.debug("无法从 LLM 输出中找到 JSON: \(text.prefix(100))")
            return nil
        }

        let jsonString = String(text[range])
        guard let data = jsonString.data(using: .utf8) else { return nil }

        return try? JSONDecoder().decode(ProcessedInfluencerTip.self, from: data)
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 内部：写入 Core Data
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 把处理好的建议写入 Core Data 的 InfluencerTip 表。
    ///
    /// 去重逻辑：同一 sourceURL 的帖子只存一次（通过 predicate 检查是否已存在）。
    /// 这样即使 Cowork 多次抓取同一条帖子，数据库里也不会重复。
    ///
    /// - Parameters:
    ///   - post: 原始帖子（提供 URL、达人信息、发布时间）
    ///   - processed: AI 加工后的建议（提供 actionTitle、processedTip 等）
    private func saveTip(post: RawInfluencerPost, processed: ProcessedInfluencerTip) async {
        let ctx = persistence.newBackgroundContext()

        // 提前捕获所有需要保存的值（线程安全 —— 值类型可跨线程传递）
        let influencerKey       = post.influencerKey
        let influencerName      = Self.defaultInfluencers.first {
                                      $0.key == post.influencerKey
                                  }?.displayName ?? post.influencerKey
        let sourceURL           = post.sourceURL
        let originalContent     = String(post.rawContent.prefix(1000))  // 截断长文本
        let actionTitle         = processed.actionTitle
        let processedTip        = processed.processedTip
        let category            = processed.category
        let confidenceScore     = processed.confidenceScore
        let postedAt            = post.postedAt
        let fetchedAt           = Date()

        ctx.perform {
            // 去重检查：这个 sourceURL 是否已经存在
            let request = InfluencerTip.fetchRequest()
            request.predicate = NSPredicate(format: "sourceURL == %@", sourceURL)
            let existing = try? ctx.fetch(request)
            guard existing?.isEmpty != false else {
                // 已存在，跳过（不重复插入）
                return
            }

            // 创建新记录
            let tip                 = InfluencerTip(context: ctx)
            tip.id                  = UUID()
            tip.influencerKey       = influencerKey
            tip.influencerName      = influencerName
            tip.sourceURL           = sourceURL
            tip.originalContent     = originalContent
            tip.actionTitle         = actionTitle
            tip.processedTip        = processedTip
            tip.category            = category
            tip.confidenceScore     = confidenceScore
            tip.postedAt            = postedAt
            tip.fetchedAt           = fetchedAt
            tip.hasBeenShown        = false  // 新建议默认未展示

            do {
                try ctx.save()
                logger.info("✅ 存入 InfluencerTip: \(actionTitle) [\(influencerKey)]")
            } catch {
                logger.error("Core Data 保存失败: \(error.localizedDescription)")
            }
        }
    }
}
