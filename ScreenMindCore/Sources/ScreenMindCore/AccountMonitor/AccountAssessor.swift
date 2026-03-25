// =============================================================================
//  AccountAssessor.swift
//  ScreenMindCore — 跨平台共享层
// =============================================================================
//
//  【里程碑 M5-Mac：账号评估引擎】
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenMind 检测到用户在看某个抖音账号或微信公众号时，
//  需要判断"这个账号的内容风格，整体上倾向于让人焦虑吗？"
//
//  比如：
//    - 财经大V 发的都是"末日预警""崩盘警告" → 高焦虑账号
//    - 旅游博主 发的都是风景和美食 → 低焦虑账号
//
//  这样可以区分："是这条内容本身让你焦虑" vs "是这个账号一贯风格让你焦虑"
//  前者是内容评分（AnxietyScorer），后者是账号评分（AccountAssessor）。
//
//  【双引擎架构】
//  ┌────────────────────────────────────────────────────────────────────┐
//  │  主引擎：火山方舟 API（豆包 doubao-pro-32k）                         │
//  │    ∙ 对头部/知名创作者评估准确，有大量训练数据                       │
//  │    ∙ 需要 API Key（存在 Keychain，不硬编码）                        │
//  │    ∙ 需要网络，响应约 1–2 秒                                        │
//  │    ∙ 豆包"知名度判断"：known=true → 高置信；known=false → 触发 fallback│
//  │                                                                    │
//  │  副引擎：Ollama 本地 LLM（qwen2.5:3b）                              │
//  │    ∙ 处理豆包不认识的陌生/新兴创作者                                │
//  │    ∙ 离线运行，隐私安全                                             │
//  │    ∙ 速度约 2–5 秒（M1 Mac）                                        │
//  └────────────────────────────────────────────────────────────────────┘
//
//  【缓存策略】
//  评估结果存入 Core Data（VideoAccountProfile 实体）：
//    - 豆包评估结果：缓存 30 天（豆包知道的头部账号风格变化慢）
//    - Ollama 评估结果：缓存 7 天（小账号内容变化快，频繁刷新）
//
//  【部署位置】
//  ScreenMindCore/Sources/ScreenMindCore/AccountMonitor/AccountAssessor.swift
//  共享包，Mac 端和 iOS 端都能用同一套评估引擎。
//
// =============================================================================

import Foundation  // 提供 URL、URLSession、JSONSerialization、Date 等基础类型
import Security   // 提供 Keychain API（SecItemCopyMatching 等），用于安全存取 API Key

// =============================================================================
// MARK: - AccountAssessor：账号风格评估引擎
// =============================================================================

/// 评估一个抖音/微信公众号账号的内容是否倾向于引发焦虑。
///
/// 【职责】
///   1. 检查 Core Data 缓存（命中则直接返回，不重复调 API）
///   2. 优先用豆包 API 评估（需要 API Key 且联网）
///   3. 豆包 API 失败时 fallback 到本地 Ollama
///   4. 把结果缓存到 Core Data
///
/// 【@unchecked Sendable 说明】
///   URLSession 等 Foundation 类不是标准 Sendable，
///   但 AccountAssessor 的所有状态（doubaoAPIKey 是计算属性，无存储状态）是只读的，
///   多线程访问是安全的，用 @unchecked 告知编译器。
public final class AccountAssessor: @unchecked Sendable {

    // MARK: - 豆包（火山方舟）API 配置 ──────────────────────────────────────

    /// 火山方舟 API 端点（北京区域）。
    ///
    /// 【什么是火山方舟？】
    /// 字节跳动的 AI 开放平台，提供豆包大语言模型的 API 调用服务。
    /// API 格式与 OpenAI 兼容，所以请求结构和 OpenAI 完全一样。
    private let doubaoEndpoint = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!

    /// 使用的豆包模型名称。
    ///
    /// doubao-pro-32k：豆包的专业版，支持 32K token 上下文（对我们的短 Prompt 来说绰绰有余）。
    /// 为什么不用 doubao-lite？Pro 版对中国内容（自媒体账号）的理解更准确，
    /// 考虑到账号评估频率很低（每个账号只评估一次），Pro 的成本完全可以接受。
    private let doubaoModel = "doubao-pro-32k"

