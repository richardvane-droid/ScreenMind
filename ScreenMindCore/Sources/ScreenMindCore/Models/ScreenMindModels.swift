// =============================================================================
//  ScreenMindModels.swift
//  ScreenMindCore — 跨平台共享层
// =============================================================================
//
//  【这个文件的作用】
//  这是整个 ScreenMind 项目的"数据词典"。
//  所有模块之间传递的数据结构（值类型/枚举），全部在这里定义。
//
//  【为什么单独放一个文件？】
//  Mac 端和 iOS 端都要用同一套数据格式（比如"焦虑分析结果"），
//  所以放在 ScreenMindCore 这个共享的 Swift Package 里，两端都能 import 进来用。
//
//  【部署位置】
//  ScreenMindCore/Sources/ScreenMindCore/Models/ScreenMindModels.swift
//
//  【初学者须知：struct vs class】
//  - struct（结构体）是"值类型"，赋值时会复制一份，线程安全，Swift 首选。
//  - class（类）是"引用类型"，多处持有同一份，需手动管理线程安全。
//  - 这里所有数据结构都用 struct，符合 Swift 最佳实践。
//
// =============================================================================

import Foundation   // 提供 UUID、Date 等基础类型（Apple 标准库，必须 import）

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 一、平台标识
// MARK: ──────────────────────────────────────────────────────────────────────

/// 标识当前数据来自哪个端（Mac 还是 iOS）。
///
/// 用处：Core Data 里的 AnxietyRecord 要记录"这条数据是 Mac 还是 iPhone 产生的"，
/// 存的是这个枚举的 rawValue 字符串（"mac" 或 "ios"）。
///
/// Codable：可以自动序列化成 JSON，方便日后导出数据或网络传输。
/// Sendable：告诉 Swift 编译器这个类型可以安全地在多个线程/任务之间传递。
public enum SMPlatform: String, Codable, Sendable {
    case mac   // macOS 端（MenuBar App）
    case ios   // iOS 端（iPhone App，通过 Broadcast Extension 捕获）
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 二、焦虑分析结果
// MARK: ──────────────────────────────────────────────────────────────────────

/// 焦虑评分引擎（AnxietyScorer）分析完一段屏幕文字后，返回这个结果。
///
/// 整个评分管道的"产品"：
///   屏幕截图 → OCR → AnxietyScorer → **AnxietyResult** → Core Data 存储 → 通知用户
///
/// 【字段说明】
/// - score: 0.0 表示完全不焦虑，1.0 表示极度焦虑
/// - dominantKeywords: 导致高分的关键词，如 ["失业", "危机", "崩盘"]
/// - source: 谁产生了这个分数（快速的 NL 模型 还是 深度 LLM）
/// - durationMs: 分析耗时（毫秒），用于性能监控
public struct AnxietyResult: Sendable {
    public let score: Double              // 焦虑分 0.0 – 1.0
    public let dominantKeywords: [String] // 触发高分的关键词列表
    public let source: AnalysisSource    // 分析来源（Stage 1 还是 Stage 2）
    public let durationMs: Int           // 分析耗时（毫秒）

