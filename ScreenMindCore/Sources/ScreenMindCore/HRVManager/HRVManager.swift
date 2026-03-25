// =============================================================================
//  HRVManager.swift
//  ScreenMindCore — 跨平台共享层
// =============================================================================
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenMind 的核心理念：屏幕内容（OCR + AI 评分）只是"外部刺激"，
//  真正的焦虑来自"身体反应"。
//  HRVManager 从 Apple Watch / iPhone 的 HealthKit 读取 HRV 数据，
//  作为"生理焦虑"的客观依据。
//
//  【HRV 和焦虑的关系】
//  当你感到压力或焦虑时，交感神经系统激活（"战斗或逃跑"模式），
//  心跳会变得更规律（相邻心跳间隔的变化量变小），即 HRV 降低。
//
//  相反，放松时副交感神经主导，心跳更自然地随呼吸起伏，HRV 升高。
//
//  【HRVManager 在整体架构中的位置（M5 之后接入）】
//  当前（M3 阶段）HRVManager 已经写好，但还没有接入主管道。
//  M5 阶段计划：
//    AnxietyScorer 结合 HRV 数据调整阈值：
//    - 当前 HRV 比 30 天基线低 → 身体本来就紧张 → 降低阈值（更容易触发提醒）
//    - 当前 HRV 比 30 天基线高 → 身体很放松 → 提高阈值（不容易触发提醒）
//
//  【dynamicMultiplier 的用途（未来）】
//    finalThreshold = baseThreshold × HRVManager.dynamicMultiplier(currentSDNN)
//    比如：HRV 比基线低 30% → multiplier = 0.7 → 阈值降至 0.6 × 0.7 = 0.42（更敏感）
//
//  【为什么在 ScreenMindCore 而不是 ScreenMindIOS？】
//  macOS 13+ 也支持 HealthKit（用户需要授权）。
//  虽然目前 HRV 数据主要来自 iPhone + Apple Watch，
//  但放在共享包里，将来 Mac 端也能用。
//
//  【部署位置】
//  ScreenMindCore/Sources/ScreenMindCore/HRVManager/HRVManager.swift
//
// =============================================================================

import Foundation  // 基础类型
import HealthKit   // 苹果健康数据框架（心率、HRV、步数、睡眠等生理数据）

/// 读取 HealthKit 中的 HRV（心率变异性）数据，并计算动态阈值乘数。
///
/// 数据流：
///   Apple Watch 实时测量 → HealthKit 存储 → HRVManager 读取 → 影响焦虑阈值
///
/// 目前支持平台：macOS 13+, iOS 17+（HealthKit API 在两平台基本一致）
///
/// @unchecked Sendable：
///   HKHealthStore（HealthKit 存储）不是 Sendable，
///   但苹果文档说 HKHealthStore 内部是线程安全的，所以用 @unchecked 允许跨线程传递。
public final class HRVManager: @unchecked Sendable {

    // MARK: - HealthKit 存储实例 ──────────────────────────────────────────

    /// HealthKit 的访问入口（单个 App 只需要一个实例）。
    ///
    /// HKHealthStore 是访问所有健康数据的门户，
    /// 类似 Core Data 的 NSPersistentContainer，或网络请求的 URLSession。
    private let healthStore = HKHealthStore()

    // MARK: - 30 天基线 ────────────────────────────────────────────────────

    /// 30 天 SDNN 滚动平均值（毫秒）。
    ///
    /// 用途：判断当前 HRV 是"正常水平"还是"低于基线"（身体在压力中）。
    ///
    /// 默认值 30.0ms：
    ///   正常成人静息 SDNN 约 30–70ms，30ms 是偏低但合理的初始假设。
    ///   App 运行后会调用 refreshBaseline() 获取用户真实的 30 天数据。
    ///
    /// private：外部不能直接修改（只通过 refreshBaseline() 更新）。
    private var baseline30d: Double = 30.0

    // MARK: - 权限申请 ────────────────────────────────────────────────────