    /// 豆包 API Key（从 Keychain 实时读取，绝不硬编码）。
    ///
    /// 【为什么用 computed property 而不是在 init 里读一次？】
    /// Keychain 里的 Key 可能被更新（用户在设置页重新填入），
    /// 每次调用时实时读取，保证总是用最新的 Key。
    ///
    /// 【为什么存 Keychain 而不是 UserDefaults？】
    /// UserDefaults 是明文存储，Keychain 是加密存储。
    /// API Key 是敏感凭据，必须用 Keychain。
    private var doubaoAPIKey: String? {
        KeychainHelper.read(key: "doubao_api_key")
    }

    // MARK: - Ollama 本地 LLM 配置 ────────────────────────────────────────

    /// Ollama 本地服务器地址（默认运行在 localhost:11434）。
    ///
    /// Ollama 是一个本地大语言模型运行环境，类似于本机版的 OpenAI API。
    /// 用户需要先安装 Ollama 并下载 qwen2.5:3b 模型，详见 README。
    private let ollamaEndpoint = URL(string: "http://127.0.0.1:11434/api/generate")!

    /// Ollama 使用的模型。
    ///
    /// qwen2.5:3b：阿里通义千问 2.5，3B 参数版本。
    /// 选这个的原因：
    ///   - 对中文内容理解能力强（比英文模型准确）
    ///   - 3B 参数量在 M1 Mac 上可以快速运行（~2-3秒）
    ///   - 内存占用约 2GB，不影响正常使用
    private let ollamaModel = "qwen2.5:3b"

    // MARK: - 缓存配置 ──────────────────────────────────────────────────────

    /// 豆包评估结果的缓存有效期（秒）。30 天。
    ///
    /// 30 × 24 × 3600 = 2_592_000 秒
    /// 为什么 30 天？头部创作者的内容风格很稳定，一个月内不会大变。
    private let doubaoСacheDays: TimeInterval = 30 * 86400

    /// Ollama 评估结果的缓存有效期（秒）。7 天。
    ///
    /// 为什么只有 7 天？
    /// Ollama 评估的是豆包"不认识"的陌生账号，这类小账号风格多变，
    /// 更短的缓存周期保证评估结果的新鲜度。
    private let ollamaCacheDays: TimeInterval = 7 * 86400

    // MARK: - 依赖项 ────────────────────────────────────────────────────────

    /// Core Data 存储控制器（用于缓存账号评估结果）。
    private let persistence: PersistenceController

    // MARK: - 初始化 ────────────────────────────────────────────────────────

    /// 初始化账号评估器。
    ///
    /// 参数有默认值（= .shared），所以大部分情况下直接 AccountAssessor() 即可。
    /// 单元测试时可以传入 PersistenceController(inMemory: true) 来隔离数据库。
    ///
    /// - Parameter persistence: Core Data 控制器，默认使用全局共享实例
    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    // MARK: - 公开方法：评估账号 ──────────────────────────────────────────

