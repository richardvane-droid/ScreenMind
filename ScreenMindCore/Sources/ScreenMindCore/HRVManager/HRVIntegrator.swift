// =============================================================================
//  HRVIntegrator.swift
//  ScreenMindCore — 跨平台共享层
// =============================================================================
//
//  【里程碑 M4：HealthKit HRV 接入 + 动态阈值引擎】
//
//  【产品需求：这个文件解决什么问题？】
//  M3 阶段的焦虑阈值是"纯文本驱动"的：
//    动态阈值 = 最近 20 帧均值 + 0.15（只看屏幕内容）
//
//  M4 阶段加入"身体信号"：
//    最终阈值 = 文本驱动阈值 × HRV乘数
//
//  什么是"HRV乘数"？
//    当你今天 HRV 很低（身体本来就紧张），
//    乘数 < 1.0 → 阈值降低 → ScreenMind 更容易提醒你休息。
//
//    当你今天 HRV 很高（身体放松），
//    乘数 > 1.0 → 阈值升高 → 不那么容易触发（你能承受更多信息）。
//
//  【完整 M4 公式】
//  ┌────────────────────────────────────────────────────────────────────┐
//  │  最终阈值 = M3文本阈值 × HRV乘数                                    │
//  │  原始乘数 = clamp(当前SDNN / 30天基线SDNN, 0.4, 1.6)               │
//  │                                                                    │
//  │  新鲜度降级（4级）：                                                │
//  │  Level 1: HRV < 1小时前  → 完整乘数（权重 100%）                   │
//  │  Level 2: HRV 1–4小时前  → 向1.0靠拢（权重 70%）                   │
//  │  Level 3: HRV 4–24小时前 → 向1.0靠拢（权重 30%）                   │
//  │  Level 4: 无 HRV 数据     → 乘数 = 1.0（阈值不变）                  │
//  │                                                                    │
//  │  "向1.0靠拢"公式：blended = w × rawMultiplier + (1-w) × 1.0       │
//  │  例：rawMultiplier=0.6, weight=0.7 → 0.7×0.6 + 0.3×1.0 = 0.72   │
//  └────────────────────────────────────────────────────────────────────┘
//
//  【数据流（M4 更新后）】
//  HealthKit（Apple Watch/iPhone）
//       ↓ HRVIntegrator.pollOnce()（每 5 分钟）
//  HRVSnapshot（sdnn, timestamp）
//       ↓ 缓存到 lastSnapshot
//  currentMultiplier（实时计算，含新鲜度降级）
//       ↓ AnxietyPipeline.computeDynamicThreshold()
//  最终阈值 = M3阈值 × currentMultiplier
//
//  【同一 Swift Package Target 内不需要 import 自己】
//  HRVIntegrator 和 HRVManager 在同一个 target（ScreenMindCore）里，
//  Swift 编译器会自动让它们互相可见，不需要任何 import 语句。
//
//  【部署位置】
//  ScreenMindCore/Sources/ScreenMindCore/HRVManager/HRVIntegrator.swift
//
// =============================================================================

import Foundation  // 提供 Date、TimeInterval、Task 等基础类型
import HealthKit   // 苹果健康数据框架（间接通过 HRVManager 使用）

// =============================================================================
// MARK: - HRV 新鲜度等级（枚举）
// =============================================================================

/// HRV 数据的新鲜度等级（决定乘数权重）。
///
/// HealthKit 的 HRV 不是实时的：Apple Watch 主要在睡眠时或休息时测量，
/// 所以最近一条 HRV 数据可能是几小时甚至几十小时前的。
///
/// 数据越旧，可信度越低，我们对它的信任（权重）也应该越低：
///   新鲜  → 完全信任 → 乘数 = 原始值（0.4–1.6）
///   陈旧  → 不信任   → 乘数 = 1.0（不调整阈值）
///   中间状态 → 按比例向 1.0 靠拢
public enum HRVFreshnessLevel: Int, CustomStringConvertible {

    /// Level 1：< 1 小时前测量，完全信任（权重 1.0）
    case fresh       = 1

    /// Level 2：1–4 小时前测量，大部分信任（权重 0.7）
    case moderate    = 2

    /// Level 3：4–24 小时前测量，仅轻度参考（权重 0.3）
    case stale       = 3

