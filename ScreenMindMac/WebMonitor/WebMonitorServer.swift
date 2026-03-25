// WebMonitorServer.swift
// ScreenMindMac — M9 实时监控服务器
//
// 架构概述
// ─────────────────────────────────────────────────────────────────────────────
// 本文件在 Mac 本机启动一个轻量 HTTP 服务器（端口 9527），提供三个端点：
//
//   GET /           → 返回内联的 Dashboard HTML 页面（DashboardHTML.swift 中定义）
//   GET /events     → Server-Sent Events (SSE) 长连接，实时推送焦虑/HRV/Pipeline 事件
//   GET /snapshot   → 一次性返回当前完整状态的 JSON 快照
//
// 为什么选 SSE 而非 WebSocket？
//   - ScreenMind 只需要 Swift → 浏览器 单向数据推送
//   - SSE 基于普通 HTTP，浏览器原生 EventSource API 无需任何 JS 库
//   - 实现复杂度远低于 WebSocket，且防火墙友好
//
// 技术栈：Apple Network.framework（NWListener），纯 Swift，无第三方依赖。
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import Network

// ─── SSE 客户端连接封装 ────────────────────────────────────────────────────────

/// 代表一个已建立的 SSE 长连接客户端。
/// 每次浏览器 GET /events 时，服务器都会创建一个新的 SSEClient 并保留在列表中，
/// 直到连接关闭（浏览器刷新 / 关闭标签页）。
final class SSEClient: @unchecked Sendable {

    /// NWConnection 是 Network.framework 的核心类，代表一条 TCP 连接
    let connection: NWConnection

    /// 客户端唯一 ID，方便日志 & 调试
    let id: UUID

    /// 是否已发送过 HTTP 响应头（SSE 头只发送一次）
    private var headerSent = false

    init(connection: NWConnection) {
        self.connection = connection
        self.id = UUID()
    }

    // MARK: - 发送 SSE 响应头

    /// 在第一次推送事件前，先把 HTTP/1.1 200 + SSE 所需的响应头发出去。
    /// SSE 协议要求：
    ///   Content-Type: text/event-stream
    ///   Cache-Control: no-cache
    ///   Connection: keep-alive
    func sendHeaders() {
        guard !headerSent else { return }
        headerSent = true

        // 构造标准 HTTP 响应头，\r\n\r\n 表示头部结束
        let headers = """
        HTTP/1.1 200 OK\r\n\
        Content-Type: text/event-stream\r\n\
        Cache-Control: no-cache\r\n\
        Connection: keep-alive\r\n\
        Access-Control-Allow-Origin: *\r\n\
        \r\n
        """
        send(text: headers)

        // 立即发送一个注释行，让浏览器知道连接已建立（防止 EventSource 超时重连）
        send(text: ": connected\n\n")
    }

    // MARK: - 推送 SSE 事件

    /// 向客户端推送一条 SSE 事件。
    /// SSE 格式：
    ///   event: <eventName>\n
    ///   data: <jsonPayload>\n
    ///   \n
    /// 其中双 \n 标志着一条事件的结束。
    func sendEvent(name: String, data: String) {
        let message = "event: \(name)\ndata: \(data)\n\n"
        send(text: message)
    }

    // MARK: - 私有发送

    /// 底层文本发送：把字符串编码成 UTF-8 字节，交给 NWConnection 异步发送。
    /// completion: 发送完成后的回调（此处忽略，失败由连接状态监听负责清理）
    private func send(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        connection.send(content: data, completion: .contentProcessed({ _ in }))
    }

    /// 关闭连接（浏览器侧断开时调用，或服务器主动断开）
    func close() {
        connection.cancel()
    }
}

// ─── MonitorEvent：所有可广播的事件类型 ───────────────────────────────────────

/// 所有可以通过 SSE 广播的事件，统一用 enum 表示，便于类型安全序列化。
public enum MonitorEvent: Sendable {

    /// 焦虑分数更新：anxietyScore 0–1，appName 触发应用名称
    case anxietyScore(score: Double, appName: String, timestamp: Date)

    /// HRV 数值更新：sdnn = 标准差（毫秒），rmssd = 均方根（毫秒）
    case hrvUpdate(sdnn: Double, rmssd: Double, timestamp: Date)

    /// Pipeline 延迟：totalMs = 完整流水线耗时（截图 → OCR → 分析 → 结果）
    case pipelineLatency(totalMs: Double, stage: String, timestamp: Date)

    /// 账号检测：检测到账号名称 + 平台 + 综合分
    case accountDetected(accountName: String, platform: String, combinedScore: Double, timestamp: Date)

    /// 建议触发：当焦虑超阈值触发弹窗时记录
    case alertTriggered(reason: String, threshold: Double, timestamp: Date)