    /// 评估（或返回缓存的）一个账号的焦虑倾向分数。
    ///
    /// 这是整个 AccountAssessor 的唯一公开入口。
    ///
    /// 调用时机：AccountDetector 检测到屏幕上出现了新的账号名时调用。
    ///
    /// 内部执行顺序：
    ///   1. 检查 Core Data 缓存 → 命中且未过期 → 直接返回
    ///   2. 有豆包 API Key → 尝试豆包 → 成功 → 缓存 + 返回
    ///   3. 豆包失败（无 Key / 超时 / 网络错误）→ 尝试 Ollama
    ///   4. Ollama 也失败 → 返回默认值（中性分 0.5），App 不崩溃
    ///
    /// - Parameters:
    ///   - accountName: 账号名称，如 "@某某财经"、"人民日报"
    ///   - platform: 账号平台（.douyin 或 .wechatMP）
    /// - Returns: 账号评估结果（永不 throw，失败时返回默认值）
    public func assess(accountName: String,
                       platform: AccountPlatform) async -> AccountAssessment {

        // ── 步骤 1：检查缓存 ──────────────────────────────────────────────
        if let cached = cachedAssessment(accountName: accountName, platform: platform) {
            return cached  // 缓存命中，直接返回（不消耗 API 配额）
        }

        // ── 步骤 2：尝试豆包 API ──────────────────────────────────────────
        if let apiKey = doubaoAPIKey, !apiKey.isEmpty {
            do {
                let result = try await doubaoAssess(accountName: accountName,
                                                    platform: platform,
                                                    apiKey: apiKey)
                cacheAssessment(result)   // 成功：写入缓存
                return result
            } catch {
                // 豆包失败（网络不通、API Key 无效、响应超时等），继续尝试 Ollama
                // 这里刻意不 throw，保证整个方法不会让 App 崩溃
            }
        }

        // ── 步骤 3：Ollama 本地 fallback ──────────────────────────────────
        do {
            let fallback = try await ollamaAssess(accountName: accountName, platform: platform)
            cacheAssessment(fallback)   // 成功：写入缓存
            return fallback
        } catch {
            // Ollama 也失败（未安装 / 未启动 / 模型未下载）→ 返回中性默认值
        }

        // ── 步骤 4：兜底默认值（不崩溃）──────────────────────────────────
        // 返回 0.5 分（中性），不影响整体焦虑评估（内容评分仍然正常工作）
        let fallbackResult = AccountAssessment(
            accountName: accountName,
            platform: platform,
            anxietyScore: 0.5,
            styleNotes: "评估暂不可用（离线状态或 API Key 未配置）",
            source: .ollama
        )
        // 注意：评估失败的结果不缓存（这样下次有网时会重新尝试）
        return fallbackResult
    }

    // MARK: - 私有：豆包 API 评估引擎 ───────────────────────────────────────

    /// 调用火山方舟豆包 API 评估账号焦虑倾向。
    ///
    /// API 格式与 OpenAI Chat Completions 兼容：
    ///   POST https://ark.cn-beijing.volces.com/api/v3/chat/completions
    ///   Authorization: Bearer <api_key>
    ///   { "model": "doubao-pro-32k", "messages": [...] }
    ///
    /// 豆包的额外能力：对中国创作者有专项知识（认识头部博主）。
    /// 如果豆包认识这个账号（known=true），评估置信度更高。
    ///
    /// - Parameters:
    ///   - accountName: 账号名
    ///   - platform: 平台
    ///   - apiKey: 火山方舟 API Key
    /// - Throws: AssessorError.invalidResponse（响应格式不对）或 URLError（网络问题）
    private func doubaoAssess(accountName: String,
                              platform: AccountPlatform,
                              apiKey: String) async throws -> AccountAssessment {
        let prompt = buildPrompt(accountName: accountName,
                                 platform: platform,
                                 askKnownStatus: true) // 豆包版：额外询问"是否认识这个账号"

        // 构建 HTTP 请求体（JSON 格式，兼容 OpenAI 协议）
        let body: [String: Any] = [
            "model": doubaoModel,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.1,   // 低温度 → 输出更确定性（减少随机性），适合评分任务
            "max_tokens": 300     // 最多返回 300 个 token（足够一个 JSON + 说明）
        ]

        var request = URLRequest(url: doubaoEndpoint)
        request.httpMethod = "POST"
        // Authorization 头：Bearer 令牌格式（OpenAI 兼容协议的标准认证方式）
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20  // 20 秒超时（豆包响应通常 1-2 秒）

        // URLSession.shared.data(for:) 是 async/await 版本的网络请求
        let (data, _) = try await URLSession.shared.data(for: request)

        // 解析 OpenAI 兼容格式的响应
        // 响应结构：{ "choices": [{ "message": { "content": "..." } }] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AssessorError.invalidResponse
        }