    /// 初始化时 dominantKeywords 和 durationMs 可以不传，有默认值。
    /// 这是 Swift 的"默认参数"特性，让调用方写起来更简洁。
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

/// 焦虑分数是由哪个引擎计算出来的。
///
/// ScreenMind 采用"两阶段评分"设计：
///   Stage 1（naturalLanguage）— 用苹果 NaturalLanguage 框架做情感分析，< 10ms，每帧都跑。
///   Stage 2（ollama）— 用本地运行的 Qwen 大语言模型做深度分析，~3-8s，只在 Stage 1 判定负面时才触发。
///
/// 这样设计的好处：99% 的帧走 Stage 1 极速通过，只有真正负面内容才动用 LLM，省电省 CPU。
public enum AnalysisSource: String, Sendable {
    case naturalLanguage   // 苹果 NaturalLanguage 框架（快速情感分析，Stage 1）
    case ollama            // 本地 LLM（Qwen 2.5:3B 模型，深度分析，Stage 2）
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 三、HRV 心率变异性快照
// MARK: ──────────────────────────────────────────────────────────────────────

/// 一次心率变异性（HRV）测量的快照数据。
///
/// 【什么是 HRV？】
/// Heart Rate Variability，心率变异性。相邻两次心跳之间的时间间隔不是完全固定的，
/// 这个"变化量"反映了自主神经系统的状态：
///   - HRV 高 → 身体放松，副交感神经活跃（好的状态）
///   - HRV 低 → 身体紧张/疲劳，交感神经活跃（压力状态）
///
/// ScreenMind 用 HRV 作为"生理焦虑"的辅助指标，与屏幕内容分析配合，提升准确率。
///
/// 【SDNN 是什么？】
/// 所有 R-R 间期（心跳间隔）的标准差，单位毫秒（ms）。是最常用的 HRV 指标。
/// 正常成人静息状态约 30–70ms。
public struct HRVSnapshot: Sendable {
    public let sdnn: Double      // SDNN 值，单位毫秒（ms）。越高越放松。
    public let rmssd: Double?    // 另一种 HRV 指标（可选）。Apple Watch 主要用这个。
    public let timestamp: Date   // 这次测量的时间

    /// rmssd 是可选的（Apple Watch 不总是提供），timestamp 默认为"现在"。
    public init(sdnn: Double, rmssd: Double? = nil, timestamp: Date = .now) {
        self.sdnn = sdnn
        self.rmssd = rmssd
        self.timestamp = timestamp
    }
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 四、视频账号评估结果
// MARK: ──────────────────────────────────────────────────────────────────────

/// 对一个抖音/微信公众号账号的焦虑倾向评估结果。
///
/// 【应用场景】
/// 用户可以让 ScreenMind 评估他关注的账号：
/// "我关注的这些账号，哪些经常发焦虑性内容？"
/// 评估完后存入 Core Data 的 VideoAccountProfile 表。
public struct AccountAssessment: Sendable {
    public let accountName: String       // 账号名（如 "@某某财经"）
    public let platform: AccountPlatform // 平台（抖音 or 微信公众号）
    public let anxietyScore: Double      // 该账号内容的平均焦虑分 0.0–1.0
    public let styleNotes: String        // 对内容风格的文字描述（由 LLM 生成）
    public let source: AssessmentSource  // 评估来源

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

/// 支持的内容平台（目前 M1 阶段只支持这两个）。
public enum AccountPlatform: String, Codable, Sendable {
    case douyin    = "douyin"      // 抖音（短视频）
    case wechatMP  = "wechat_mp"   // 微信公众号（图文）
}

/// 账号评估由哪个 AI 服务完成的。
///
/// doubao：字节跳动的"豆包"大语言模型（需要 API Key，联网）。
/// ollama：本机运行的开源 LLM（离线，速度相对慢）。
public enum AssessmentSource: String, Sendable {
    case doubao  // 豆包 API（云端 LLM，快速，需网络）
    case ollama  // 本地 Ollama（离线 LLM，慢但隐私安全）
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 五、放松建议条目
// MARK: ──────────────────────────────────────────────────────────────────────

/// 当用户焦虑分超过阈值时，App 会推送放松建议。
/// 这个结构体就是一条建议的数据。
///
/// M6 扩展：建议不再只有"去某地"，还可以是：
///   - 下单健身课（Keep）
///   - 点外卖（美团/饿了么）
///   - 买电影票（猫眼）
///   - 预约到家按摩（美团到家）
///   - 买在线课程（得到）
///
/// 有 serviceConfig 的条目可以由 ComputerUseOrderAgent 自动下单。
///
/// 实现了 Identifiable（SwiftUI 列表用来区分每条记录）。
public struct SuggestionItem: Identifiable, Sendable {
    public let id: UUID              // 唯一 ID（SwiftUI 列表必须有）
    public let title: String         // 建议标题，如 "去中山公园散步"
    public let detail: String?       // 详细描述（可选）
    public let address: String?      // 地址文字，如 "长宁区中山公园路"（可选，地点类建议才有）
    public let latitude: Double?     // 纬度（可选，有地址才填）
    public let longitude: Double?    // 经度（可选，有地址才填）
    public var travelMinutes: Int?   // 从当前位置驾车所需分钟数（可选，后续由地图 API 计算）