    /// 心跳：每 15 秒发送一次，防止 SSE 连接被中间代理超时断开
    case heartbeat(timestamp: Date)

    // MARK: - 序列化

    /// 事件名称（对应 SSE 的 event: 字段，前端 EventSource.addEventListener 用这个区分）
    var eventName: String {
        switch self {
        case .anxietyScore:    return "anxiety"
        case .hrvUpdate:       return "hrv"
        case .pipelineLatency: return "latency"
        case .accountDetected: return "account"
        case .alertTriggered:  return "alert"
        case .heartbeat:       return "heartbeat"
        }
    }

    /// 序列化成 JSON 字符串（data: 字段的内容）
    var jsonPayload: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        switch self {
        case .anxietyScore(let score, let appName, let ts):
            let dict: [String: Any] = ["score": score, "appName": appName, "ts": iso8601(ts)]
            return jsonString(dict)

        case .hrvUpdate(let sdnn, let rmssd, let ts):
            let dict: [String: Any] = ["sdnn": sdnn, "rmssd": rmssd, "ts": iso8601(ts)]
            return jsonString(dict)

        case .pipelineLatency(let ms, let stage, let ts):
            let dict: [String: Any] = ["totalMs": ms, "stage": stage, "ts": iso8601(ts)]
            return jsonString(dict)

        case .accountDetected(let name, let platform, let score, let ts):
            let dict: [String: Any] = ["accountName": name, "platform": platform, "combinedScore": score, "ts": iso8601(ts)]
            return jsonString(dict)

        case .alertTriggered(let reason, let threshold, let ts):
            let dict: [String: Any] = ["reason": reason, "threshold": threshold, "ts": iso8601(ts)]
            return jsonString(dict)

        case .heartbeat(let ts):
            let dict: [String: Any] = ["ts": iso8601(ts)]
            return jsonString(dict)
        }
    }

    // MARK: - 工具方法

    /// 把 Date 转成 ISO8601 字符串（前端 new Date(ts) 可直接解析）
    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// 把 [String: Any] 字典序列化成 JSON 字符串（失败时返回 {}）
    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// ─── WebMonitorServer：核心 HTTP / SSE 服务器 ─────────────────────────────────

/// 在 localhost:9527 监听 HTTP 请求的服务器。
/// - 线程安全：所有可变状态都在 `queue`（串行队列）上访问
/// - 生命周期：由 WebMonitorBroadcaster 持有，随 App 启动/退出
@MainActor
public final class WebMonitorServer {

    // MARK: - 公开属性

    /// 服务器监听端口（可在 Settings 中调整，暂硬编码 9527）
    public let port: UInt16 = 9527

    /// 是否正在运行
    public private(set) var isRunning = false

    // MARK: - 私有属性

    /// NWListener：Network.framework 的 TCP 监听器，相当于 BSD socket 的 accept() 循环
    private var listener: NWListener?

    /// 当前所有活跃的 SSE 长连接客户端
    /// 注意：这里不是 actor-isolated 属性，通过 DispatchQueue 保护
    private var sseClients: [SSEClient] = []

    /// 保护 sseClients 列表的串行队列（防止多线程并发写）
    private let clientQueue = DispatchQueue(label: "com.screenmind.webmonitor.clients")

    /// 快照回调：由 WebMonitorBroadcaster 注入，返回当前系统状态 JSON 字符串
    /// GET /snapshot 端点调用此闭包获取数据
    public var snapshotProvider: (() -> String)?

    // MARK: - 初始化

    public init() {}

    // MARK: - 启动 / 停止