    /// Level 4：无 HRV 数据，或超过 24 小时，完全不信任（权重 0.0，乘数 = 1.0）
    case unavailable = 4

    // ── 权重（blendWeight） ──────────────────────────────────────────────

    /// 混合权重：决定"原始乘数"和"中性值 1.0"之间的比例。
    ///
    /// 混合公式：blendedMultiplier = weight × rawMultiplier + (1 - weight) × 1.0
    ///
    /// 数值示例（rawMultiplier = 0.6，代表今天压力大 HRV 低）：
    ///   fresh:      1.0 × 0.6 + 0.0 × 1.0 = 0.60（完全使用原始乘数）
    ///   moderate:   0.7 × 0.6 + 0.3 × 1.0 = 0.72（轻微向中性靠拢）
    ///   stale:      0.3 × 0.6 + 0.7 × 1.0 = 0.88（大幅向中性靠拢）
    ///   unavailable: 0.0 × 0.6 + 1.0 × 1.0 = 1.0（完全中性，不调整阈值）
    public var blendWeight: Double {
        switch self {
        case .fresh:       return 1.0
        case .moderate:    return 0.7
        case .stale:       return 0.3
        case .unavailable: return 0.0
        }
    }

    /// 供调试窗口显示的文字描述。
    public var description: String {
        switch self {
        case .fresh:       return "L1:新鲜(<1h)"
        case .moderate:    return "L2:一般(1-4h)"
        case .stale:       return "L3:陈旧(4-24h)"
        case .unavailable: return "L4:无数据"
        }
    }

    /// 根据"HRV 测量距现在的小时数"判断新鲜度等级。
    ///
    /// - Parameter hoursAgo: 距现在多少小时（可以是小数，如 1.5 = 1小时30分钟）
    /// - Returns: 对应的 HRVFreshnessLevel
    public static func classify(hoursAgo: Double) -> HRVFreshnessLevel {
        // Swift 的 switch + 范围匹配：..< 是半开区间，不包含上界
        switch hoursAgo {
        case ..<1:    return .fresh        // 不足 1 小时
        case 1..<4:   return .moderate     // 1 小时以上、不足 4 小时
        case 4..<24:  return .stale        // 4 小时以上、不足 24 小时
        default:      return .unavailable  // 24 小时以上（或负数，理论上不应该发生）
        }
    }
}

// =============================================================================
// MARK: - HRVIntegrator：M4 核心类
// =============================================================================

/// M4 核心：HealthKit HRV 后台轮询器 + 动态阈值乘数提供者。
///
/// 【职责】
///   1. 每 5 分钟向 HealthKit 请求最新 HRV 数据
///   2. 每 24 小时刷新 30 天 SDNN 基线（并持久化到 Core Data）
///   3. App 重启时从 Core Data 恢复上次保存的基线
///   4. 根据数据新鲜度计算混合 HRV 乘数（currentMultiplier）
///   5. 供 AnxietyPipeline 调用：adjustedThreshold(base:) = base × currentMultiplier
///
/// 【设计选择：Task 循环 vs Timer】
///   macOS 传统方法是 Timer，但 Timer 和 Swift Concurrency (async/await) 兼容性差。
///   这里用 Swift 原生方式：在 Task 内使用 Task.sleep() 做循环定时。
///   好处：
///     - 可以直接 await 异步函数（不用 dispatch 或回调地狱）
///     - pollingTask.cancel() 彻底停止轮询（Timer 容易忘记 invalidate()）
///
/// 【@unchecked Sendable 说明】
///   HRVManager 内部的 HKHealthStore 不是标准 Sendable，
///   但苹果文档保证 HKHealthStore 内部是线程安全的。
///   HRVIntegrator 的 lastSnapshot 和 localBaseline30d 只在 Task（串行）里修改，
///   我们自己承诺线程安全，用 @unchecked 绕过编译器检查。
public final class HRVIntegrator: @unchecked Sendable {

    // MARK: - 可配置参数 ────────────────────────────────────────────────────

    /// HRV 轮询间隔（秒）。默认 300 秒 = 5 分钟。
    ///
    /// 为什么是 5 分钟？
    ///   Apple Watch 几小时才测一次 HRV，每 5 分钟轮询已经足够，更频繁没意义。
    public var pollingInterval: TimeInterval = 300

