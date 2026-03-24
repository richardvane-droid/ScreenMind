import Foundation

// MARK: - Platform enum

public enum SMPlatform: String, Codable, Sendable {
    case mac
    case ios
}

// MARK: - Anxiety analysis result

/// Lightweight value type returned by AnxietyScorer.
public struct AnxietyResult: Sendable {
    public let score: Double          // 0.0 – 1.0
    public let dominantKeywords: [String]
    public let source: AnalysisSource  // which engine produced this score
    public let durationMs: Int         // wall-clock time of analysis

    public init(score: Double,
                dominantKeywords: [String] = [],
                source: AnalysisSource,
                durationMs: Int = 0) {
        self.score = score
        self.dominantKeywords = dominantKeywords
        self.source = source
        self.durationMs = durationMs
    }
}

public enum AnalysisSource: String, Sendable {
    case naturalLanguage   // Stage 1 fast filter
    case ollama            // Stage 2 local LLM
}

// MARK: - HRV snapshot

public struct HRVSnapshot: Sendable {
    public let sdnn: Double    // ms
    public let rmssd: Double?  // ms, optional
    public let timestamp: Date

    public init(sdnn: Double, rmssd: Double? = nil, timestamp: Date = .now) {
        self.sdnn = sdnn
        self.rmssd = rmssd
        self.timestamp = timestamp
    }
}

// MARK: - Video account assessment

public struct AccountAssessment: Sendable {
    public let accountName: String
    public let platform: AccountPlatform
    public let anxietyScore: Double    // 0.0 – 1.0
    public let styleNotes: String
    public let source: AssessmentSource

    public init(accountName: String,
                platform: AccountPlatform,
                anxietyScore: Double,
                styleNotes: String,
                source: AssessmentSource) {
        self.accountName = accountName
        self.platform = platform
        self.anxietyScore = anxietyScore
        self.styleNotes = styleNotes
        self.source = source
    }
}

public enum AccountPlatform: String, Codable, Sendable {
    case douyin       = "douyin"
    case wechatMP     = "wechat_mp"
}

public enum AssessmentSource: String, Sendable {
    case doubao
    case ollama
}

// MARK: - Relaxation suggestion value type

public struct SuggestionItem: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String?
    public let address: String?
    public let latitude: Double?
    public let longitude: Double?
    public var travelMinutes: Int?

    public init(id: UUID = UUID(),
                title: String,
                detail: String? = nil,
                address: String? = nil,
                latitude: Double? = nil,
                longitude: Double? = nil,
                travelMinutes: Int? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.travelMinutes = travelMinutes
    }
}

// MARK: - App config keys

public enum ConfigKey: String {
    case baseAnxietyThreshold    = "base_anxiety_threshold"    // Double, default 0.6
    case samplingIntervalSeconds = "sampling_interval_seconds" // Int, default 30
    case cooldownMinutes         = "cooldown_minutes"          // Int, default 5
    case doubaoAPIKey            = "doubao_api_key"            // stored in Keychain, key here is placeholder
    case appFilterMode           = "app_filter_mode"           // "whitelist" | "blacklist"
    case appFilterList           = "app_filter_list"           // JSON array of bundle IDs
    case enableIOSLayer2         = "enable_ios_layer2"         // Bool
}