    /// 启动 HTTP 服务器。
    /// 调用后在 localhost:9527 开始接受连接。
    public func start() {
        guard !isRunning else { return }

        // NWParameters.tcp 表示 TCP 协议（不加 TLS，本地使用不需要 HTTPS）
        let parameters = NWParameters.tcp
        // 禁用 Nagle 算法：SSE 需要实时推送小数据包，不能等待缓冲区填满
        parameters.allowLocalEndpointReuse = true

        do {
            // 创建监听器，绑定到指定端口
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("[WebMonitorServer] 创建监听器失败: \(error)")
            return
        }

        // 监听器状态变化回调（ready / failed / cancelled）
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[WebMonitorServer] ✅ 服务器已启动，访问 http://localhost:\(self?.port ?? 9527)")
            case .failed(let error):
                print("[WebMonitorServer] ❌ 服务器错误: \(error)")
            case .cancelled:
                print("[WebMonitorServer] 服务器已停止")
            default:
                break
            }
        }

        // 新连接到来的回调（每个新 TCP 连接都触发一次）
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        // 在后台队列启动监听器
        listener?.start(queue: DispatchQueue(label: "com.screenmind.webmonitor.listener"))
        isRunning = true
    }

    /// 停止服务器，关闭所有 SSE 连接
    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        clientQueue.sync {
            sseClients.forEach { $0.close() }
            sseClients.removeAll()
        }
        print("[WebMonitorServer] 服务器已停止，所有 SSE 连接已关闭")
    }

    // MARK: - 连接处理

    /// 处理一个新进来的 TCP 连接。
    /// HTTP 请求是文本协议，我们读取请求行，然后路由到对应处理函数。
    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "com.screenmind.webmonitor.conn.\(UUID())"))

        // 读取 HTTP 请求（最多 4096 字节已足够读取请求行 + 头部）
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }

            // 解析请求行（第一行），格式：GET /path HTTP/1.1
            let requestText = String(data: data, encoding: .utf8) ?? ""
            let firstLine = requestText.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")

            guard parts.count >= 2 else {
                connection.cancel()
                return
            }

            let method = parts[0]  // "GET"
            let path = parts[1]    // "/", "/events", "/snapshot"

            // 路由
            switch (method, path) {
            case ("GET", "/events"):
                // SSE 长连接：不关闭连接，持续推送事件
                self.handleSSERequest(connection: connection)
            case ("GET", "/snapshot"):
                // 快照：返回 JSON 后关闭连接
                self.handleSnapshotRequest(connection: connection)
            case ("GET", "/"):
                // Dashboard HTML 页面
                self.handleDashboardRequest(connection: connection)
            default:
                // 404
                self.sendHTTPResponse(connection: connection, status: "404 Not Found", contentType: "text/plain", body: "Not Found")
                connection.cancel()
            }
        }
    }

    // MARK: - 路由处理函数

    /// 处理 GET / ：返回内联 Dashboard HTML
    private func handleDashboardRequest(connection: NWConnection) {
        let html = DashboardHTML.content  // 见 DashboardHTML.swift
        sendHTTPResponse(connection: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: html)
        // HTML 是一次性响应，发完就关闭
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            connection.cancel()
        }
    }

    /// 处理 GET /snapshot ：返回当前状态 JSON
    private func handleSnapshotRequest(connection: NWConnection) {
        let json = snapshotProvider?() ?? "{}"
        sendHTTPResponse(connection: connection, status: "200 OK", contentType: "application/json", body: json)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            connection.cancel()
        }
    }

    /// 处理 GET /events ：升级为 SSE 长连接
    /// 此连接会一直保持，直到浏览器断开。
    private func handleSSERequest(connection: NWConnection) {
        let client = SSEClient(connection: connection)

        // 注册到客户端列表
        clientQueue.async { [weak self] in
            self?.sseClients.append(client)
        }

        // 发送 SSE 响应头（让浏览器进入 EventSource 模式）
        client.sendHeaders()

        // 立即推送一条快照事件，让页面初次加载时就有数据
        let snapshot = snapshotProvider?() ?? "{}"
        client.sendEvent(name: "snapshot", data: snapshot)

        // 监听连接断开（浏览器关闭 / 刷新时会触发 cancelled/failed）
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                // 从列表中移除已断开的客户端
                self?.removeClient(id: client.id)
            default:
                break
            }
        }

        print("[WebMonitorServer] SSE 客户端已连接，ID: \(client.id)，当前连接数: \(sseClients.count)")
    }

    // MARK: - 广播接口（由 WebMonitorBroadcaster 调用）

    /// 向所有已连接的 SSE 客户端广播一条事件。
    /// 如果某个客户端已断开，发送会静默失败（Network.framework 层面忽略错误）。
    public func broadcast(event: MonitorEvent) {
        let name = event.eventName
        let payload = event.jsonPayload

        clientQueue.async { [weak self] in
            self?.sseClients.forEach { $0.sendEvent(name: name, data: payload) }
        }
    }

    // MARK: - 工具方法

    /// 从客户端列表中移除指定 ID 的客户端（连接断开时调用）
    private func removeClient(id: UUID) {
        clientQueue.async { [weak self] in
            self?.sseClients.removeAll { $0.id == id }
            print("[WebMonitorServer] SSE 客户端已断开，剩余连接: \(self?.sseClients.count ?? 0)")
        }
    }

    /// 构造并发送标准 HTTP 响应
    /// - Parameters:
    ///   - connection: 目标 NWConnection
    ///   - status: HTTP 状态行，如 "200 OK"
    ///   - contentType: Content-Type 头值
    ///   - body: 响应体字符串
    private func sendHTTPResponse(connection: NWConnection, status: String, contentType: String, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let headers = """
        HTTP/1.1 \(status)\r\n\
        Content-Type: \(contentType)\r\n\
        Content-Length: \(bodyData.count)\r\n\
        Access-Control-Allow-Origin: *\r\n\
        Connection: close\r\n\
        \r\n
        """
        var responseData = headers.data(using: .utf8)!
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed({ _ in }))
    }
}