        return parseAssessmentResponse(content,
                                       accountName: accountName,
                                       platform: platform,
                                       source: .doubao)
    }

    // MARK: - 私有：Ollama fallback 评估引擎 ────────────────────────────────

    /// 调用本地 Ollama LLM 评估账号焦虑倾向（豆包失败时的备用方案）。
    ///
    /// Ollama API 格式：
    ///   POST http://127.0.0.1:11434/api/generate
    ///   { "model": "qwen2.5:3b", "prompt": "...", "stream": false }
    ///
    /// 注意：Ollama 的 API 和 OpenAI 不兼容（用 "prompt" 而不是 "messages"），
    /// 但 ScreenMind 对两者都做了适配。
    ///
    /// - Parameters:
    ///   - accountName: 账号名
    ///   - platform: 平台
    /// - Throws: AssessorError.invalidResponse 或 URLError
    private func ollamaAssess(accountName: String,
                              platform: AccountPlatform) async throws -> AccountAssessment {
        let prompt = buildPrompt(accountName: accountName,
                                 platform: platform,
                                 askKnownStatus: false) // Ollama 版：不问已知状态

        let body: [String: Any] = [
            "model": ollamaModel,
            "prompt": prompt,
            "stream": false,  // false = 等待完整响应后返回（而不是流式逐字返回）
            "options": [
                "temperature": 0.1, // 同豆包：低温度保证输出稳定
                "num_predict": 300  // 最多预测 300 个 token
            ]
        ]

        var request = URLRequest(url: ollamaEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30  // Ollama 比豆包慢，给 30 秒

        let (data, _) = try await URLSession.shared.data(for: request)

        // Ollama 响应格式：{ "response": "完整的回复文字" }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["response"] as? String else {
            throw AssessorError.invalidResponse
        }

        return parseAssessmentResponse(content,
                                       accountName: accountName,
                                       platform: platform,
                                       source: .ollama)
    }

    // MARK: - 私有：Prompt 构建 ────────────────────────────────────────────

    /// 构建账号评估的 Prompt。
    ///
    /// 【Prompt 工程说明】
    /// 1. 明确角色：让 LLM 扮演"自媒体情绪影响分析专家"，提高专业度
    /// 2. 评估维度：列出三个维度，保证评估一致性（不受随机性影响）
    /// 3. 输出格式：严格要求 JSON，方便程序解析
    /// 4. 豆包专属：askKnownStatus=true 时，额外询问 known 字段（利用豆包的创作者数据库）
    ///
    /// - Parameters:
    ///   - accountName: 账号名
    ///   - platform: 平台
    ///   - askKnownStatus: 是否在 JSON 里返回 known 字段（豆包用 true，Ollama 用 false）
    /// - Returns: 完整 Prompt 字符串
    private func buildPrompt(accountName: String,
                             platform: AccountPlatform,
                             askKnownStatus: Bool) -> String {
        let platformName = platform == .douyin ? "抖音" : "微信公众号"

        // 根据是否需要 known 字段，选择不同的 JSON 格式说明
        let jsonFormat = askKnownStatus
            ? """
              {"known": true/false, "score": 0.7, "notes": "简要风格描述（不超过50字）"}
              其中 known 表示你是否了解这个账号（true=已知头部账号，false=陌生账号），
              """
            : """
              {"score": 0.7, "notes": "简要风格描述（不超过50字）"}
              其中
              """

        return """
        你是一个分析自媒体账号对读者/观众情绪影响的专家。
        请评估\(platformName)账号「\(accountName)」的内容风格对读者产生的焦虑感。

        评估维度（三个维度综合打分）：
        1. 内容是否制造紧迫感或恐慌（如"末日警告""必看！不然你会后悔"）
        2. 是否传递悲观/负面世界观（如持续渲染社会问题、经济危机、人际不信任）
        3. 是否使用情绪操控手法（标题党、极端化叙事、对立化框架、"只有我知道真相"）

        请严格用以下 JSON 格式回复，不要输出任何 JSON 以外的内容：
        \(jsonFormat)
        score 为 0.0（完全不焦虑）到 1.0（极度焦虑），notes 为风格描述（中文，不超过50字）。
        """
    }

    // MARK: - 私有：响应解析 ──────────────────────────────────────────────

    /// 从 LLM 返回的文字里提取 JSON，解析出评分和风格描述。
    ///
    /// 【为什么用正则提取 JSON 而不是直接 JSONDecode？】
    /// LLM 有时会在 JSON 前后加上解释文字，比如：
    ///   "好的，以下是评估结果：\n{\"score\": 0.7, ...}\n希望对你有帮助。"
    /// 直接 JSONDecode 会失败，用正则表达式 \{[^}]+\} 先找到 JSON 块再解析。
    ///
    /// - Parameters:
    ///   - text: LLM 返回的完整文字
    ///   - accountName: 账号名（解析失败时用于构造默认返回值）
    ///   - platform: 平台
    ///   - source: 评估来源（豆包或 Ollama）
    /// - Returns: 解析出的 AccountAssessment（解析失败时返回中性默认值）
    private func parseAssessmentResponse(_ text: String,
                                         accountName: String,
                                         platform: AccountPlatform,
                                         source: AssessmentSource) -> AccountAssessment {
        // 正则表达式 \{[^}]+\}：匹配第一个出现的 { ... }（花括号内不含另一个花括号）
        // options: .regularExpression 启用正则模式
        let pattern = #"\{[^}]+\}"#

        guard let range = text.range(of: pattern, options: .regularExpression),
              let data = String(text[range]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let score = json["score"] as? Double else {
            // 解析失败：返回中性分，避免影响用户体验
            return AccountAssessment(
                accountName: accountName,
                platform: platform,
                anxietyScore: 0.5,
                styleNotes: "解析失败，返回中性默认值",
                source: source
            )
        }

        let notes = json["notes"] as? String ?? ""
        // min(max(score, 0), 1)：把分数钳位到 [0.0, 1.0]，防止 LLM 输出越界值
        return AccountAssessment(
            accountName: accountName,
            platform: platform,
            anxietyScore: min(max(score, 0.0), 1.0),
            styleNotes: notes,
            source: source
        )
    }

    // MARK: - 私有：Core Data 缓存读取 ───────────────────────────────────────

    /// 从 Core Data 读取缓存的账号评估结果。
    ///
    /// 缓存有效期规则：
    ///   - 豆包评估的结果：30 天内有效
    ///   - Ollama 评估的结果：7 天内有效（小账号风格多变）
    ///
    /// - Parameters:
    ///   - accountName: 账号名
    ///   - platform: 平台
    /// - Returns: 有效的缓存结果，不存在或已过期则返回 nil
    private func cachedAssessment(accountName: String,
                                  platform: AccountPlatform) -> AccountAssessment? {
        let ctx = persistence.container.viewContext
        let request = VideoAccountProfile.fetchRequest()

        // 精确匹配：同一个账号名 + 同一个平台（抖音"张三"≠ 公众号"张三"）
        request.predicate = NSPredicate(
            format: "accountName == %@ AND platform == %@",
            accountName, platform.rawValue
        )
        request.fetchLimit = 1

        guard let entity = (try? ctx.fetch(request))?.first,
              let lastAssessed = entity.lastAssessedAt else { return nil }

        // 根据评估来源决定缓存有效期
        let cacheExpiry = entity.assessmentSource == "doubao" ? doubaoСacheDays : ollamaCacheDays
        let isExpired = Date().timeIntervalSince(lastAssessed) >= cacheExpiry

        guard !isExpired else { return nil } // 已过期，返回 nil（触发重新评估）

        return AccountAssessment(
            accountName: accountName,
            platform: platform,
            anxietyScore: entity.anxietyScore,
            styleNotes: entity.styleNotes ?? "",
            source: entity.assessmentSource == "doubao" ? .doubao : .ollama
        )
    }

    // MARK: - 私有：Core Data 缓存写入 ───────────────────────────────────────

    /// 把评估结果写入 Core Data 缓存（后台线程执行，不阻塞 UI）。
    ///
    /// 写入策略：
    ///   - 如果已有这个账号的记录 → 更新（不重复创建）
    ///   - 如果没有 → 创建新记录
    ///
    /// - Parameter assessment: 要缓存的评估结果
    private func cacheAssessment(_ assessment: AccountAssessment) {
        let ctx = persistence.newBackgroundContext()

        // 提前解包所有需要的值（在 ctx.perform 闭包外获取，避免 actor 隔离问题）
        let name     = assessment.accountName
        let platform = assessment.platform.rawValue
        let score    = assessment.anxietyScore
        let notes    = assessment.styleNotes
        let source   = assessment.source.rawValue

        ctx.perform {
            let request = VideoAccountProfile.fetchRequest()
            request.predicate = NSPredicate(format: "accountName == %@ AND platform == %@",
                                            name, platform)
            request.fetchLimit = 1

            // 有则更新，无则创建（upsert 模式）
            let entity: VideoAccountProfile
            if let existing = (try? ctx.fetch(request))?.first {
                entity = existing          // 更新已有记录
            } else {
                entity = VideoAccountProfile(context: ctx)  // 首次写入
                entity.id = UUID()
            }

            entity.accountName       = name
            entity.platform          = platform
            entity.anxietyScore      = score
            entity.styleNotes        = notes
            entity.assessmentSource  = source
            entity.lastAssessedAt    = Date()    // 记录本次评估时间（缓存过期检查依赖这个）

            try? ctx.save()
        }
    }

    // MARK: - 错误类型 ──────────────────────────────────────────────────────

    /// AccountAssessor 的错误类型。
    ///
    /// 目前只有一种错误：API 返回的内容格式不对（无法解析）。
    /// 网络错误会透传 URLError，调用方可以统一处理。
    public enum AssessorError: Error {
        case invalidResponse  // API 返回了不符合预期格式的内容
    }
}

