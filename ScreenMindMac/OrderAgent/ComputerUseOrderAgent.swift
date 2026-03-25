// =============================================================================
//  ComputerUseOrderAgent.swift
//  ScreenMindMac — Mac 端主应用
// =============================================================================
//
//  【里程碑 M6-Mac：Computer Use 下单代理】
//
//  【产品需求：这个文件解决什么问题？】
//  当 ScreenMind 检测到用户焦虑时，会弹出放松建议（比如"去 Keep 练瑜伽"、"点一份健康外卖"）。
//  用户点击建议后，不需要自己去打开 App、搜索、挑选套餐、加入购物车——
//  ComputerUseOrderAgent 会：
//    1. 打开外部浏览器（Safari），导航到对应服务平台
//    2. 自动搜索、筛选最佳性价比套餐
//    3. 加入购物车，停在支付确认页
//    4. 发送通知告诉用户"已帮你选好，请打开 Safari 完成支付"
//
//  【为什么用外部浏览器而不是 WebView？】
//  ScreenMind 本身是 MenuBar 服务，没有主窗口（无界面设计）。
//  外部浏览器（Safari/Chrome）的优势：
//    - 已经保存了所有平台的登录状态（Cookie），不需要重新登录
//    - 浏览器界面用户熟悉，支付流程更安全可信
//    - ScreenMind 不需要处理 WebView 安全、Cookie 隔离等复杂问题
//
//  【Computer Use 是什么技术？】
//  Computer Use = Claude AI 控制计算机的能力（截图 → 理解界面 → 点击/输入）。
//
//  本文件的实现分两个层次：
//
//    Layer 1（Swift 端）—— 本文件负责的部分：
//      - 根据 ServiceOrderConfig 构造 URL，用 NSWorkspace 打开外部浏览器
//      - 发送系统通知告知用户
//      - 提供 onOrderLaunched 回调，供 AlertPanel 更新 UI
//
//    Layer 2（Claude Agent 端）—— 外部 Cowork/Claude 实现（不在本 Swift 项目里）：
//      - 截图识别浏览器当前页面
//      - 找到搜索框、输入 searchKeyword
//      - 浏览套餐列表、根据 preferredPackageKeywords 找最优套餐
//      - 点击"立即购买"或"加购物车"
//      - 停在支付确认页
//      - 通过 NSDistributedNotificationCenter 或 URL scheme 通知 Swift 端"已就绪"
//
//  【两层之间如何通信？】
//  Swift App → Claude Agent：
//    通过 pasteboard（剪贴板）写入 JSON，包含 searchKeyword、preferredPackageKeywords 等
//    Claude Agent 读取剪贴板 JSON 后开始操作
//
//  Claude Agent → Swift App：
//    通过 NSDistributedNotificationCenter 发一个"com.screenmind.orderReady"通知
//    Swift App 收到后更新 UI，提醒用户去支付
//
//  【部署位置】
//  ScreenMindMac/OrderAgent/ComputerUseOrderAgent.swift
//  仅 Mac 端（依赖 NSWorkspace、NSPasteboard，不适用于 iOS）
//
//  【安全说明】
//  本文件不会触发任何支付动作。
//  所有支付操作必须由用户在浏览器里手动确认（这是设计上的安全底线）。
//
// =============================================================================

import Foundation  // 基础类型 + URLComponents
import AppKit      // NSWorkspace（打开 URL）、NSPasteboard（剪贴板）
import ScreenMindCore  // ServiceOrderConfig、ServiceProvider、SuggestionItem
import OSLog       // 结构化日志

private let logger = Logger(subsystem: "com.screenmind.mac", category: "OrderAgent")

// =============================================================================
// MARK: - 下单状态枚举
// =============================================================================

/// 一次下单流程的当前状态。
///
/// 供 AlertPanel（提醒浮窗）的 SwiftUI 视图实时更新 UI 状态。
///
/// 完整状态流转：
///   idle → launching → browserOpened → agentNavigating → readyForPayment → completed / failed
///
/// Sendable：Swift 并发标记，状态枚举可以安全跨线程传递。
public enum OrderFlowState: Sendable {
    /// 初始状态，没有正在进行的下单流程
    case idle

    /// 正在打开浏览器（NSWorkspace.open 已调用，等待浏览器窗口出现）
    case launching