    /// 基线刷新间隔（秒）。默认 86400 秒 = 24 小时。
    ///
    /// 86400 = 60 × 60 × 24（每天一次刷新基线）
    public var baselineRefreshInterval: TimeInterval = 86400

    // MARK: - 内部组件 ──────────────────────────────────────────────────────

    /// HRV 数据读取器（封装 HealthKit 低层 API）。
    private let hrvManager = HRVManager()

    /// Core Data 存储控制器（用于持久化 HRV 基线）。
    private let persistence = PersistenceController.shared

    // MARK: - 内部状态 ──────────────────────────────────────────────────────

    /// 最近一次成功获取的 HRV 快照（包含 sdnn 值和测量时间戳）。
    ///
    /// nil 表示：
    ///   - App 刚启动，还没有完成第一次轮询
    ///   - 用户没有 Apple Watch 或 HealthKit 权限被拒绝
    private var lastSnapshot: HRVSnapshot?

    /// 当前缓存的 30 天基线 SDNN（毫秒）。
    ///
    /// 初始值 30.0ms 和 HRVManager 默认值保持一致。
    /// App 重启时会从 Core Data 恢复，pollOnce 成功后会从 HealthKit 刷新。
    ///
    /// 【didSet 的作用】
    /// 每次基线值更新时，自动同步给 HRVManager，
    /// 确保 dynamicMultiplier() 使用最新基线计算。
    private var localBaseline30d: Double = 30.0 {
        didSet {
            // localBaseline30d 改变 → 同步给 HRVManager 的内部基线
            // 这样 dynamicMultiplier(currentSDNN:) 就会用新基线
            hrvManager.setBaseline30d(localBaseline30d)
        }
    }

    /// 上一次刷新 30 天基线的时间。nil 表示从未刷新过。
    private var lastBaselineRefresh: Date?

    /// 轮询任务句柄（用于在 stopPolling() 时取消任务）。
    private var pollingTask: Task<Void, Never>?

    // MARK: - 外部回调 ────────────────────────────────────────────────────────

    /// HRV 数据更新回调（M9 新增）。
    ///
    /// 每次 pollOnce() 成功拿到新的 HRV 快照后触发，
    /// 供 StatusBarController 把 HRV 数据推送给 WebMonitorBroadcaster，
    /// 进而在副屏 Dashboard 的 HRV 折线图上实时更新。
    ///
    /// 参数说明：
    ///   - 第一个 Double：SDNN（毫秒），心率变异性标准差，是 HealthKit 提供的指标
    ///   - 第二个 Double：RMSSD（毫秒），相邻心跳差均方根
    ///     HealthKit SDNN 接口不直接提供 RMSSD，此处传 0.0 占位，
    ///     未来如果接入 RMSSD 专用查询可在这里更新
    ///
    /// 使用示例（StatusBarController.setupPipelineCallbacks()）：
    ///   hrvIntegrator.onHRVUpdate = { sdnn, rmssd in
    ///       webMonitor.recordHRV(sdnn: sdnn, rmssd: rmssd)
    ///   }
    ///
    /// 【为什么用闭包而不是 delegate？】
    ///   闭包比协议/委托更简洁，适合单一回调场景。
    ///   多个观察者场景才考虑 NotificationCenter 或 Combine。
    public var onHRVUpdate: ((Double, Double) -> Void)?

    // MARK: - 初始化 ────────────────────────────────────────────────────────

    /// 初始化 HRVIntegrator，从 Core Data 恢复上次保存的基线。
    ///
    /// 【为什么在 init() 里恢复基线？】
    /// App 冷启动时 HealthKit 刷新是异步的（需要 2–5 秒）。
    /// 如果第一次轮询前有用户内容触发评分，需要一个合理的初始基线。
    /// Core Data 里存有上次关闭 App 前的最新基线，直接读出来用。
    public init() {
        restoreBaselineFromCoreData()
    }

    // MARK: - 公开方法：启动 / 停止轮询 ──────────────────────────────────

