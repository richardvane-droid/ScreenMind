// =============================================================================
//  AnxietyScorer.swift
//  ScreenMindCore — 跨平台共享层
// =============================================================================
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenMind 的核心功能是"帮助用户减少焦虑性内容摄入"。
//  要做到这一点，App 首先要能"读懂"屏幕上的文字是否令人焦虑。
//  AnxietyScorer 就是这个"理解文字情绪"的核心模块。
//
//  输入：一段 OCR 识别出来的屏幕文字（可能是新闻、微信消息、抖音弹幕……）
//  输出：一个 0.0–1.0 的焦虑分（0 = 完全平静，1 = 极度焦虑）+ 关键词列表
//
//  【两阶段设计思路】
//
//  ┌──────────────────────────────────────────────────────────────────────┐
//  │  OCR 文本输入                                                         │
//  │       ↓                                                              │
//  │  Stage 1：NaturalLanguage 情感分析（< 10ms，每帧都跑）                 │
//  │       ↓ 情感分 ≥ -0.2（正面/中性内容）                                │
//  │       └─→ 直接返回 Stage 1 分数（source = .naturalLanguage）           │
//  │       ↓ 情感分 < -0.2（负面内容！）                                    │
//  │  Stage 2：Ollama 本地 LLM（3–8秒，按需触发）                           │
//  │       ↓                                                              │
//  │       └─→ 返回精确分数 + 关键词（source = .ollama）                    │
//  └──────────────────────────────────────────────────────────────────────┘
//
//  【为什么分两阶段，而不是每帧都调 LLM？】
//  App 每 30 秒截一次屏，如果每次都调 LLM（3–8秒/次），CPU 会一直跑，笔记本散热扇呼呼转。
//  Stage 1 用苹果芯片内置的神经引擎做情感分析，几乎不耗电。
//  只有真的检测到负面内容，才动用 LLM。实践中 LLM 约 3–5 分钟才触发一次。
//
//  【部署位置】
//  ScreenMindCore/Sources/ScreenMindCore/AnxietyScorer/AnxietyScorer.swift
//  这个文件在 ScreenMindCore Swift Package 里，Mac 和 iOS 两端都可以直接使用。
//
//  【依赖的外部服务】
//  Ollama（本地 LLM 运行时）：https://ollama.com
//  用户需要在 Mac 上安装 Ollama，并 pull qwen2.5:3b 模型。
//  Ollama 启动后在本机 11434 端口提供 HTTP API，不需要联网。
//
// =============================================================================

import Foundation      // 提供 URL、URLSession、JSONSerialization、Date 等基础类型
import NaturalLanguage // 苹果的自然语言处理框架，提供情感分析、语言检测、分词等能力

/// 两阶段焦虑评分器。
///
/// 【初学者：什么是 public final class？】
/// - public：这个类可以在 ScreenMindCore 包之外使用（Mac 端和 iOS 端都能访问）
/// - final：不允许其他类继承它（这是一个设计决定，确保行为可预测）
/// - class：引用类型（与 struct 的区别：class 可以被多处共享，改一处所有地方都变）
///
/// 【为什么用 @unchecked Sendable？】
/// Swift 的 Actor 系统要求跨并发任务传递的类型标注 Sendable（表示线程安全）。
/// 这里我们手动保证线程安全（sentimentTagger 只在一个任务里用），所以用 @unchecked 跳过编译器检查。
public final class AnxietyScorer: @unchecked Sendable {

    // MARK: - 可调节的配置项 ─────────────────────────────────────────────────

    /// Stage 1 触发 Stage 2 的情感分阈值。
    ///
    /// NaturalLanguage 的情感分范围：-1.0（极负面）到 +1.0（极正面）
    /// 默认值 -0.2 含义：情感分低于 -0.2（偏负面）就升级到 LLM 做精确分析。
    /// 可以在 App 设置里调整：
    ///   - 调高（如 0.0）→ 更容易触发 Stage 2，消耗更多 CPU，但漏报更少
    ///   - 调低（如 -0.5）→ 更不容易触发 Stage 2，更省电，但可能漏掉轻度负面内容
    public var stage1Threshold: Double = -0.2

    // MARK: - Stage 1 内部组件 ───────────────────────────────────────────────