    /// 浏览器已打开，等待 Claude Agent 开始导航
    ///
    /// 关联值：targetURL（打开的是哪个页面）
    case browserOpened(url: String)

    /// Claude Agent 正在浏览器里导航/搜索/选套餐
    ///
    /// 关联值：step（当前步骤描述，如 "正在搜索瑜伽课..."）
    case agentNavigating(step: String)

    /// Agent 已找到最优套餐并停在支付页，等待用户确认
    ///
    /// 关联值：packageName（找到的套餐名称）
    case readyForPayment(packageName: String)

    /// 流程完成（用户已支付）
    case completed

    /// 流程失败（网络问题、Agent 无法找到套餐等）
    ///
    /// 关联值：reason（失败原因说明）
    case failed(reason: String)
}

// =============================================================================
// MARK: - 下单启动结果
// =============================================================================

/// 调用 `launchOrder()` 后的立即返回结果（不包含 Agent 导航的异步结果）。
///
/// 区分"立即启动成功"和"启动失败"两种情况。
public struct OrderLaunchResult: Sendable {
    /// 是否成功打开了浏览器
    public let launched: Bool

    /// 打开的 URL（供调试）
    public let url: String

    /// 失败原因（launched=false 时有值）
    public let failureReason: String?
}

// =============================================================================
// MARK: - 核心类：ComputerUseOrderAgent
// =============================================================================

/// M6 下单代理：打开外部浏览器并写入 Agent 指令，驱动自动下单流程。
///
/// 【@MainActor 原因】
/// onStateChanged 回调供 AlertPanel（SwiftUI 视图）更新 UI，必须在主线程。
/// NSPasteboard 的读写也必须在主线程（AppKit 要求）。
@MainActor
public final class ComputerUseOrderAgent {

    // MARK: - 状态与回调 ──────────────────────────────────────────────────────

    /// 当前下单流程状态（供 AlertPanel 绑定）。
    ///
    /// 每次状态变更都会触发 onStateChanged 回调，AlertPanel 据此更新 UI。
    public private(set) var currentState: OrderFlowState = .idle

    /// 状态变更回调（供 AlertPanel SwiftUI 视图绑定）。
    ///
    /// 类型：((OrderFlowState) -> Void)?
    ///   (OrderFlowState) → Void：接受新状态，无返回值
    ///   ? 表示可选，没有绑定时什么都不做
    public var onStateChanged: ((OrderFlowState) -> Void)?

    /// 进入"等待支付"状态时的回调（单独提出来方便 AlertPanel 做明显的 UI 提示）。
    public var onReadyForPayment: ((String) -> Void)?

    // MARK: - 配置 ────────────────────────────────────────────────────────────

    /// 用于接收 Claude Agent "已就绪"通知的 NSDistributedNotification 名称。
    ///
    /// NSDistributedNotificationCenter 是 macOS 进程间通信（IPC）的一种方式：
    ///   - 发送方（Claude Agent / Cowork）：发布这个通知
    ///   - 接收方（ScreenMind Swift App）：注册监听，收到后更新状态
    ///
    /// 格式：反向域名，保证唯一性（不会和系统其他通知冲突）
    private static let agentReadyNotification = "com.screenmind.orderAgentReady"

    /// 通过剪贴板传给 Claude Agent 的 JSON key 名称。
    private static let pasteboardKey = "com.screenmind.orderConfig"

    // MARK: - 初始化 ──────────────────────────────────────────────────────────

    public init() {
        // 注册监听 Claude Agent 发来的"已就绪"通知
        // 当 Agent 在浏览器里找到最优套餐、停在支付页时，会发这个通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAgentReadyNotification(_:)),
            name: NSNotification.Name(Self.agentReadyNotification),
            object: nil
        )

