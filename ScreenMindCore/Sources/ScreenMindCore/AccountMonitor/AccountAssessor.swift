import Foundation

/// Assesses a video account's anxiety-inducing style.
///
/// Primary engine: 豆包 (Doubao) via 火山方舟 API.
/// Fallback engine: Ollama local LLM (when API key absent or network unavailable).
public final class AccountAssessor: @unchecked Sendable {

    // MARK: - Doubao (火山方舟) configuration

    private let doubaoEndpoint = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!
    private let doubaoModel = "doubao-pro-32k"

    /// Retrieved from Keychain at runtime — never hardcoded.
    private var doubaoAPIKey: String? {
        KeychainHelper.read(key: "doubao_api_key")
    }

    // Ollama fallback
    private let ollamaEndpoint = URL(string: "http://127.0.0.1:11434/api/generate")!
    private let ollamaModel = "qwen2.5:3b"

    private let persistence: PersistenceController

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    // MARK: - Public API

    /// Assess (or return cached) anxiety score for an account.
    public func assess(accountName: String, platform: AccountPlatform) async -> AccountAssessment {
        // Check cache first (re-assess if older than 7 days)
        if let cached = cachedAssessment(accountName: accountName, platform: platform) {
            return cached
        }

        // Try Doubao first
        if let apiKey = doubaoAPIKey, !apiKey.isEmpty {
            if let result = try? await doubaoAssess(accountName: accountName,
                                                     platform: platform,
                                                     apiKey: apiKey) {
                cacheAssessment(result)
                return result
            }
        }

        // Fallback to Ollama
        let fallback = (try? await ollamaAssess(accountName: accountName, platform: platform))
            ?? AccountAssessment(accountName: accountName,
                                 platform: platform,
                                 anxietyScore: 0.5,
                                 styleNotes: "评估失败，使用默认值",
                                 source: .ollama)
        cacheAssessment(fallback)
        return fallback
    }

    // MARK: - Doubao engine

    private func doubaoAssess(accountName: String,
                              platform: AccountPlatform,
                              apiKey: String) async throws -> AccountAssessment {
        let prompt = buildPrompt(accountName: accountName, platform: platform)
        let body: [String: Any] = [
            "model": doubaoModel,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.1,
            "max_tokens": 200
        ]
        var request = URLRequest(url: doubaoEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, _) = try await URLSession.shared.data(for: request)
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

    // MARK: - Ollama fallback

    private func ollamaAssess(accountName: String, platform: AccountPlatform) async throws -> AccountAssessment {
        let prompt = buildPrompt(accountName: accountName, platform: platform)
        let body: [String: Any] = [
            "model": ollamaModel,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 200]
        ]
        var request = URLRequest(url: ollamaEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["response"] as? String else {
            throw AssessorError.invalidResponse
        }
        return parseAssessmentResponse(content,
                                       accountName: accountName,
                                       platform: platform,
                                       source: .ollama)
    }

    // MARK: - Prompt builder

    private func buildPrompt(accountName: String, platform: AccountPlatform) -> String {
        let platformName = platform == .douyin ? "抖音" : "微信公众号"
        return """
        你是一个分析自媒体账号对读者/观众情绪影响的专家。
        请评估\(platformName)账号「\(accountName)」的内容风格对读者产生的焦虑感。
        评估维度：
        1. 内容是否制造紧迫感或恐慌
        2. 是否传递悲观/负面世界观
        3. 是否使用情绪操控手法（标题党、对立化叙事等）

        请用以下 JSON 格式回复，不要输出其他内容：
        {"score": 0.7, "notes": "简要风格描述（不超过50字）"}
        其中 score 为 0.0（完全不焦虑）到 1.0（极度焦虑），notes 为风格描述。
        """
    }

    // MARK: - Response parser

    private func parseAssessmentResponse(_ text: String,
                                         accountName: String,
                                         platform: AccountPlatform,
                                         source: AssessmentSource) -> AccountAssessment {
        let pattern = #"\{[^}]+\}"#
        guard let range = text.range(of: pattern, options: .regularExpression),
              let data = String(text[range]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let score = json["score"] as? Double else {
            return AccountAssessment(accountName: accountName,
                                     platform: platform,
                                     anxietyScore: 0.5,
                                     styleNotes: "解析失败",
                                     source: source)
        }
        let notes = json["notes"] as? String ?? ""
        return AccountAssessment(accountName: accountName,
                                 platform: platform,
                                 anxietyScore: min(max(score, 0), 1),
                                 styleNotes: notes,
                                 source: source)
    }

    // MARK: - Cache (Core Data)

    private func cachedAssessment(accountName: String, platform: AccountPlatform) -> AccountAssessment? {
        let ctx = persistence.container.viewContext
        let request = VideoAccountProfile.fetchRequest()
        request.predicate = NSPredicate(format: "accountName == %@ AND platform == %@",
                                        accountName, platform.rawValue)
        request.fetchLimit = 1
        guard let entity = (try? ctx.fetch(request))?.first,
              let lastAssessed = entity.lastAssessedAt,
              Date().timeIntervalSince(lastAssessed) < 7 * 86400 else { return nil }
        return AccountAssessment(accountName: accountName,
                                 platform: platform,
                                 anxietyScore: entity.anxietyScore,
                                 styleNotes: entity.styleNotes ?? "",
                                 source: entity.assessmentSource == "doubao" ? .doubao : .ollama)
    }

    private func cacheAssessment(_ assessment: AccountAssessment) {
        let ctx = persistence.newBackgroundContext()
        ctx.perform {
            let request = VideoAccountProfile.fetchRequest()
            request.predicate = NSPredicate(format: "accountName == %@ AND platform == %@",
                                            assessment.accountName, assessment.platform.rawValue)
            request.fetchLimit = 1
            let entity = (try? ctx.fetch(request))?.first ?? VideoAccountProfile(context: ctx)
            entity.id = entity.id ?? UUID()
            entity.accountName = assessment.accountName
            entity.platform = assessment.platform.rawValue
            entity.anxietyScore = assessment.anxietyScore
            entity.styleNotes = assessment.styleNotes
            entity.assessmentSource = assessment.source.rawValue
            entity.lastAssessedAt = Date()
            try? ctx.save()
        }
    }

    // MARK: - Errors

    public enum AssessorError: Error {
        case invalidResponse
    }
}

// MARK: - Keychain Helper (minimal)

public enum KeychainHelper {
    public static func read(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    public static func write(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}