    /// NaturalLanguage 情感分析器。
    ///
    /// 【NLTagger 是什么？】
    /// 苹果的 NaturalLanguage 框架提供的文本标注工具。
    /// 传入 .sentimentScore 表示"我要做情感分析"（打分模式）。
    ///
    /// 【为什么用 lazy 闭包初始化？】
    /// 用 `= { ... }()` 这种闭包语法初始化，可以在创建时做一些配置。
    /// 如果直接写 `= NLTagger(tagSchemes: [.sentimentScore])`，效果是一样的，
    /// 但闭包写法更清晰，便于以后添加更多配置。
    private let sentimentTagger: NLTagger = {
        // 创建一个只做情感分析的 NLTagger
        let t = NLTagger(tagSchemes: [.sentimentScore])
        return t
    }()

    // MARK: - Stage 2 内部组件 ───────────────────────────────────────────────

    /// Ollama API 地址。
    ///
    /// Ollama 是一个本地 LLM 运行时，安装后在本机后台运行，
    /// 通过 HTTP API 接受请求（就像一个本地的"小服务器"）。
    /// 127.0.0.1 = 本机地址（只有本机能访问，不会经过互联网），11434 是默认端口。
    private let ollamaEndpoint = URL(string: "http://127.0.0.1:11434/api/generate")!
    // 注意末尾的 !：URL(string:) 返回 Optional<URL>，我们确定这个字符串合法，强制解包。

    /// Ollama 使用的模型名称。
    ///
    /// qwen2.5:3b = 阿里通义千问 2.5，3B 参数版本。
    /// 选 3B 的原因：
    ///   - 参数量小，在 Mac 上推理速度快（约 3–5 秒/次）
    ///   - 中文理解能力好（通义千问专门优化了中文）
    ///   - 占用显存少（约 2GB），不影响日常使用
    ///   - 更大的 7B/14B 模型更准确，但在后台运行会明显影响 Mac 性能
    private let ollamaModel = "qwen2.5:3b"

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: Stage 1：快速情感分析
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 对文本做快速情感分析，返回焦虑分（0.0–1.0）。
    ///
    /// 【算法原理】
    /// NaturalLanguage 框架用苹果训练好的神经网络模型，分析整段文字的情感倾向，
    /// 给出一个 -1.0 到 +1.0 的分数：
    ///   -1.0 = 极度负面（"股市暴跌、经济崩溃、失业潮来袭"）
    ///    0.0 = 中性（"今天会议议程如下"）
    ///   +1.0 = 极度正面（"今天天气真好，心情愉快"）
    ///
    /// 我们把这个情感分"翻转并归一化"，映射到焦虑分：
    ///   情感分 -1.0 → 焦虑分 1.0（最焦虑）
    ///   情感分  0.0 → 焦虑分 0.5（中性）
    ///   情感分 +1.0 → 焦虑分 0.0（最放松）
    ///   公式：焦虑分 = (1.0 - 情感分) / 2.0
    ///
    /// - Parameter text: 要分析的文本（支持中文、英文，NL 框架自动检测语言）
    /// - Returns: 焦虑分，0.0（完全不焦虑）到 1.0（极度焦虑）
    public func stage1Score(text: String) -> Double {
        // 把要分析的文字设置给 NLTagger
        sentimentTagger.string = text

        // 分析整段文字的情感，返回一个"标签"（tag）
        // unit: .document 表示分析整篇文章，而不是逐句分析
        // scheme: .sentimentScore 表示要情感分数这种标签
        let (tag, _) = sentimentTagger.tag(at: text.startIndex,
                                           unit: .document,
                                           scheme: .sentimentScore)
        // tag?.rawValue 是一个字符串，比如 "-0.45" 或 "0.78"
        // 如果 text 为空或无法识别，tag 可能是 nil，这时 rawValue 取 "0"
        let sentiment = Double(tag?.rawValue ?? "0") ?? 0.0

        // 公式：情感分[-1, 1] → 焦虑分[0, 1]
        // 情感分是 -1 时：(1 - (-1)) / 2 = 1.0（最焦虑）
        // 情感分是  0 时：(1 - 0) / 2 = 0.5（中性）
        // 情感分是  1 时：(1 - 1) / 2 = 0.0（最平静）
        return (1.0 - sentiment) / 2.0
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: Stage 2：本地 LLM 深度分析
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 调用本地 Ollama LLM 做深度焦虑分析，返回精确分数 + 关键词。
    ///
    /// 【这个函数为什么是 async throws？】
    /// - async：因为网络请求要等待（发请求→等响应，可能要几秒），
    ///   用 async 可以让调用方在等待期间去干别的事，不会"卡住"整个程序。
    /// - throws：如果 Ollama 没有启动、网络超时、返回格式不对，会抛出错误，
    ///   调用方用 try 调用，可以用 do-catch 处理错误。
    ///
    /// 【Ollama 的工作原理（概述）】
    /// 1. 我们把文本包装成一个 Prompt（提示词）
    /// 2. 通过 HTTP POST 发送给本机 11434 端口
    /// 3. Ollama 用 Qwen 模型生成回复（JSON 格式）
    /// 4. 我们解析 JSON，提取焦虑分和关键词
    ///
    /// - Parameter text: 要分析的文本
    /// - Returns: AnxietyResult，包含精确焦虑分 + 关键词 + 来源(.ollama) + 耗时
    /// - Throws: ScorerError.invalidResponse（LLM 返回格式不对）
    public func stage2Score(text: String) async throws -> AnxietyResult {
        let start = Date() // 记录开始时间，用于计算耗时

        // 构建发给 LLM 的提示词（Prompt）
        // buildPrompt 会把文本嵌入一段精心设计的指令，引导 LLM 输出 JSON
        let prompt = buildPrompt(text: text)

        // 构建 HTTP 请求体（JSON 格式）
        // Ollama API 的参数说明：
        //   "model"：使用哪个模型
        //   "prompt"：发给模型的问题/指令
        //   "stream": false → 等全部生成完再一次性返回（方便解析），不用流式输出
        //   "options": temperature（越低输出越稳定，0.1 让 LLM 尽量输出固定格式的 JSON）
        //              num_predict（最多生成 100 个 token，够了，JSON 不需要太长）
        let body: [String: Any] = [
            "model": ollamaModel,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 100]
        ]

        // 构建 URLRequest（HTTP 请求）
        var request = URLRequest(url: ollamaEndpoint)
        request.httpMethod = "POST"                                       // POST 方法（发送数据）
        request.setValue("application/json", forHTTPHeaderField: "Content-Type") // 告诉服务器"我发的是 JSON"
        request.httpBody = try JSONSerialization.data(withJSONObject: body) // 把 Swift 字典序列化成 JSON 数据
        request.timeoutInterval = 15 // 最多等 15 秒，超时就报错（防止 Ollama 卡死）

        // 发送请求，等待响应
        // URLSession.shared 是系统提供的网络会话管理器（单例）
        // await 表示"暂停这个函数，等网络响应回来后继续"
        let (data, _) = try await URLSession.shared.data(for: request)
        // data = 服务器返回的原始字节数据（就是 JSON 文本的字节表示）
        // _ = HTTP 响应元信息（状态码等），这里我们不需要用，所以忽略

        // 计算耗时（毫秒）
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)

