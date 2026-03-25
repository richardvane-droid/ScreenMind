// =============================================================================
//  OCREngine.swift
//  ScreenMindMac — Mac 端主应用
// =============================================================================
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenMind 需要"读懂"屏幕上的内容。
//  但 ScreenCaptureKit 给我们的是一张图片（像素数据 CVPixelBuffer），不是文字。
//  OCREngine 负责把"图片 → 文字"这个转换做好，同时做必要的过滤。
//
//  【OCR 是什么？】
//  OCR = Optical Character Recognition（光学字符识别）。
//  就是"让计算机读图片里的文字"，比如扫描书页识别文字、身份证照片识别信息。
//  苹果在 macOS 10.15 以后提供了内置的 OCR 引擎（Vision 框架），
//  在苹果芯片上用神经引擎加速，速度很快。
//
//  【OCREngine 的职责】
//  除了基础 OCR，还做了三层过滤，避免"垃圾数据"传给焦虑评分：
//
//  层级 1 — 置信度过滤：
//    Vision OCR 对每段识别的文字给出置信度（0–1）。
//    置信度低的（< 0.4）说明识别不确定，扔掉。
//    （比如模糊的状态栏小字，识别结果可能乱码）
//
//  层级 2 — 最小长度过滤：
//    少于 10 个字符的结果意义不大，扔掉。
//    （比如只识别出"返回""确定"这类按钮文字）
//
//  层级 3 — 去重过滤（Deduplication）：
//    如果屏幕内容和上一帧基本一样（相似度 > 85%），跳过本帧不处理。
//    用户滚动阅读时，屏幕每 30 秒截图一次，相邻帧可能还是同一段文章，没必要重复分析。
//    去重算法：Jaccard 相似度（集合交集/并集，见下方详解）。
//
//  【部署位置】
//  ScreenMindMac/OCREngine/OCREngine.swift
//
// =============================================================================

import Foundation   // 基础类型（Date、Set 等）
import Vision       // 苹果 OCR 框架（文字识别、人脸检测、条形码识别等计算机视觉功能）
import CoreImage    // 图像处理框架（CIImage：Apple 的通用图像表示格式）
import OSLog        // 结构化日志

private let logger = Logger(subsystem: "com.screenmind.mac", category: "OCR")

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 数据结构：OCR 识别结果
// MARK: ──────────────────────────────────────────────────────────────────────

/// 一帧 OCR 识别的完整结果。
///
/// 这个结构体是 OCREngine 的"产品"，
/// 向上游（CaptureCoordinator）提供识别出的文字和元信息。
struct OCRResult {
    let text: String              // 识别出的全部文字（多行，用 \n 连接）
    let language: DetectedLanguage // 检测到的语言
    let wordCount: Int            // 识别到的文本行数（注意：是行数，不是字数）
    let durationMs: Int           // 本次 OCR 耗时（毫秒），用于性能监控
    let timestamp: Date           // 截图时间

    /// 语言类型枚举（OCRResult 的嵌套类型）。
    ///
    /// 嵌套在 OCRResult 里的好处：用 OCRResult.DetectedLanguage 访问，
    /// 命名空间清晰，不会和项目其他地方的"语言"枚举混淆。
    enum DetectedLanguage: String {
        case chinese = "zh"     // 简/繁中文（统一处理）
        case english = "en"     // 英文
        case mixed   = "mixed"  // 中英混合（如技术文章）
        case unknown = "unknown" // 无法判断（纯数字、符号等）
    }
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 核心类：OCREngine
// MARK: ──────────────────────────────────────────────────────────────────────

/// 屏幕帧文字识别引擎。
///
/// 接收 CVPixelBuffer（原始像素数据），输出过滤去重后的 OCRResult。
///
/// 设计说明：
///   OCREngine 是有状态的（lastResultTokens 记录上一帧）。
///   一个 OCREngine 实例服务一个监控会话，停止监控时调用 resetDeduplication() 清空状态。
///
/// 为什么 @unchecked Sendable？
///   OCREngine 的属性（lastResultTokens、requestHandler）不是自动线程安全的。
///   但 CaptureCoordinator 保证所有 handleFrame 调用都在同一个串行队列（processingQueue），
///   所以实际上是线程安全的。@unchecked 告诉编译器"我保证，相信我"。
final class OCREngine: @unchecked Sendable {

    // MARK: - 可调配置 ───────────────────────────────────────────────────

    /// Vision OCR 置信度下限（0.0–1.0）。
    /// 低于这个值的文字段落会被丢弃（认为识别不准确）。
    /// 默认 0.4：40% 置信度以下的识别结果不可信。
    var minimumConfidence: Float = 0.4

    /// 有效帧的最少字符数。
    /// 少于 10 字的帧通常是工具栏、状态栏等无意义内容，跳过。
    var minimumTextLength: Int = 10

    /// Jaccard 去重阈值（0.0–1.0）。
    /// 相似度超过这个值的帧被认为是"重复帧"，跳过。
    /// 默认 0.85：85% 的内容相同就认为是重复（允许少量滚动变化）。
    var deduplicationThreshold: Double = 0.85