    /// M6 新增：如果这条建议对应一项线上服务，这里记录服务平台和下单配置。
    ///
    /// 为 nil 时：纯线下建议（去公园、做冥想），不支持自动下单。
    /// 有值时：ComputerUseOrderAgent 可以读取它，打开对应平台页面完成下单。
    public let serviceConfig: ServiceOrderConfig?

    /// M6 新增：这条建议属于哪个大分类（决定在 AlertPanel 里显示在哪个区域）。
    public let category: SuggestionCategory

    /// var travelMinutes 用 var（可变）而不是 let（不可变）：
    /// 因为 travelMinutes 是后续异步计算回来后再填入的，初始化时可能是 nil。
    public init(id: UUID = UUID(),
                title: String,
                detail: String? = nil,
                address: String? = nil,
                latitude: Double? = nil,
                longitude: Double? = nil,
                travelMinutes: Int? = nil,
                category: SuggestionCategory = .place,
                serviceConfig: ServiceOrderConfig? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.travelMinutes = travelMinutes
        self.category = category
        self.serviceConfig = serviceConfig
    }
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 五-B、M6 放松建议分类枚举
// MARK: ──────────────────────────────────────────────────────────────────────

/// 放松建议的六大分类（M6 新增）。
///
/// 【产品设计说明】
/// 用户焦虑时不只想"去附近走走"，也可能想：
///   - 运动发泄（健身）
///   - 学点新东西（课程）
///   - 吃顿好的犒劳自己（外卖）
///   - 看个轻松的电影（娱乐）
///   - 约个放松服务（到家服务）
///
/// 六个分类覆盖了"放松"的主要维度，兼顾线上和线下。
///
/// Codable：可以存到 Core Data 里（以 rawValue 字符串形式存储）。
public enum SuggestionCategory: String, Codable, Sendable, CaseIterable {

    /// 地点类：去附近的公园、咖啡厅、图书馆等（线下，无需下单）
    ///
    /// 特点：需要经纬度 + 车程计算（MapKit）
    case place = "place"

    /// 健身类：Keep 课程、gym 团课、瑜伽等（线上平台预约/购买）
    ///
    /// 对应平台：Keep、超级猩猩等
    case fitness = "fitness"

    /// 课程类：在线学习放松技能，如冥想、吉他入门、烹饪等
    ///
    /// 对应平台：得到、网易公开课、Bilibili 学习区
    case course = "course"

    /// 外卖类：直接点一份好吃的犒劳自己
    ///
    /// 对应平台：美团外卖、饿了么
    case food = "food"

    /// 娱乐类：买电影票、订 KTV、订演出票等
    ///
    /// 对应平台：猫眼、大麦网
    case entertainment = "entertainment"

    /// 到家服务类：预约上门按摩、精油 SPA、家政等
    ///
    /// 对应平台：美团到家、58 到家
    case homeService = "home_service"

    /// 这个分类的中文展示名称（供 AlertPanel UI 显示）
    public var displayName: String {
        switch self {
        case .place:         return "附近地点"
        case .fitness:       return "健身运动"
        case .course:        return "学点新东西"
        case .food:          return "吃点好的"
        case .entertainment: return "娱乐放松"
        case .homeService:   return "到家服务"
        }
    }

    /// SF Symbol 图标名称（供 AlertPanel SwiftUI 显示）
    public var symbolName: String {
        switch self {
        case .place:         return "map.fill"
        case .fitness:       return "figure.run"
        case .course:        return "book.fill"
        case .food:          return "fork.knife"
        case .entertainment: return "popcorn.fill"
        case .homeService:   return "house.fill"
        }
    }
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 五-C、M6 服务平台枚举
// MARK: ──────────────────────────────────────────────────────────────────────

/// 支持自动下单的中国服务平台枚举（M6 新增）。
///
/// 【设计说明】
/// 每个 case 代表一个具体的线上服务平台。
/// ComputerUseOrderAgent 根据 ServiceProvider 知道：
///   - 该平台的 Web URL（要打开哪个网址）
///   - 搜索框的位置（用 Computer Use 输入搜索词）
///   - 套餐筛选关键词（如"性价比"、"新人优惠"）
///
/// 【为什么不用官方 App？】
/// 因为 ScreenMind 是 MenuBar 服务，没有自己的 UI。
/// 用外部浏览器（Safari/Chrome）：
///   - 浏览器已经有用户的登录状态，不需要重新登录
///   - Computer Use 可以直接截图+点击操作浏览器
///   - 支持几乎所有中国服务的 Web 版
///
/// Codable：可以序列化存到 Core Data 的 RelaxationSuggestion 表里。
public enum ServiceProvider: String, Codable, Sendable {