        logger.info("ComputerUseOrderAgent 初始化完成，监听 \(Self.agentReadyNotification)")
    }

    deinit {
        // 销毁前取消监听（防止悬空观察者导致崩溃）
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 公开方法：启动下单 ──────────────────────────────────────────────

    /// 启动一个放松建议的下单流程。
    ///
    /// 调用后立即返回（不阻塞主线程），后续状态通过 onStateChanged 回调推送。
    ///
    /// 完整流程：
    ///   1. 检查 suggestion.serviceConfig 不为 nil（有下单配置才能执行）
    ///   2. 构造目标 URL（带搜索词的深链接）
    ///   3. 把下单配置写入剪贴板（JSON 格式，Claude Agent 会读取）
    ///   4. 用 NSWorkspace 打开 URL 到外部浏览器
    ///   5. 更新状态为 .browserOpened
    ///   6. 发系统通知告知用户"正在帮你选套餐"
    ///   7. 等待 Agent 发来 agentReadyNotification（状态变为 .readyForPayment）
    ///
    /// - Parameter suggestion: 要执行下单的建议条目（必须有 serviceConfig）
    /// - Returns: OrderLaunchResult，说明是否成功打开浏览器
    @discardableResult
    public func launchOrder(for suggestion: SuggestionItem) async -> OrderLaunchResult {
        // ── 前置检查：必须有 serviceConfig ──────────────────────────────────
        guard let config = suggestion.serviceConfig else {
            let reason = "建议条目没有 serviceConfig，无法下单（建议类型可能是纯线下地点）"
            logger.warning("\(reason)")
            updateState(.failed(reason: reason))
            return OrderLaunchResult(launched: false, url: "", failureReason: reason)
        }

        // ── 步骤 1：更新状态为"启动中" ──────────────────────────────────────
        updateState(.launching)
        logger.info("开始下单流程: \(config.serviceDescription) via \(config.provider.displayName)")

        // ── 步骤 2：构造目标 URL ─────────────────────────────────────────────
        let targetURLString = buildTargetURL(config: config)
        guard let url = URL(string: targetURLString) else {
            let reason = "URL 构造失败: \(targetURLString)"
            logger.error("\(reason)")
            updateState(.failed(reason: reason))
            return OrderLaunchResult(launched: false, url: targetURLString, failureReason: reason)
        }

        // ── 步骤 3：把配置 JSON 写入剪贴板（供 Claude Agent 读取）────────────
        writeConfigToPasteboard(config: config, suggestionTitle: suggestion.title)

        // ── 步骤 4：打开外部浏览器 ───────────────────────────────────────────
        // NSWorkspace.shared.open(url)：用系统默认浏览器打开 URL
        // 这是 macOS 最简单、最兼容的"打开网页"方式
        let opened = NSWorkspace.shared.open(url)

        guard opened else {
            let reason = "NSWorkspace 无法打开 URL（浏览器可能被限制）"
            logger.error("\(reason)")
            updateState(.failed(reason: reason))
            return OrderLaunchResult(launched: false, url: targetURLString, failureReason: reason)
        }

        // ── 步骤 5：更新状态为"浏览器已打开" ────────────────────────────────
        updateState(.browserOpened(url: targetURLString))
        logger.info("浏览器已打开: \(targetURLString)")

        // ── 步骤 6：发送"正在处理"通知给用户 ───────────────────────────────
        // 告诉用户 ScreenMind 正在帮他选套餐，不要手动操作浏览器
        await postUserNotification(
            title: "ScreenMind 正在帮你选套餐",
            body: "正在 \(config.provider.displayName) 上搜索"\(config.serviceDescription)"，" +
                  "找到最优方案后会通知你去支付。"
        )

        logger.info("等待 Claude Agent 完成导航（监听 \(Self.agentReadyNotification)）")

        // 返回启动成功（后续 Agent 导航状态通过通知回调推送）
        return OrderLaunchResult(launched: true, url: targetURLString, failureReason: nil)
    }

    /// 取消当前进行中的下单流程（用户点击取消）。
    public func cancelOrder() {
        logger.info("用户取消下单，当前状态: \(String(describing: self.currentState))")
        updateState(.idle)
    }

    // MARK: - 内部：状态更新 ──────────────────────────────────────────────────

    /// 更新当前状态并触发回调。
    ///
    /// 这个方法确保所有状态变更都经过统一的日志记录和回调触发，
    /// 避免遗漏某些状态变更的通知。
    private func updateState(_ newState: OrderFlowState) {
        currentState = newState
        onStateChanged?(newState)

        // 如果是"等待支付"状态，额外触发专用回调
        if case .readyForPayment(let packageName) = newState {
            onReadyForPayment?(packageName)
        }
    }

    // MARK: - 内部：URL 构造 ──────────────────────────────────────────────────

    /// 根据 ServiceOrderConfig 构造目标 URL。
    ///
    /// 优先使用 config.targetURL（精确深链接），
    /// 如果没有，就在平台主页 URL 后面附加搜索参数。
    ///
    /// 【URL 编码说明】
    /// 中文字符不能直接放在 URL 里（HTTP 规范限制），
    /// 需要做 percent-encoding，把中文转成 %XX%XX 格式。
    /// `addingPercentEncoding(withAllowedCharacters:)` 负责这个工作。
    ///
    /// - Parameter config: 服务下单配置
    /// - Returns: 可以直接传给 NSWorkspace.open 的 URL 字符串
    private func buildTargetURL(config: ServiceOrderConfig) -> String {
        // 如果有精确目标 URL，直接用（最准确的路径）
        if let target = config.targetURL, !target.isEmpty {
            return target
        }

        // 没有精确 URL：根据平台特性构造带搜索词的 URL
        let baseURL = config.provider.webBaseURL

        // 对搜索词进行 URL 编码（中文 → %E5%86%A5% 格式）
        // allowedCharacters: .urlQueryAllowed 允许字母数字 + 常见符号，但会编码中文和特殊字符
        let encodedKeyword = config.searchKeyword
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.searchKeyword

        // 根据平台的搜索 URL 格式构造 URL
        // 每个平台的搜索参数名不一样（q=、keyword=、search=），这里做一一对应
        switch config.provider {
        case .keep:
            // Keep 搜索 URL：https://www.keep.com/shop?keyword=瑜伽
            return "\(baseURL)?keyword=\(encodedKeyword)"

        case .dedao:
            // 得到搜索：https://www.dedao.cn/course/list?q=冥想
            return "\(baseURL)?q=\(encodedKeyword)"

        case .wangyiKaifang:
            // 网易公开课搜索：https://open.163.com/search/#q=冥想
            return "\(baseURL)/search/#q=\(encodedKeyword)"

        case .meituanFood:
            // 美团外卖搜索：直接到搜索页（移动端格式，PC 端支持）
            return "https://waimai.meituan.com/waimai/search?keyword=\(encodedKeyword)"

        case .eleme:
            // 饿了么搜索
            return "https://h5.ele.me/search/?kw=\(encodedKeyword)"

        case .maoyan:
            // 猫眼电影搜索：https://www.maoyan.com/search?query=喜剧
            return "https://www.maoyan.com/search?query=\(encodedKeyword)"

        case .damai:
            // 大麦网搜索：https://search.damai.cn/search.html?keyword=演唱会
            return "https://search.damai.cn/search.html?keyword=\(encodedKeyword)"

        case .meituanHome:
            // 美团到家搜索
            return "https://dj.meituan.com/?keyword=\(encodedKeyword)"

        case .wubadaojia:
            // 58到家搜索
            return "https://www.58daojia.com/search?keyword=\(encodedKeyword)"
        }
    }

    // MARK: - 内部：剪贴板通信 ────────────────────────────────────────────────

    /// 把下单配置写入系统剪贴板，供 Claude Agent 读取。
    ///
    /// 【为什么用剪贴板通信？】
    /// Claude Agent（Cowork）运行在独立进程里，和 ScreenMind Swift App 不在同一进程。
    /// 进程间通信（IPC）有很多方式：
    ///   - 剪贴板（最简单，但只能单向）
    ///   - Unix Domain Socket（复杂但双向）
    ///   - NSDistributedNotificationCenter（适合通知，不适合大数据）
    ///   - 共享文件（磁盘读写）
    ///
    /// 这里用剪贴板是因为：
    ///   1. 实现最简单（几行代码）
    ///   2. 数据量小（就是一段 JSON）
    ///   3. Claude Agent 原生支持"读取剪贴板"操作
    ///
    /// 写入的内容格式（JSON）：
    ///   {
    ///     "action": "screenmind_order",
    ///     "provider": "keep",
    ///     "searchKeyword": "瑜伽 15分钟",
    ///     "preferredPackageKeywords": ["新人优惠", "月卡"],
    ///     "serviceDescription": "Keep 瑜伽月卡"
    ///   }
    ///
    /// - Parameters:
    ///   - config: 服务下单配置
    ///   - suggestionTitle: 建议条目标题（附加到 JSON，方便 Agent 理解上下文）
    private func writeConfigToPasteboard(config: ServiceOrderConfig, suggestionTitle: String) {
        // 构造 JSON 字典
        let dict: [String: Any] = [
            "action": "screenmind_order",             // 固定标识，Agent 用来区分是 ScreenMind 发的指令
            "provider": config.provider.rawValue,     // 平台标识符
            "displayName": config.provider.displayName, // 平台中文名（方便 Agent 日志）
            "searchKeyword": config.searchKeyword,    // 搜索词
            "preferredPackageKeywords": config.preferredPackageKeywords, // 套餐筛选关键词数组
            "serviceDescription": config.serviceDescription, // 服务描述
            "suggestionTitle": suggestionTitle,       // 建议标题
            "timestamp": ISO8601DateFormatter().string(from: Date()) // 时间戳（防止 Agent 读到旧数据）
        ]

        // JSON 序列化：把 Swift 字典转成 JSON 字符串
        // JSONSerialization：Apple 标准库提供的 JSON 工具
        // .prettyPrinted：生成有缩进的可读格式（方便 Agent 调试）
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict,
                                                         options: .prettyPrinted),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("剪贴板 JSON 序列化失败")
            return
        }

        // 写入系统剪贴板
        // NSPasteboard.general：系统通用剪贴板（Cmd+C/V 用的那个）
        // clearContents()：先清空旧内容，避免混入之前的数据
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(jsonString, forType: .string)

        logger.info("下单配置已写入剪贴板 (\(jsonString.count) 字符)")
    }

    // MARK: - 内部：接收 Agent 就绪通知 ──────────────────────────────────────

    /// 收到 Claude Agent 发来的"已找到套餐，停在支付页"通知后的处理。
    ///
    /// 通知的 userInfo 里包含：
    ///   - "packageName": String  找到的套餐名称
    ///   - "price": String        套餐价格（可选）
    ///
    /// @objc 是因为 NotificationCenter.addObserver 的 selector 需要是 Objective-C 兼容的方法。
    @objc private func handleAgentReadyNotification(_ notification: Notification) {
        // 从通知里提取套餐名称
        let packageName = (notification.userInfo?["packageName"] as? String)
            ?? "最优套餐"  // Agent 没传名称时的默认显示文字

        let price = notification.userInfo?["price"] as? String

        let packageDisplay = price != nil ? "\(packageName)（¥\(price!)）" : packageName

        logger.notice("Agent 通知：已找到套餐，等待用户支付。套餐=\(packageDisplay)")

        // 更新状态为"等待支付"
        updateState(.readyForPayment(packageName: packageDisplay))

        // 发送系统通知，提醒用户去浏览器完成支付
        Task {
            await postUserNotification(
                title: "已帮你选好套餐，请完成支付 ✅",
                body: "已选择"\(packageDisplay)"，请打开 Safari 完成支付确认。ScreenMind 不会替你支付。"
            )
        }
    }

    // MARK: - 内部：发送系统通知 ──────────────────────────────────────────────

    /// 向用户发送一条 UNUserNotification 系统通知。
    ///
    /// 这里直接用 UserNotifications 框架（UNUserNotificationCenter），
    /// 不走 NotificationManager，因为 OrderAgent 是独立组件，
    /// 不需要 AnxietyPipeline 的提醒逻辑（不涉及阈值、冷却等）。
    ///
    /// - Parameters:
    ///   - title: 通知标题（加粗显示）
    ///   - body: 通知正文
    private func postUserNotification(title: String, body: String) async {
        // 导入 UserNotifications 框架（如果在文件顶部 import UserNotifications，这里就不需要）
        // 为了不增加文件依赖，这里用动态导入方式
        // 实际使用时在文件顶部加 import UserNotifications 即可

        // 注：完整实现需要 import UserNotifications
        // 当前先通过 OSLog 记录，实际接入时替换为 UNMutableNotificationContent
        logger.notice("📱 用户通知 → \(title): \(body)")

        // TODO: 完整实现如下（需在文件顶部 import UserNotifications）：
        //
        // let content = UNMutableNotificationContent()
        // content.title = title
        // content.body = body
        // content.sound = .default
        //
        // let request = UNNotificationRequest(
        //     identifier: "com.screenmind.orderAgent.\(UUID().uuidString)",
        //     content: content,
        //     trigger: nil  // nil = 立即发送
        // )
        // try? await UNUserNotificationCenter.current().add(request)
    }
}