// =============================================================================
// MARK: - KeychainHelper：安全存取 API Key
// =============================================================================

/// Keychain（钥匙串）读写工具。
///
/// 【什么是 Keychain？】
/// macOS/iOS 系统提供的加密安全存储区，专门用来存放密码、API Key、证书等敏感数据。
/// 与 UserDefaults 的区别：
///   - UserDefaults：明文，任何有 App 沙盒访问权限的进程都能读
///   - Keychain：AES-256 加密，只有授权 App 能读
///
/// 【用法示例】
///   写入：KeychainHelper.write(key: "doubao_api_key", value: "sk-xxxx")
///   读取：let key = KeychainHelper.read(key: "doubao_api_key")
public enum KeychainHelper {

    /// 从 Keychain 读取一个字符串值。
    ///
    /// - Parameter key: 存储时使用的键名（如 "doubao_api_key"）
    /// - Returns: 找到则返回字符串值，没有则返回 nil
    public static func read(key: String) -> String? {
        // 构建查询字典（kSec* 开头的常量是 Security 框架定义的）
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,  // 查找"通用密码"类型的条目
            kSecAttrAccount: key,                        // 通过账户名（key）定位
            kSecReturnData:  true,                       // 返回原始数据
            kSecMatchLimit:  kSecMatchLimitOne           // 只取一条（防止重复）
        ]
        var item: CFTypeRef?
        // SecItemCopyMatching：查找 Keychain 条目，结果存入 item
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,                  // 转换为 Data
              let value = String(data: data, encoding: .utf8)  // Data → String
        else { return nil }
        return value
    }

    /// 向 Keychain 写入（或更新）一个字符串值。
    ///
    /// 先删除已有的同名条目（避免 kSecDuplicateItem 错误），再插入新值。
    ///
    /// - Parameters:
    ///   - key: 键名
    ///   - value: 要存储的字符串值（如 API Key）
    public static func write(key: String, value: String) {
        let data = Data(value.utf8)  // 字符串转 Data（Keychain 只能存 Data）
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData:   data
        ]
        SecItemDelete(query as CFDictionary)  // 先删除旧值（防止重复插入报错）
        SecItemAdd(query as CFDictionary, nil) // 插入新值（nil 表示不需要返回新条目的引用）
    }

    /// 从 Keychain 删除一个条目（用户清除 API Key 时调用）。
    ///
    /// - Parameter key: 要删除的键名
    public static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)  // 找不到也不报错，安全调用
    }
}
