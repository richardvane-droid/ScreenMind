import Foundation
import Vision
import CoreImage
import OSLog

private let logger = Logger(subsystem: "com.screenmind.mac", category: "OCR")

// MARK: - OCR Result

struct OCRResult {
    let text: String
    let language: DetectedLanguage
    let wordCount: Int
    let durationMs: Int
    let timestamp: Date

    enum DetectedLanguage: String {
        case chinese = "zh"
        case english = "en"
        case mixed   = "mixed"
        case unknown = "unknown"
    }
}

// MARK: - OCREngine

/// 对 CVPixelBuffer 执行 Vision 文字识别，并做后处理：
/// - 去噪：过滤低置信度 token
/// - 去重：跳过与上一帧高度相似的结果（避免重复分析静止页面）
/// - 语言检测：简中 / 英文 / 混合
final class OCREngine: @unchecked Sendable {

    // MARK: - Config
    var minimumConfidence: Float = 0.4
    var minimumTextLength: Int = 10       // 少于 10 字的帧跳过
    var deduplicationThreshold: Double = 0.85  // Jaccard 相似度阈值

    // MARK: - State
    private var lastResultTokens: Set<String> = []
    private let requestHandler = VNSequenceRequestHandler()

    // MARK: - Main entry

    /// 对一帧进行 OCR，返回 nil 表示与上帧重复（跳过）
    func recognizeText(in frame: CaptureFrame) async -> OCRResult? {
        let start = Date()
        let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)

        // 语言提示：中文优先
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.01   // 过滤极小字体（状态栏等噪音）

        do {
            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            try handler.perform([request])
        } catch {
            logger.error("OCR perform failed: \(error.localizedDescription)")
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return nil }

        // 按置信度过滤，拼接文本
        let lines: [String] = observations.compactMap { obs -> String? in
            guard let candidate = obs.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else { return nil }
            return candidate.string
        }

        let rawText = lines.joined(separator: "\n")
        guard rawText.count >= minimumTextLength else { return nil }

        // 去重检测
        let tokens = tokenize(rawText)
        if isDuplicate(tokens) { return nil }
        lastResultTokens = tokens

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        let lang = detectLanguage(rawText)

        logger.debug("OCR done: \(rawText.count) chars, \(elapsed)ms, lang=\(lang.rawValue)")

        return OCRResult(
            text: rawText,
            language: lang,
            wordCount: lines.count,
            durationMs: elapsed,
            timestamp: frame.timestamp
        )
    }

    // MARK: - Deduplication

    private func tokenize(_ text: String) -> Set<String> {
        // 中文按字符、英文按单词分词
        var tokens: Set<String> = []
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        for word in words where !word.isEmpty {
            if word.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
                // 中文：每个字符作为 token
                word.forEach { tokens.insert(String($0)) }
            } else {
                tokens.insert(word.lowercased())
            }
        }
        return tokens
    }

    /// Jaccard 相似度：交集 / 并集
    private func isDuplicate(_ tokens: Set<String>) -> Bool {
        guard !lastResultTokens.isEmpty else { return false }
        let intersection = tokens.intersection(lastResultTokens).count
        let union = tokens.union(lastResultTokens).count
        guard union > 0 else { return false }
        let jaccard = Double(intersection) / Double(union)
        return jaccard >= deduplicationThreshold
    }

    // MARK: - Language detection

    private func detectLanguage(_ text: String) -> OCRResult.DetectedLanguage {
        let chineseCount = text.unicodeScalars.filter {
            ($0.value >= 0x4E00 && $0.value <= 0x9FFF) ||
            ($0.value >= 0x3400 && $0.value <= 0x4DBF)
        }.count
        let asciiCount = text.unicodeScalars.filter { $0.value < 128 && $0.value > 32 }.count
        let total = chineseCount + asciiCount
        guard total > 0 else { return .unknown }
        let chineseRatio = Double(chineseCount) / Double(total)
        if chineseRatio > 0.7 { return .chinese }
        if chineseRatio < 0.2 { return .english }
        return .mixed
    }

    // MARK: - Reset dedup state

    func resetDeduplication() {
        lastResultTokens = []
    }
}