        // 解析 Ollama 返回的 JSON
        // Ollama /api/generate 的响应格式：{ "model": "...", "response": "{ \"score\": 0.7, ... }", ... }
        // 我们只需要里面的 "response" 字段（这是 LLM 生成的文字）
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            // 如果解析失败（比如 Ollama 返回了错误格式），抛出错误
            throw ScorerError.invalidResponse
        }

        // 进一步解析 LLM 输出的内容，提取我们让它输出的 JSON 分数
        return parseOllamaResponse(responseText, durationMs: elapsed)
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 公开入口：两阶段组合分析
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 对外唯一的分析接口。自动决定走 Stage 1 还是 Stage 2。
    ///
    /// 【调用者：AnxietyPipeline】
    /// AnxietyPipeline 每次收到 OCR 文本后，调用这个方法。
    /// 不用关心内部是走 NL 还是 LLM，直接拿结果用就好。
    ///
    /// 【降级策略（Graceful Degradation）】
    /// 如果 Ollama 没有启动、网络超时、模型不存在：
    ///   - 不会让 App 崩溃（do-catch 捕获错误）
    ///   - 降级使用 Stage 1 的分数（不那么精确，但总比没有好）
    ///   - 这叫"优雅降级"，是生产级 App 的重要设计原则
    ///
    /// - Parameter text: OCR 识别的屏幕文字
    /// - Returns: AnxietyResult（来源是 .naturalLanguage 或 .ollama 之一）
    public func analyze(text: String) async -> AnxietyResult {
        // 先跑 Stage 1（< 10ms，几乎没有性能开销）
        let s1 = stage1Score(text: text)

        // 把焦虑分"反转"回情感分，用来和阈值比较
        // s1 是焦虑分（0–1），sentimen = 1 - (s1 * 2)，还原成 NL 的情感分格式
        let s1Sentiment = 1.0 - (s1 * 2.0)

        // 判断：情感分 >= 阈值（-0.2）？
        // 如果是（正面/中性），直接返回 Stage 1 结果，不调 LLM
        guard s1Sentiment < stage1Threshold else {
            // 内容是正面或中性的，Stage 1 就够了
            // source: .naturalLanguage 表示这个分数来自苹果的 NL 框架
            return AnxietyResult(score: s1, source: .naturalLanguage)
        }

        // 内容是负面的，升级到 Stage 2（LLM 深度分析）
        do {
            // try await：调用异步函数，并等待结果
            return try await stage2Score(text: text)
        } catch {
            // Ollama 出错了（没启动/超时/格式错）→ 优雅降级：返回 Stage 1 分数
            // 注意：source 仍标记为 .naturalLanguage，让调试窗口可以知道 LLM 没有生效
            return AnxietyResult(score: s1, source: .naturalLanguage)
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 私有辅助函数
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 构建发给 Ollama LLM 的提示词（Prompt）。
    ///
    /// 【提示词工程（Prompt Engineering）】
    /// 大语言模型的输出质量很大程度取决于如何写提示词。
    /// 这里的技巧：
    ///   1. 先告诉 LLM 它的角色（"你是一个分析情绪影响的助手"）
    ///   2. 明确要求（给焦虑分 + 关键词）
    ///   3. 指定输出格式（JSON），方便程序解析
    ///   4. 文本只取前 300 字（LLM 的 token 限制，也足够分析了）
    ///
    /// - Parameter text: OCR 文本
    /// - Returns: 格式化好的提示词字符串
    private func buildPrompt(text: String) -> String {
        // 使用 Swift 的多行字符串字面量（""" ... """）
        """
        你是一个专注于分析文本对读者情绪影响的助手。
        请分析以下文本对读者产生的焦虑感，给出 0.0 到 1.0 的评分（0=完全不焦虑，1=极度焦虑）。
        同时列出最多3个导致焦虑的关键词。

        文本（节选，最多300字）：
        \(String(text.prefix(300)))

        请用以下 JSON 格式回复，不要输出其他内容：
        {"score": 0.65, "keywords": ["关键词1", "关键词2"]}
        """
        // \(String(text.prefix(300))) 是字符串插值：把变量嵌入字符串
        // text.prefix(300) 取前 300 个字符，防止超过 LLM 的 token 限制
    }

    /// 解析 Ollama LLM 返回的文字，提取 JSON 中的焦虑分和关键词。
    ///
    /// 【为什么需要正则表达式？】
    /// LLM 有时会在 JSON 前后输出一些多余的文字（比如 "好的，以下是分析结果：{...}"），
    /// 用正则表达式 `\{[^}]+\}` 从文字中"挖出" JSON 部分，更健壮。
    ///
    /// 【如果 LLM 输出不规范怎么办？】
    /// 返回 score = 0.5（中性），不崩溃，继续运行。这也是"优雅降级"。
    ///
    /// - Parameter text: LLM 生成的原始文字（可能包含 JSON 和其他内容）
    /// - Parameter durationMs: 分析耗时，直接透传到结果
    /// - Returns: AnxietyResult
    private func parseOllamaResponse(_ text: String, durationMs: Int) -> AnxietyResult {
        // 正则表达式：匹配 `{` 开头、`}` 结尾的 JSON 对象
        // #"..."# 是 Swift 的原始字符串（\{ 不需要写成 \\{）
        let pattern = #"\{[^}]+\}"#

        // 尝试在 LLM 输出中找到 JSON 部分
        guard let range = text.range(of: pattern, options: .regularExpression),
              let data = String(text[range]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let score = json["score"] as? Double else {
            // 解析失败：返回中性分 0.5，来源标记为 ollama（表示尝试过但解析失败）
            return AnxietyResult(score: 0.5, source: .ollama, durationMs: durationMs)
        }

        // 提取关键词列表（如果 LLM 没有输出关键词，默认空数组）
        let keywords = json["keywords"] as? [String] ?? []

        // min(max(score, 0), 1)：把分数限制在 [0, 1] 范围内
        // 防御性编程：即使 LLM 输出了 1.5 或 -0.3 这样越界的值也没关系
        return AnxietyResult(
            score: min(max(score, 0), 1), // 限制在 [0.0, 1.0]
            dominantKeywords: keywords,
            source: .ollama,
            durationMs: durationMs
        )
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 错误类型定义
    // MARK: ─────────────────────────────────────────────────────────────────

    /// Stage 2 可能抛出的错误类型。
    ///
    /// 【Swift 错误处理机制】
    /// Swift 用 enum 定义错误类型，每个 case 是一种错误。
    /// 函数用 throws 声明可能抛出错误，调用方用 try + do-catch 处理。
    public enum ScorerError: Error {
        case invalidResponse   // Ollama 返回的数据格式不对，无法解析
        case ollamaUnavailable // Ollama 服务没有运行（尚未使用，为未来扩展预留）
    }
}