    // ── 健身类 ─────────────────────────────────────────────────────────────
    /// Keep：国内最大在线健身 App，有课程、直播、跑步记录。Web 版支持购买会员和课程。
    case keep          = "keep"

    // ── 课程类 ─────────────────────────────────────────────────────────────
    /// 得到：罗振宇旗下知识付费平台，有音频课、电子书、专栏。网站：dedao.cn
    case dedao         = "dedao"

    /// 网易公开课：网易旗下免费/付费课程平台，覆盖多领域。
    case wangyiKaifang = "wangyi_kaifang"

    // ── 外卖类 ─────────────────────────────────────────────────────────────
    /// 美团外卖：中国最大外卖平台。Web 版：waimai.meituan.com
    case meituanFood   = "meituan_food"

    /// 饿了么：阿里旗下外卖平台。Web 版：h5.ele.me
    case eleme         = "eleme"

    // ── 娱乐类 ─────────────────────────────────────────────────────────────
    /// 猫眼电影：国内主流电影购票平台。Web 版：maoyan.com
    case maoyan        = "maoyan"

    /// 大麦网：演出票务平台（演唱会、话剧、音乐节）。Web 版：damai.cn
    case damai         = "damai"

    // ── 到家服务类 ─────────────────────────────────────────────────────────
    /// 美团到家：美团旗下到家服务（按摩、保洁、美甲等）。
    case meituanHome   = "meituan_home"

    /// 58到家：58 同城旗下到家服务平台，家政、保洁为主。
    case wubadaojia    = "58daojia"

    // ── 通用属性 ──────────────────────────────────────────────────────────

    /// 平台的 Web 主页 URL（ComputerUseOrderAgent 会从这里导航进入）
    public var webBaseURL: String {
        switch self {
        case .keep:          return "https://www.keep.com/shop"
        case .dedao:         return "https://www.dedao.cn/course/list"
        case .wangyiKaifang: return "https://open.163.com"
        case .meituanFood:   return "https://waimai.meituan.com"
        case .eleme:         return "https://h5.ele.me"
        case .maoyan:        return "https://www.maoyan.com"
        case .damai:         return "https://www.damai.cn"
        case .meituanHome:   return "https://dj.meituan.com"
        case .wubadaojia:    return "https://www.58daojia.com"
        }
    }

    /// 平台的中文显示名称
    public var displayName: String {
        switch self {
        case .keep:          return "Keep"
        case .dedao:         return "得到"
        case .wangyiKaifang: return "网易公开课"
        case .meituanFood:   return "美团外卖"
        case .eleme:         return "饿了么"
        case .maoyan:        return "猫眼电影"
        case .damai:         return "大麦网"
        case .meituanHome:   return "美团到家"
        case .wubadaojia:    return "58到家"
        }
    }
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 五-D、M6 服务下单配置
// MARK: ──────────────────────────────────────────────────────────────────────

/// 一条服务类建议的下单配置（M6 新增）。
///
/// 当 SuggestionItem.serviceConfig 不为 nil 时，
/// ComputerUseOrderAgent 会读取这个配置来完成自动下单。
///
/// 【下单流程（由 ComputerUseOrderAgent 执行）】
/// 1. 用 NSWorkspace 打开 targetURL 到外部浏览器（Safari/Chrome）
/// 2. 浏览器已有用户登录状态（不需要重新登录）
/// 3. 在搜索框输入 searchKeyword
/// 4. 浏览套餐列表，找到 preferredPackageKeywords 描述的套餐
/// 5. 加入购物车 / 立即购买
/// 6. 停在支付确认页（不触发支付）
/// 7. 发送通知：请用户打开浏览器完成支付
///
/// Sendable + Codable：可以安全跨线程传递，也可以序列化成 JSON 存到 Core Data。
public struct ServiceOrderConfig: Sendable, Codable {

