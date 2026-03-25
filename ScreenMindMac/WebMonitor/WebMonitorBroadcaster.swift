// WebMonitorBroadcaster.swift
// ScreenMindMac — M9 实时监控事件广播器
//
// 架构说明
// ─────────────────────────────────────────────────────────────────────────────
// WebMonitorBroadcaster 是 ScreenMind 内部事件系统 ↔ SSE 对外广播层的"翻译官"。
// 它持有 WebMonitorServer 实例，并向 StatusBarController 暴露一组
// `record*(...)` 方法；StatusBarController 在每个 Pipeline 阶段结束后调用这些
// 方法，Broadcaster 把数据包装成 MonitorEvent 并交给 Server 广播给所有连接的
// 浏览器客户端。
//
// 同时 Broadcaster 还维护一份"当前快照"（SnapshotState），供 GET /snapshot
// 端点返回最新状态，让新打开的 Dashboard 页面立刻有数据展示。
//
// 心跳机制：每 15 秒自动广播一次 heartbeat 事件，防止 SSE 连接被 Nginx / CDN
// 等中间代理因为闲置超时而断开（对本地使用基本用不上，但保留是好习惯）。
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

// ─── 快照状态：记录各维度最新数值 ─────────────────────────────────────────────

/// 保存当前系统各项指标的最新快照，用于 GET /snapshot 端点。
/// 注意：这是值类型（struct），每次赋值都会复制，线程安全由 @MainActor 保证。
struct SnapshotState {

    // 最新焦虑分数（0–1）
    var latestAnxietyScore: Double = 0.0
    var latestAnxietyApp: String = ""

    // 最新 HRV 数据（毫秒）
    var latestHRVsdnn: Double = 0.0
    var latestHRVrmssd: Double = 0.0

    // 最新 Pipeline 延迟（毫秒）
    var latestPipelineMs: Double = 0.0
    var latestPipelineStage: String = ""

    // 最新账号检测
    var latestAccountName: String = ""
    var latestAccountPlatform: String = ""
    var latestAccountScore: Double = 0.0

    // 统计计数
    var totalEventsCount: Int = 0
    var totalAlertCount: Int = 0

    // 服务器启动时间
    var serverStartedAt: Date = Date()

    // 近 60 次焦虑分数（用于折线图滚动展示）
    // 最多保存 120 个点（约 10 分钟，每 5 秒一次 Pipeline）
    var anxietyHistory: [(ts: String, score: Double)] = []

    // 近 60 次 Pipeline 延迟
    var latencyHistory: [(ts: String, ms: Double)] = []

    // MARK: - 序列化

    /// 把快照序列化成 JSON 字符串（供 GET /snapshot 端点返回）
    func toJSON() -> String {
        let iso = ISO8601DateFormatter()

        // anxietyHistory 转成 [[ts, score]] 格式（Chart.js 友好）
        let anxArr = anxietyHistory.map { ["ts": $0.ts, "score": $0.score] as [String: Any] }
        let latArr = latencyHistory.map { ["ts": $0.ts, "ms": $0.ms] as [String: Any] }

        let dict: [String: Any] = [
            "latestAnxietyScore": latestAnxietyScore,
            "latestAnxietyApp": latestAnxietyApp,
            "latestHRVsdnn": latestHRVsdnn,
            "latestHRVrmssd": latestHRVrmssd,
            "latestPipelineMs": latestPipelineMs,
            "latestPipelineStage": latestPipelineStage,
            "latestAccountName": latestAccountName,
            "latestAccountPlatform": latestAccountPlatform,
            "latestAccountScore": latestAccountScore,
            "totalEventsCount": totalEventsCount,
            "totalAlertCount": totalAlertCount,
            "serverStartedAt": iso.string(from: serverStartedAt),
            "anxietyHistory": anxArr,
            "latencyHistory": latArr
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// ─── WebMonitorBroadcaster ─────────────────────────────────────────────────────

/// M9 核心广播器：接收 ScreenMind 内部事件 → 广播给 SSE 客户端。
///
/// 用法：
///   1. 在 StatusBarController.init() 中创建并调用 start()
///   2. 在各 Pipeline 回调中调用 recordAnxiety / recordHRV / recordLatency 等方法
///   3. Dashboard 页面打开后自动接收实时数据
@MainActor
public final class WebMonitorBroadcaster {

    // MARK: - 属性

    /// 底层 HTTP / SSE 服务器
    private let server: WebMonitorServer

    /// 当前快照状态（每次 record* 调用都会更新）
    private var snapshot: SnapshotState = SnapshotState()

    /// 心跳定时器（每 15 秒触发一次）
    private var heartbeatTimer: Timer?

    /// 历史数据最大保留点数（超出时移除最旧的点）
    private let maxHistoryPoints = 120

    // MARK: - 初始化

    public init() {
        server = WebMonitorServer()

        // 把快照 Provider 注入服务器：每次 GET /snapshot 时调用 snapshot.toJSON()
        server.snapshotProvider = { [weak self] in
            self?.snapshot.toJSON() ?? "{}"
        }
    }

    // MARK: - 启动 / 停止

    /// 启动 HTTP 服务器 + 心跳定时器
    public func start() {
        server.start()

        // 心跳：每 15 秒广播一次空事件，防止 SSE 连接被代理层断开
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.server.broadcast(event: .heartbeat(timestamp: Date()))
            }
        }

        print("[WebMonitorBroadcaster] 广播器已启动，Dashboard: http://localhost:\(server.port)")
    }

    /// 停止服务器 + 心跳定时器
    public func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        server.stop()
    }

