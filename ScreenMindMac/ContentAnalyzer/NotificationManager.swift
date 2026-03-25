// =============================================================================
//  NotificationManager.swift
//  ScreenMindMac — Mac 端主应用
// =============================================================================
//
//  【产品需求：这个文件解决什么问题？】
//  当 AnxietyPipeline 检测到高焦虑内容时，需要提醒用户。
//  提醒的方式：发送一条 macOS 系统通知（右上角弹出的那种小卡片）。
//
//  通知内容：
//    标题："🧠 ScreenMind — 检测到焦虑内容"
//    正文："焦虑指数：72%（失业率、股市崩盘、经济危机）
//           💡 建议：
//           • 去中山公园散步（开车约 8 分钟）
//           • 做 5 分钟深呼吸"
//
//  【UNUserNotification 是什么？】
//  UNUserNotification（User Notifications）框架：
//    - macOS 10.14+、iOS 10+ 的统一推送通知 API
//    - 支持本地通知（不需要网络/服务器，直接在本机发）和远程推送（需要 APNs）
//    - ScreenMind 只用本地通知，trigger = nil 表示"立刻显示"
//
//  【权限说明】
//  发送通知前，App 必须先向用户申请通知权限（会弹出系统对话框）。
//  用户可以在"系统设置 → 通知"里撤回授权或修改通知样式。
//
//  【部署位置】
//  ScreenMindMac/ContentAnalyzer/NotificationManager.swift
//
// =============================================================================

import Foundation          // 基础类型
import UserNotifications   // macOS/iOS 统一通知框架
import ScreenMindCore      // 共享包，提供 SuggestionItem 数据类型

/// 系统通知管理器。
///
/// 职责：
///   1. 申请通知权限
///   2. 构建并发送"焦虑警告"通知
///   3. 构建并发送"高焦虑账号"提醒通知（M5 后使用）
///
/// 【@unchecked Sendable】
/// 这个类没有可变状态（stateless），所有方法都是无副作用的工具函数，
/// 可以安全地跨 actor/线程传递。
final class NotificationManager: @unchecked Sendable {

    // MARK: - 权限申请 ────────────────────────────────────────────────────

    /// 向用户申请发送通知的权限。
    ///
    /// 调用时机：App 启动时（StatusBarController.init 里的 Task { } 里调用）。
    ///
    /// 参数说明：
    ///   options: [.alert, .sound]
    ///     .alert：显示通知横幅（标题 + 正文）
    ///     .sound：播放通知声音
    ///     没有申请 .badge（App 图标上的数字角标），因为 MenuBar App 没有 Dock 图标
    ///
    /// try?：忽略可能的错误（如果用户已经授权过，重复申请会直接成功）。
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current() // 通知中心（单例）
        try? await center.requestAuthorization(options: [.alert, .sound])
    }

    // MARK: - 发送焦虑警告通知 ────────────────────────────────────────────

    /// 发送"检测到焦虑内容"通知，包含焦虑分数、关键词，和可选的放松建议。
    ///
    /// 调用时机：AnxietyPipeline 触发 onAlert，StatusBarController 调用此方法。
    ///
    /// 通知样例：
    ///   标题：🧠 ScreenMind — 检测到焦虑内容
    ///   正文：焦虑指数：72%（失业率、股市崩盘、经济危机）
    ///
    ///         💡 建议：
    ///         • 去中山公园散步（开车约 8 分钟）
    ///         • 做 5 分钟深呼吸
    ///
    /// - Parameters:
    ///   - score: 焦虑分（0.0–1.0），用于显示百分比
    ///   - keywords: 触发焦虑的关键词（来自 AnxietyScorer 的 LLM 分析），显示在括号里
    ///   - suggestions: 放松建议列表（M4 阶段 SuggestionEngine 接入后填入），
    ///                  取前 2 条显示在通知里
    func sendAnxietyAlert(score: Double,
                          keywords: [String],
                          suggestions: [SuggestionItem]) async {
        // ── 创建通知内容 ──────────────────────────────────────────────────
        // UNMutableNotificationContent：可修改的通知内容对象
        let content = UNMutableNotificationContent()
        content.title = "🧠 ScreenMind — 检测到焦虑内容"
        content.sound = .default // 使用系统默认通知声音

        // ── 构建通知正文 ──────────────────────────────────────────────────
        let scorePercent = Int(score * 100) // 0.72 → 72
        var body = "焦虑指数：\(scorePercent)%"

        // 如果有关键词，附在括号里（最多显示 3 个，避免太长）
        if !keywords.isEmpty {
            body += "（\(keywords.prefix(3).joined(separator: "、"))）"
            // prefix(3)：Swift 的切片方法，取前 3 个元素
            // joined(separator:)：用顿号连接，如 "失业率、崩盘、危机"
        }

        // 显示最多 2 条放松建议（通知正文不宜太长）
        let topSuggestions = suggestions.prefix(2)
        if !topSuggestions.isEmpty {
            body += "\n\n💡 建议：\n" // \n 是换行符，\n\n 是空一行
            body += topSuggestions.map { item in
                var line = "• \(item.title)" // • 是项目符号（·圆点）
                if let mins = item.travelMinutes, mins > 0 {
                    line += "（开车约 \(mins) 分钟）" // 如果有车程，加括号说明
                }
                return line
            }.joined(separator: "\n") // 每条建议换行
        }
        content.body = body

        // ── 创建并发送通知请求 ────────────────────────────────────────────
        // UNNotificationRequest：一条通知的完整描述（内容 + 触发条件 + ID）
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, // 每次用新 UUID，允许多条通知同时存在
            content: content,
            trigger: nil // trigger = nil 表示"立刻发送"（没有延迟，不是定时）
        )
        try? await UNUserNotificationCenter.current().add(request)
        // add 失败（比如通知权限被撤销）→ try? 让我们忽略错误，不崩溃
    }

    // MARK: - 发送账号焦虑提醒 ────────────────────────────────────────────

    /// 发送"你关注的某个账号内容焦虑度很高"的提醒通知。
    ///
    /// 调用时机：AccountAssessor 评估完一个账号后，如果分数 > 阈值，发送此通知。
    /// 目前（M3 阶段）尚未接入 AccountAssessor，这个方法预先写好备用。
    ///
    /// 通知样例：
    ///   标题：📱 高焦虑账号：@某某财经
    ///   正文：焦虑指数：85%
    ///         该账号经常发布负面经济新闻，措辞夸张，容易引发读者焦虑。
    ///
    /// - Parameters:
    ///   - accountName: 账号名称（如 "@某某财经"）
    ///   - score: 账号的平均焦虑分（0.0–1.0）
    ///   - notes: LLM 对该账号风格的文字评估
    func sendAccountAlert(accountName: String, score: Double, notes: String) async {
        let content = UNMutableNotificationContent()
        content.title = "📱 高焦虑账号：\(accountName)"

        let scorePercent = Int(score * 100)
        content.body = "焦虑指数：\(scorePercent)%\n\(notes)"
        content.sound = .default

        // 账号通知用账号名作为 ID（而不是 UUID）：
        // 这样同一个账号不会重复推送（identifier 相同的通知会覆盖旧通知）
        let request = UNNotificationRequest(
            identifier: "account-\(accountName)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
