import Foundation
import NaturalLanguage

/// Two-stage anxiety scorer.
///
/// Stage 1 — NaturalLanguage sentiment (< 10 ms, runs on every OCR frame).
/// Stage 2 — Ollama local LLM (only called when Stage 1 sentiment < -0.2).
///
/// This design keeps the Neural Engine load low: Ollama is invoked roughly
/// once every 3–5 minutes rather than on every frame.
public final class AnxietyScorer: @unchecked Sendable {

    // MARK: - Configuration

    /// Stage 1 sentiment score threshold below which Stage 2 is triggered.
    /// NL sentiment range: -1.0 (negative) … +1.0 (positive)
    public var stage1Threshold: Double = -0.2

    // MARK: - Stage 1 — NaturalLanguage

    private let sentimentTagger: NLTagger = {
        let t = NLTagger(tagSchemes: [.sentimentScore])
        return t
    }()

    /// Fast sentiment pre-filter. Returns a normalised anxiety score 0–1.
    /// Negative sentiment → higher anxiety score.
    public func stage1Score(text: String) -> Double {
        sentimentTagger.string = text
        let (tag, _) = sentimentTagger.tag(at: text.startIndex,
                                           unit: .document,
                                           scheme: .sentimentScore)
        // tag?.rawValue is a string like "-0.45"
        let sentiment = Double(tag?.rawValue ?? "0") ?? 0.0
        // Map [-1, 1] → anxiety [1, 0]: anxious = negative sentiment
        return (1.0 - sentiment) / 2.0
    }

    // MARK: - Stage 2 — Ollama (local LLM)

    /// Ollama endpoint — localhost, no network required.
    private let ollamaEndpoint = URL(string: "http://127.0.0.1:11434/api/generate")!
    private let ollamaModel = "qwen2.5:3b"

    /// Deep LLM-based anxiety analysis. Called only when Stage 1 flags negative content.
    public func stage2Score(text: String) async throws -> AnxietyResult {
        let start = Date()
        let prompt = buildPrompt(text: text)
        let body: [String: Any] = [
            "model": ollamaModel,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 100]
        ]
        var request = URLRequest(url: ollamaEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, _) = try await URLSession.shared.data(for: request)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)

        // Ollama response: { "response": "..." }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw ScorerError.invalidResponse
        }
        return parseOllamaResponse(responseText, durationMs: elapsed)
    }

    // MARK: - Combined entry point

    /// Run the two-stage pipeline. Returns Stage 1 result if content is benign,
    /// Stage 2 result if Stage 1 flags anxiety.
    public func analyze(text: String) async -> AnxietyResult {
        let s1 = stage1Score(text: text)
        let s1Sentiment = 1.0 - (s1 * 2.0)   // convert back to sentiment for threshold check
        guard s1Sentiment < stage1Threshold else {
            // Content is positive/neutral — no need to call LLM
            return AnxietyResult(score: s1, source: .naturalLanguage)
        }
        // Negative content — escalate to Ollama
        do {
            return try await stage2Score(text: text)
        } catch {
            // Graceful degradation: return Stage 1 score if LLM is unavailable
            return AnxietyResult(score: s1, source: .naturalLanguage)
        }
    }

    // MARK: - Helpers

    private func buildPrompt(text: String) -> String {
        """
        你是一个专注于分析文本对读者情绪影响的助手。
        请分析以下文本对读者产生的焦虑感，给出 0.0 到 1.0 的评分（0=完全不焦虑，1=极度焦虑）。
        同时列出最多3个导致焦虑的关键词。

        文本（节选，最多300字）：
        \(String(text.prefix(300)))

        请用以下 JSON 格式回复，不要输出其他内容：
        {"score": 0.65, "keywords": ["关键词1", "关键词2"]}
        """
    }

    private func parseOllamaResponse(_ text: String, durationMs: Int) -> AnxietyResult {
        // Extract JSON from response
        let pattern = #"\{[^}]+\}"#
        guard let range = text.range(of: pattern, options: .regularExpression),
              let data = String(text[range]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let score = json["score"] as? Double else {
            return AnxietyResult(score: 0.5, source: .ollama, durationMs: durationMs)
        }
        let keywords = json["keywords"] as? [String] ?? []
        return AnxietyResult(score: min(max(score, 0), 1),
                             dominantKeywords: keywords,
                             source: .ollama,
                             durationMs: durationMs)
    }

    // MARK: - Errors

    public enum ScorerError: Error {
        case invalidResponse
        case ollamaUnavailable
    }
}