    // MARK: - 内部状态 ────────────────────────────────────────────────────

    /// 上一帧 OCR 结果的 Token 集合，用于去重比较。
    ///
    /// Set<String> = 字符串集合（不允许重复，查找快 O(1)）。
    /// 每次成功识别后更新，用来和下一帧做 Jaccard 相似度比较。
    private var lastResultTokens: Set<String> = []

    /// Vision 的序列请求处理器（Sequence Request Handler）。
    ///
    /// 用于连续帧处理时保持状态（比如跟踪同一个文本块随时间的变化）。
    /// 这里实际上我们每帧都新建 VNImageRequestHandler，
    /// requestHandler 目前只是预留的扩展点。
    private let requestHandler = VNSequenceRequestHandler()

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 主入口：识别一帧
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 对一帧屏幕图像做 OCR 识别，返回 nil 表示这帧应该跳过（重复 or 内容太少）。
    ///
    /// 整个识别流程：
    ///   1. 像素数据 → CIImage（Vision 能处理的格式）
    ///   2. 配置 Vision OCR 请求（语言、精度等）
    ///   3. 执行识别，得到 VNRecognizedTextObservation 数组
    ///   4. 按置信度过滤，拼成一段文字
    ///   5. Jaccard 去重，如果和上帧太像就返回 nil
    ///   6. 语言检测，包装成 OCRResult 返回
    ///
    /// async 关键字：这个函数是异步的（因为 Vision OCR 可能需要几十毫秒）。
    /// 调用方 await 这个函数，OCR 执行期间可以干别的事，不阻塞。
    ///
    /// - Parameter frame: 截图帧（包含像素数据和元信息）
    /// - Returns: OCRResult（有效识别结果）或 nil（重复/内容不足，应跳过）
    func recognizeText(in frame: CaptureFrame) async -> OCRResult? {
        let start = Date() // 记录开始时间

        // ── 步骤 1：像素数据 → CIImage ────────────────────────────────
        // CVPixelBuffer 是内存中的原始像素数组（R/G/B/A 字节）
        // CIImage 是 Core Image 的图像表示，Vision 框架可以直接处理它
        let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)

        // ── 步骤 2：配置 Vision OCR 请求 ────────────────────────────────
        let request = VNRecognizeTextRequest()
        // 优先识别简/繁中文，其次英文（按优先级排列，影响混合文字的识别策略）
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        // .fast：速度快，精度略低，适合实时场景（对应 .accurate 是慢但更准）
        request.recognitionLevel = .fast
        // false：不用语言纠错（我们不需要，并且纠错可能把专有名词改错）
        request.usesLanguageCorrection = false
        // minimumTextHeight = 0.01：忽略高度小于图像高度 1% 的文字（过滤状态栏极小字体）
        request.minimumTextHeight = 0.01

        // ── 步骤 3：执行 OCR ────────────────────────────────────────────
        do {
            // VNImageRequestHandler：用于处理单张图像的请求（区别于视频流）
            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            // perform：执行请求，结果存在 request.results 里
            try handler.perform([request])
        } catch {
            // OCR 执行失败（极少发生，可能是图像格式问题）
            logger.error("OCR perform failed: \(error.localizedDescription)")
            return nil
        }

        // ── 步骤 4：过滤低置信度结果，拼接文字 ─────────────────────────
        guard let observations = request.results, !observations.isEmpty else { return nil }
        // request.results 是 [VNRecognizedTextObservation]
        // 每个 observation 代表图像中识别出的一段文字（一行）

        // compactMap：映射 + 过滤 nil
        // 对每个 observation，取置信度最高的候选文字，如果置信度不够就返回 nil（被过滤掉）
        let lines: [String] = observations.compactMap { obs -> String? in
            guard let candidate = obs.topCandidates(1).first, // 取最可能的一个候选
                  candidate.confidence >= minimumConfidence    // 置信度检查
            else { return nil }
            return candidate.string  // 这行文字的内容
        }

        // 把所有行用换行符连接成一段文字
        let rawText = lines.joined(separator: "\n")

        // 内容太少，跳过（比如只识别出"返回""取消"等按钮文字）
        guard rawText.count >= minimumTextLength else { return nil }

        // ── 步骤 5：Jaccard 去重 ─────────────────────────────────────────
        // 把文字分词成 Token 集合
        let tokens = tokenize(rawText)
        // 如果和上帧太像，返回 nil（跳过本帧）
        if isDuplicate(tokens) { return nil }
        // 不是重复帧，更新"上帧"记录
        lastResultTokens = tokens

        // ── 步骤 6：计算耗时 + 检测语言 + 包装结果 ──────────────────────
        let elapsed = Int(Date().timeIntervalSince(start) * 1000) // 毫秒
        let lang = detectLanguage(rawText)

        logger.debug("OCR done: \(rawText.count) chars, \(elapsed)ms, lang=\(lang.rawValue)")