    /// 当前监听端口（供 StatusBarController 展示菜单项 URL）
    public var dashboardURL: URL? {
        URL(string: "http://localhost:\(server.port)")
    }

    // MARK: - 事件记录接口（StatusBarController 调用）

    /// 记录焦虑分数更新（每次 AnxietyPipeline 出分时调用）
    /// - Parameters:
    ///   - score: 焦虑分数 0.0–1.0
    ///   - appName: 当前前台 App 名称（如 "抖音"）
    public func recordAnxiety(score: Double, appName: String) {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)

        // 更新快照
        snapshot.latestAnxietyScore = score
        snapshot.latestAnxietyApp = appName
        snapshot.totalEventsCount += 1

        // 追加历史（超出限制时移除最旧的点）
        snapshot.anxietyHistory.append((ts: ts, score: score))
        if snapshot.anxietyHistory.count > maxHistoryPoints {
            snapshot.anxietyHistory.removeFirst()
        }

        // 广播 SSE 事件
        server.broadcast(event: .anxietyScore(score: score, appName: appName, timestamp: now))
    }

    /// 记录 HRV 数据更新（来自 HealthKit 或手环同步时调用）
    /// - Parameters:
    ///   - sdnn: SDNN 毫秒值（心率变异性标准差，越高越好）
    ///   - rmssd: RMSSD 毫秒值（相邻心跳差的均方根）
    public func recordHRV(sdnn: Double, rmssd: Double) {
        let now = Date()
        snapshot.latestHRVsdnn = sdnn
        snapshot.latestHRVrmssd = rmssd
        snapshot.totalEventsCount += 1

        server.broadcast(event: .hrvUpdate(sdnn: sdnn, rmssd: rmssd, timestamp: now))
    }

    /// 记录 Pipeline 端到端延迟（从截图到最终结果的总耗时）
    /// - Parameters:
    ///   - totalMs: 总耗时毫秒
    ///   - stage: 当前完成的阶段名（如 "ocr" / "llm" / "full"）
    public func recordLatency(totalMs: Double, stage: String) {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)

        snapshot.latestPipelineMs = totalMs
        snapshot.latestPipelineStage = stage

        snapshot.latencyHistory.append((ts: ts, ms: totalMs))
        if snapshot.latencyHistory.count > maxHistoryPoints {
            snapshot.latencyHistory.removeFirst()
        }

        server.broadcast(event: .pipelineLatency(totalMs: totalMs, stage: stage, timestamp: now))
    }

    /// 记录账号检测结果（AccountDetector 检测到账号时调用）
    public func recordAccountDetection(accountName: String, platform: String, combinedScore: Double) {
        snapshot.latestAccountName = accountName
        snapshot.latestAccountPlatform = platform
        snapshot.latestAccountScore = combinedScore

        server.broadcast(event: .accountDetected(
            accountName: accountName,
            platform: platform,
            combinedScore: combinedScore,
            timestamp: Date()
        ))
    }

    /// 记录焦虑告警触发（弹出 AlertPanel 时调用）
    /// - Parameters:
    ///   - reason: 触发原因描述（如 "内容焦虑分超阈值" / "账号综合分超阈值"）
    ///   - threshold: 触发时使用的阈值
    public func recordAlertTriggered(reason: String, threshold: Double) {
        snapshot.totalAlertCount += 1
        server.broadcast(event: .alertTriggered(reason: reason, threshold: threshold, timestamp: Date()))
    }
}