    /// 向用户申请 HealthKit 数据读取权限。
    ///
    /// 调用时机：App 首次启动，或者用户首次打开 HRV 相关功能时。
    ///
    /// 权限类型说明：
    ///   toShare: []     → 我们不向 HealthKit 写入数据（我们只读）
    ///   read: [sdnnType] → 只需要读取 HRV SDNN 数据
    ///
    /// 权限粒度：用户可以在"设置 → 隐私 → 健康"里撤回授权。
    ///
    /// - Throws: HRVError.healthKitUnavailable（比如运行在不支持 HealthKit 的设备/模拟器上）
    public func requestAuthorization() async throws {
        // 检查当前设备是否支持 HealthKit（Apple Watch、iPhone、Mac 各有不同支持情况）
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HRVError.healthKitUnavailable
        }
        // 创建"HRV SDNN"数据类型（HealthKit 用类型对象区分不同数据种类）
        let sdnnType = HKQuantityType(.heartRateVariabilitySDNN)
        // 发起授权请求，会弹出系统授权对话框（如果还没有授权过）
        try await healthStore.requestAuthorization(toShare: [], read: [sdnnType])
    }

    // MARK: - 读取最新 HRV ────────────────────────────────────────────────

    /// 获取 HealthKit 中最近一次 HRV 测量值。
    ///
    /// 数据来源：
    ///   - iPhone：健康 App 手动测量
    ///   - Apple Watch：自动后台测量（睡眠时、运动后等）
    ///
    /// 注意：HRV 不是实时的，最近一条数据可能是几小时前甚至昨天的。
    /// 因此 ScreenMind 使用 HRV 作为"趋势"参考，而不是精确实时指标。
    ///
    /// - Returns: HRVSnapshot（包含 SDNN 值和测量时间）
    /// - Throws: HRVError.noDataAvailable（用户没有 HRV 数据）
    public func latestHRV() async throws -> HRVSnapshot {
        let sdnnType = HKQuantityType(.heartRateVariabilitySDNN)
        // 按时间降序排列（最新的排第一）
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        // withCheckedThrowingContinuation：把旧的回调风格 API 包装成 async/await 风格
        //
        // 【为什么需要这个包装？】
        // HKSampleQuery 使用回调（completion handler）风格（是老式 ObjC API）：
        //   query.completionHandler = { results, error in ... }
        // Swift 的 async/await 不能直接用 await 等待回调。
        // withCheckedThrowingContinuation 提供了一个"暂停点"：
        //   - continuation.resume(returning:) = 成功，返回值
        //   - continuation.resume(throwing:)  = 失败，抛出错误
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sdnnType,
                predicate: nil,       // nil = 不过滤，查所有
                limit: 1,             // 只要最新的 1 条
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    // 查询出错，通知 continuation 抛出错误
                    continuation.resume(throwing: error)
                    return
                }
                // 取第一个（也是唯一的）结果，并转换成 HKQuantitySample 类型
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(throwing: HRVError.noDataAvailable)
                    return
                }
                // 从 HKQuantity 提取数值（指定单位：毫秒 = secondUnit(with: .milli)）
                let sdnn = sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
                // 成功！返回 HRVSnapshot
                continuation.resume(returning: HRVSnapshot(sdnn: sdnn,
                                                           timestamp: sample.endDate))
            }
            healthStore.execute(query) // 实际执行 HealthKit 查询
        }
    }

    // MARK: - 刷新 30 天基线 ──────────────────────────────────────────────

    /// 从 HealthKit 计算过去 30 天的平均 HRV，并缓存到 baseline30d。
    ///
    /// 调用时机：
    ///   - App 启动时调用一次（加载历史基线）
    ///   - 每天凌晨定时更新（保持基线是最近 30 天的数据）
    ///
    /// HKStatisticsQuery：HealthKit 的统计查询，可以直接计算均值/最大值/最小值。
    /// 比手动读取所有样本再计算均值更高效（统计在 HealthKit 内部完成）。
    ///
    /// - Throws: HRVError.noDataAvailable（30天内没有 HRV 数据）
    public func refreshBaseline() async throws {
        let sdnnType = HKQuantityType(.heartRateVariabilitySDNN)
        // 计算 30 天前的时间点
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        // 时间范围谓词（查询 30 天内的所有数据）
        let predicate = HKQuery.predicateForSamples(withStart: thirtyDaysAgo, end: .now)

        let stats: HKStatistics = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: sdnnType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage  // 请求计算离散平均值
            ) { _, stats, error in
                if let error { continuation.resume(throwing: error); return }
                guard let stats else {
                    continuation.resume(throwing: HRVError.noDataAvailable); return
                }
                continuation.resume(returning: stats)
            }
            healthStore.execute(query)
        }

        // 从统计结果中提取平均值（averageQuantity 可能为 nil，如果没有数据）
        if let avg = stats.averageQuantity() {
            baseline30d = avg.doubleValue(for: HKUnit.secondUnit(with: .milli))
            // 更新 baseline30d（这里没有触发 UI 更新，将来可以加 @Published）
        }
    }

    // MARK: - M4 基线读写接口 ──────────────────────────────────────────────

    /// 从外部（Core Data 或 HRVIntegrator）设置 30 天基线 SDNN。
    ///
    /// 调用方：HRVIntegrator
    ///   - App 冷启动时，从 Core Data 恢复上次保存的基线
    ///   - HealthKit refreshBaseline() 成功后，更新基线
    ///
    /// 为什么需要这个方法？
    ///   baseline30d 是 private（封装原则），外部不能直接赋值。
    ///   通过这个方法，HRVIntegrator 可以在 Core Data 持久化和 HealthKit 刷新之间
    ///   保持 HRVManager 内部基线和外部缓存的同步。
    ///
    /// - Parameter value: 新的 30 天基线 SDNN（毫秒），如果 ≤ 0 则忽略（防止无效数据）
    public func setBaseline30d(_ value: Double) {
        guard value > 0 else { return }  // 防止写入 0 或负数（会导致除以 0）
        baseline30d = value
    }

    /// 读取当前缓存的 30 天基线 SDNN（毫秒）。
    ///
    /// 调用方：HRVIntegrator.pollOnce()
    ///   refreshBaseline() 成功后，调用此方法获取新基线，
    ///   然后更新自己的 localBaseline30d 副本，并持久化到 Core Data。
    ///
    /// - Returns: 当前 baseline30d 值（毫秒，默认 30.0ms）
    public func getBaseline30d() -> Double {
        return baseline30d
    }

    // MARK: - 动态阈值乘数 ────────────────────────────────────────────────

    /// 基于当前 HRV 相对于 30 天基线的比值，计算焦虑阈值乘数。
    ///
    /// 【公式】
    ///   multiplier = clamp(currentSDNN / baseline30d, 0.4, 1.6)
    ///
    /// 【含义】
    ///   currentSDNN = baseline30d：身体状态正常 → multiplier = 1.0（阈值不变）
    ///   currentSDNN = baseline30d × 0.5（HRV 低了 50%）：身体在压力中 → multiplier ≈ 0.5
    ///   currentSDNN = baseline30d × 2（HRV 高了一倍）：非常放松 → multiplier ≈ 1.6
    ///
    ///   实际使用：
    ///     adjustedThreshold = baseThreshold × multiplier
    ///     如果今天压力大（multiplier = 0.7），焦虑阈值降低（0.6 × 0.7 = 0.42），
    ///     更容易触发提醒，促使用户休息。
    ///
    /// 【为什么要 clamp（限制范围）？】
    ///   防止极端值：
    ///   - HRV 极低时（multiplier 可能接近 0），不能让阈值降到 0（会一直触发）
    ///   - HRV 极高时（multiplier 可能很大），不能让阈值高到永远不触发
    ///   [0.4, 1.6] 是实践中合理的范围。
    ///
    /// - Parameter currentSDNN: 当前实测 HRV（毫秒）
    /// - Returns: 阈值乘数（范围 [0.4, 1.6]，正常情况接近 1.0）
    public func dynamicMultiplier(currentSDNN: Double) -> Double {
        let raw = currentSDNN / max(baseline30d, 1.0)  // max 防止 baseline30d 为 0 时除以零
        return min(max(raw, 0.4), 1.6) // clamp 到 [0.4, 1.6]
    }

    // MARK: - 错误类型 ────────────────────────────────────────────────────

    /// HRVManager 操作可能产生的错误。
    public enum HRVError: Error {
        case healthKitUnavailable  // HealthKit 不可用（比如运行在不支持的模拟器上）
        case noDataAvailable       // HealthKit 里没有 HRV 数据（用户没有 Apple Watch 或未测量）
    }
}