    /// 启动 HRV 后台轮询（App 启动时调用一次）。
    ///
    /// 调用时机：StatusBarController.init() 里的 Task { } 里调用。
    ///
    /// 轮询逻辑：
    ///   1. 立刻执行一次（冷启动时马上拿数据，不等 5 分钟）
    ///   2. 进入 while 循环：等 pollingInterval 秒 → 再次轮询 → 重复
    ///   3. 每次轮询时，如果基线超过 24h 未刷新，也顺便刷新基线
    public func startPolling() {
        pollingTask?.cancel() // 防止重复启动：先取消可能存在的旧任务

        // Task(priority: .utility) 创建一个后台低优先级任务
        // .utility 代表"实用优先级"：不影响 UI，但不会被饿死
        // [weak self]：防止 HRVIntegrator 实例被 Task 强持有（循环引用）
        pollingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            // 立刻执行第一次（不等待 5 分钟，冷启动时马上有数据）
            await self.pollOnce()

            // 主循环：每 pollingInterval 秒执行一次
            // Task.isCancelled 是 Swift Concurrency 的标准取消检测点
            while !Task.isCancelled {
                // Task.sleep(for:) 是 async/await 风格的等待，不阻塞线程
                // try? 因为任务被取消时 sleep 会抛出 CancellationError，我们忽略它
                try? await Task.sleep(for: .seconds(self.pollingInterval))

                // sleep 结束后再次检查取消状态（取消可能发生在 sleep 期间）
                guard !Task.isCancelled else { break }

                await self.pollOnce()
            }
        }
    }

    /// 停止 HRV 轮询。
    ///
    /// 调用时机：StatusBarController.stopMonitoring() 时（App 主动停止监控）。
    /// cancel() 是"协作式取消"（cooperative cancellation）：
    ///   只是设置了取消标志，Task 在下一个 isCancelled 检查点响应并退出。
    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - 公开计算属性：当前 HRV 乘数 ───────────────────────────────

    /// 当前 HRV 动态乘数（范围大约在 0.4–1.6 之间，越旧越接近 1.0）。
    ///
    /// 这是 AnxietyPipeline 调整阈值的关键数值：
    ///   finalThreshold = baseThreshold × currentMultiplier
    ///
    /// 计算步骤：
    ///   1. 如果 lastSnapshot 为 nil → 返回 1.0（Level 4，无数据）
    ///   2. 计算快照年龄（小时）
    ///   3. 判断新鲜度等级（Level 1/2/3/4）
    ///   4. 用 HRVManager.dynamicMultiplier() 计算原始乘数（基于 SDNN / 基线）
    ///   5. 用新鲜度权重混合：blended = weight × raw + (1 - weight) × 1.0
    public var currentMultiplier: Double {
        // ── Level 4：无数据 ──────────────────────────────────────────────
        guard let snapshot = lastSnapshot else {
            return 1.0 // 没有 HRV 数据，不调整阈值
        }

        // ── 计算数据年龄 ──────────────────────────────────────────────────
        // timeIntervalSince 返回秒数，除以 3600 得小时数
        let ageHours = Date().timeIntervalSince(snapshot.timestamp) / 3600

        // ── 判断新鲜度等级 ────────────────────────────────────────────────
        let freshness = HRVFreshnessLevel.classify(hoursAgo: ageHours)

        // Level 4：虽然有快照但已经超过 24 小时，退回中性
        guard freshness != .unavailable else { return 1.0 }

        // ── 计算原始乘数 ──────────────────────────────────────────────────
        // HRVManager.dynamicMultiplier() 内部使用 localBaseline30d（通过 setBaseline30d 同步）
        // 返回值已经 clamp 在 [0.4, 1.6] 区间
        let rawMultiplier = hrvManager.dynamicMultiplier(currentSDNN: snapshot.sdnn)

        // ── 按新鲜度权重混合 ──────────────────────────────────────────────
        // 公式：blended = weight × raw + (1 - weight) × 1.0
        // 等价于：blended = 1.0 + weight × (raw - 1.0)
        // 当 weight = 1.0：完全用 raw（新鲜数据）
        // 当 weight = 0.0：完全用 1.0（无调整）
        let weight = freshness.blendWeight
        return weight * rawMultiplier + (1.0 - weight) * 1.0
    }

    /// 当前 HRV 数据的新鲜度等级（供调试窗口显示用）。
    public var currentFreshnessLevel: HRVFreshnessLevel {
        guard let snapshot = lastSnapshot else { return .unavailable }
        let ageHours = Date().timeIntervalSince(snapshot.timestamp) / 3600
        return HRVFreshnessLevel.classify(hoursAgo: ageHours)
    }

    /// 最近一次 HRV 快照（供调试/统计使用）。
    /// nil 表示还没有拿到过 HRV 数据。
    public var latestSnapshot: HRVSnapshot? { lastSnapshot }

    // MARK: - 公开方法：阈值调整 ───────────────────────────────────────

    /// 把 M3 文本阈值乘以 HRV 乘数，返回最终阈值。
    ///
    /// 调用方：AnxietyPipeline.computeDynamicThreshold()
    ///
    /// 完整示例：
    ///   - M3 文本阈值 = 0.65（近 20 帧均值 0.50 + 偏移 0.15）
    ///   - 今日 HRV SDNN = 20ms，基线 = 35ms
    ///   - 原始乘数 = clamp(20/35, 0.4, 1.6) = clamp(0.571, ...) = 0.571
    ///   - HRV 测量 2 小时前，freshness = .moderate，weight = 0.7
    ///   - blended = 0.7 × 0.571 + 0.3 × 1.0 = 0.700
    ///   - 最终阈值 = 0.65 × 0.700 = 0.455 → clamp 到 [0.35, 0.90] = 0.455
    ///   → ScreenMind 对焦虑内容更敏感（阈值从 0.65 降到 0.455）✓
    ///
    /// 【最终阈值范围约束 [0.35, 0.90]】
    ///   最低 0.35：极端低 HRV + 极低文本阈值叠加时，不让阈值降到 0
    ///   最高 0.90：即使 HRV 极高，也不让阈值高到"什么都不提醒"
    ///
    /// - Parameter base: M3 计算出的文本驱动基础阈值（已经是 [0.45, 0.85]）
    /// - Returns: 应用 HRV 调整后的最终阈值（钳位在 [0.35, 0.90]）
    public func adjustedThreshold(_ base: Double) -> Double {
        let adjusted = base * currentMultiplier
        // 双重钳位：先取下限，再取上限
        return min(max(adjusted, 0.35), 0.90)
    }

    // MARK: - 公开方法：HealthKit 权限申请 ────────────────────────────

    /// 申请 HealthKit 数据读取权限（弹出系统授权对话框）。
    ///
    /// 调用时机：StatusBarController.init() → Task { await hrvIntegrator.requestAuthorization() }
    ///
    /// 失败（HealthKit 不可用，比如没有 Apple Watch）时静默忽略。
    /// 没有权限时，后续的 pollOnce() 会静默失败，currentMultiplier 保持 1.0。
    public func requestAuthorization() async {
        // try? 把可能抛出的错误转换为 nil（失败不崩溃）
        try? await hrvManager.requestAuthorization()
    }

    // MARK: - 私有：单次轮询 ────────────────────────────────────────────

    /// 执行一次完整的 HRV 数据获取和刷新。
    ///
    /// 步骤 1：判断基线是否需要刷新（超过 24h 或从未刷新过）
    ///   → 调用 HRVManager.refreshBaseline() → 更新 localBaseline30d → 存 Core Data
    ///
    /// 步骤 2：获取最新 HRV 快照
    ///   → 调用 HRVManager.latestHRV() → 更新 lastSnapshot
    ///
    /// 所有 HealthKit 操作都用 try?（失败静默忽略，不崩溃）。
    private func pollOnce() async {
        // ── 步骤 1：是否需要刷新 30 天基线 ────────────────────────────
        let needsRefresh: Bool = {
            guard let last = lastBaselineRefresh else { return true } // 从未刷新过
            return Date().timeIntervalSince(last) >= baselineRefreshInterval
        }()

        if needsRefresh {
            do {
                // refreshBaseline() 内部用 HKStatisticsQuery 计算 30 天均值
                // 并更新 HRVManager.baseline30d（私有属性）
                try await hrvManager.refreshBaseline()
                lastBaselineRefresh = Date() // 记录本次刷新时间

                // refreshBaseline 成功后，通过 getBaseline30d() 获取新基线值
                // 并更新 localBaseline30d（didSet 会同步给 HRVManager）
                localBaseline30d = hrvManager.getBaseline30d()

                // 持久化到 Core Data（App 重启后可以恢复）
                saveBaselineToCoreData(value: localBaseline30d)
            } catch {
                // 常见失败原因：HealthKit 未授权、无数据、模拟器不支持
                // 静默跳过，保留上次的 localBaseline30d
            }
        }

        // ── 步骤 2：获取最新 HRV 快照 ─────────────────────────────────
        do {
            // latestHRV() 从 HealthKit 查最近一次 HRV 测量记录（可能是几小时前的）
            let snapshot = try await hrvManager.latestHRV()
            lastSnapshot = snapshot // 更新缓存（currentMultiplier 下次访问会用新快照）

            // M9 新增：拿到新快照后触发 onHRVUpdate 回调，
            // 通知 StatusBarController → WebMonitorBroadcaster → Dashboard HRV 折线图
            // 注意：HealthKit SDNN 接口不直接提供 RMSSD，第二个参数传 0.0 占位
            // 如果后续接入 RMSSD 专用 HKQuantityType，在这里替换 0.0 即可
            onHRVUpdate?(snapshot.sdnn, 0.0)
        } catch {
            // 失败原因：没有 Apple Watch、没有 HealthKit 数据、权限被拒绝
            // 保留旧快照（如果有的话），currentMultiplier 会用旧快照的新鲜度计算
        }
    }

    // MARK: - 私有：Core Data 持久化 ──────────────────────────────────────

    /// 把 30 天基线保存到 Core Data HRVBaseline 实体。
    ///
    /// 【为什么要持久化基线而不是每次重启都从 HealthKit 重新计算？】
    /// 1. App 启动时 HealthKit 权限检查是异步的（需要 1–3 秒）
    /// 2. 在第一次轮询完成前，用 Core Data 里的历史基线保证计算正确性
    /// 3. 减少对 HealthKit 的重复查询（每次重启查 30 天历史数据比较耗时）
    ///
    /// - Parameter value: 当前 30 天基线 SDNN 均值（毫秒）
    private func saveBaselineToCoreData(value: Double) {
        guard value > 0 else { return } // 防止写入无效数据

        let ctx = persistence.newBackgroundContext()
        // 提前捕获值（避免在 ctx.perform 闭包里捕获 self 导致 actor 隔离问题）
        let savedValue = value

        ctx.perform {
            // 查找已有的 HRVBaseline 记录（按时间降序取最新一条）
            let request = HRVBaseline.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            request.fetchLimit = 1

            let baseline: HRVBaseline
            if let existing = (try? ctx.fetch(request))?.first {
                // 更新已有记录（同一条记录，避免 Core Data 里有大量历史基线记录）
                baseline = existing
            } else {
                // 第一次写入，创建新记录
                baseline = HRVBaseline(context: ctx)
                baseline.id = UUID()
                baseline.platform = "mac"
            }

            baseline.date          = Date()       // 更新时间戳
            baseline.sdnn          = savedValue   // 当前测量的基线（ms）
            baseline.rollingAvg30d = savedValue   // 30 天滚动均值（与 sdnn 保持一致）

            // 写入数据库（失败忽略，不崩溃）
            try? ctx.save()
        }
    }

    /// 从 Core Data 读取上次保存的基线，并还原给 HRVManager。
    ///
    /// 在 init() 里同步调用，保证 App 启动时有合理的初始基线。
    private func restoreBaselineFromCoreData() {
        let ctx = persistence.container.viewContext

        let request = HRVBaseline.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchLimit = 1

        if let record = (try? ctx.fetch(request))?.first,
           record.rollingAvg30d > 0 {
            // 恢复上次保存的基线（不触发 didSet，避免在 init 时产生副作用）
            // 注意：这里用 _ = 来"跳过" didSet。
            // 实际上 didSet 会触发，但因为 HRVManager 已经被初始化，这是安全的。
            localBaseline30d = record.rollingAvg30d
        }
        // 如果 Core Data 里没有记录，localBaseline30d 保持默认值 30.0ms
        // HRVManager 也用同样的默认值，两者一致
    }
}