        return OCRResult(
            text: rawText,
            language: lang,
            wordCount: lines.count,   // 行数
            durationMs: elapsed,
            timestamp: frame.timestamp // 用截图时间（不是 OCR 完成时间）
        )
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 去重：Jaccard 相似度
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 把文本分词成 Token 集合。
    ///
    /// 【为什么要分词？】
    /// 直接比较两段文字字符串（"这个内容和上次一样吗？"）效果不好：
    ///   - 顺序不同但内容相同（界面重排）会判定为不同
    ///   - 用集合（Set）忽略顺序，只看"这两段文字包含哪些词"
    ///
    /// 【中英文分词策略不同】
    /// 英文："Hello World" → {"hello", "world"}（按空格分词，转小写）
    /// 中文："你好世界" → {"你", "好", "世", "界"}（每个字是一个 token，没有空格可分）
    /// 混合："Hello 世界" → {"hello", "世", "界"}（分别处理）
    ///
    /// - Parameter text: OCR 识别出的文字
    /// - Returns: Token 集合（供 Jaccard 计算用）
    private func tokenize(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        // 先按空白字符（空格、换行、制表符）分割成单词
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        for word in words where !word.isEmpty {
            // 判断这个"词"是否包含中文字符
            // Unicode 中文区间：0x4E00–0x9FFF（CJK 统一汉字基本区）
            if word.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
                // 中文词：逐字切分（每个汉字单独作为一个 token）
                word.forEach { tokens.insert(String($0)) }
            } else {
                // 英文/数字词：整词转小写（大小写不敏感，"Hello" 和 "hello" 算同一个词）
                tokens.insert(word.lowercased())
            }
        }
        return tokens
    }

    /// 用 Jaccard 相似度判断当前帧是否与上帧重复。
    ///
    /// 【Jaccard 相似度是什么？】
    /// 衡量两个集合有多相似的指标：
    ///   J(A, B) = |A ∩ B| / |A ∪ B|
    ///   A ∩ B = 交集（两个集合共同有的元素）
    ///   A ∪ B = 并集（两个集合合并后所有元素）
    ///
    /// 例子：
    ///   帧A tokens：{"你", "好", "世", "界", "hello"}    5个元素
    ///   帧B tokens：{"你", "好", "世", "界", "world"}    5个元素
    ///   交集：{"你", "好", "世", "界"}                  4个元素
    ///   并集：{"你", "好", "世", "界", "hello", "world"} 6个元素
    ///   Jaccard = 4/6 ≈ 0.67 → 不超过 0.85，不算重复，处理这帧
    ///
    /// - Parameter tokens: 当前帧的 token 集合
    /// - Returns: true = 重复（应跳过），false = 新内容（应处理）
    private func isDuplicate(_ tokens: Set<String>) -> Bool {
        guard !lastResultTokens.isEmpty else { return false } // 第一帧永远不算重复
        let intersection = tokens.intersection(lastResultTokens).count // 交集大小
        let union = tokens.union(lastResultTokens).count               // 并集大小
        guard union > 0 else { return false }
        let jaccard = Double(intersection) / Double(union)
        return jaccard >= deduplicationThreshold // 超过阈值 → 重复
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 语言检测
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 通过统计中文字符和 ASCII 字符的比例，判断文本的主要语言。
    ///
    /// 【为什么不用 NLLanguageRecognizer？】
    /// NLLanguageRecognizer 是苹果提供的语言识别 API，但在短文本上不够稳定。
    /// 这里用简单的字符计数法，更快、更可预期。
    ///
    /// 【判断规则】
    ///   中文字符 > 70% → .chinese
    ///   中文字符 < 20% → .english
    ///   其他（20–70%） → .mixed
    ///   无法统计       → .unknown
    ///
    /// - Parameter text: OCR 文字
    /// - Returns: 检测到的语言类型
    private func detectLanguage(_ text: String) -> OCRResult.DetectedLanguage {
        // 统计中文字符数（包括 CJK 基本区 4E00–9FFF 和扩展区 3400–4DBF）
        let chineseCount = text.unicodeScalars.filter {
            ($0.value >= 0x4E00 && $0.value <= 0x9FFF) || // CJK 统一汉字（常用字）
            ($0.value >= 0x3400 && $0.value <= 0x4DBF)    // CJK 扩展 A 区（不常用字）
        }.count

        // 统计 ASCII 字母/数字字符（排除控制字符和空格，value 在 33–127）
        let asciiCount = text.unicodeScalars.filter {
            $0.value < 128 && $0.value > 32 // 可打印 ASCII
        }.count

        let total = chineseCount + asciiCount
        guard total > 0 else { return .unknown } // 全是符号/空白，无法判断

        let chineseRatio = Double(chineseCount) / Double(total)
        if chineseRatio > 0.7 { return .chinese } // 70% 以上是中文
        if chineseRatio < 0.2 { return .english } // 20% 以下是中文（即英文为主）
        return .mixed                              // 20–70% 之间是混合
    }

    // MARK: - 重置去重状态 ─────────────────────────────────────────────────

    /// 清空"上一帧"的记录，使下一帧强制处理（不走去重逻辑）。
    ///
    /// 调用时机：
    ///   - 用户从暂停恢复（用户可能切换了应用，页面已经完全变了）
    ///   - 捕获停止后重新启动
    func resetDeduplication() {
        lastResultTokens = []
    }
}