    /// 目标平台（美团/猫眼/Keep 等）
    public let provider: ServiceProvider

    /// 在平台搜索框里输入的关键词
    ///
    /// 例如：
    ///   - Keep → "瑜伽 15分钟"
    ///   - 猫眼 → "周末 上海 轻松喜剧"
    ///   - 美团外卖 → "健康沙拉"
    public let searchKeyword: String

    /// 直接跳转到的 URL（可选）。
    ///
    /// 如果平台支持搜索 URL 参数（如猫眼支持 ?q=喜剧），
    /// 可以直接构造带搜索词的 URL，跳过在搜索框里打字的步骤，更快更准确。
    ///
    /// 如果为 nil：ComputerUseOrderAgent 会先导航到 ServiceProvider.webBaseURL，
    ///             然后找搜索框，输入 searchKeyword。
    public let targetURL: String?

    /// 筛选"最优套餐"时使用的关键词数组（优先级从高到低）。
    ///
    /// ComputerUseOrderAgent 会在套餐列表里找包含这些关键词的套餐。
    /// 例如：["新人优惠", "性价比", "月卡", "体验课"]
    /// 如果第一个关键词没有命中，尝试第二个，以此类推。
    /// 全部没有命中则选第一个显示的套餐。
    public let preferredPackageKeywords: [String]

    /// 用于通知用户的服务描述（出现在"请完成支付"通知里）
    ///
    /// 例如："Keep 瑜伽月卡"、"猫眼周末电影票"
    public let serviceDescription: String

    public init(provider: ServiceProvider,
                searchKeyword: String,
                targetURL: String? = nil,
                preferredPackageKeywords: [String] = [],
                serviceDescription: String) {
        self.provider = provider
        self.searchKeyword = searchKeyword
        self.targetURL = targetURL
        self.preferredPackageKeywords = preferredPackageKeywords
        self.serviceDescription = serviceDescription
    }
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: 六、App 配置键
// MARK: ──────────────────────────────────────────────────────────────────────

/// App 所有可配置项的键名，存储在 Core Data 的 AppConfig 表里（以 key-value 形式）。
///
/// 【为什么用 enum 而不是直接写字符串？】
/// 如果直接写 "base_anxiety_threshold" 这样的字符串，很容易拼错，且不能自动补全。
/// 用 enum 的 rawValue 可以保证类型安全，IDE 也能提示。
///
/// 使用示例：
///   let key = ConfigKey.baseAnxietyThreshold.rawValue  // → "base_anxiety_threshold"
public enum ConfigKey: String {
    /// 焦虑分超过这个值就触发提醒。范围 0.0–1.0，默认 0.6（即 60%）。
    case baseAnxietyThreshold    = "base_anxiety_threshold"

    /// 多少秒采样一次屏幕（默认 30 秒）。太频繁耗电，太慢不及时。
    case samplingIntervalSeconds = "sampling_interval_seconds"

    /// 两次提醒之间至少间隔多少分钟（默认 5 分钟），防止烦扰用户。
    case cooldownMinutes         = "cooldown_minutes"

    /// 豆包 API Key。注意：实际的 Key 存在 Keychain（钥匙串）里，这里只是占位符。
    case doubaoAPIKey            = "doubao_api_key"

    /// App 过滤模式（"whitelist" 只分析白名单 App，"blacklist" 跳过黑名单 App）。
    case appFilterMode           = "app_filter_mode"

    /// 过滤列表，存 JSON 数组，每项是一个 App 的 Bundle ID，如 "com.apple.Safari"。
    case appFilterList           = "app_filter_list"

    /// 是否启用 iOS 端的 Layer 2 分析（HRV + Broadcast Extension）。
    case enableIOSLayer2         = "enable_ios_layer2"
}
