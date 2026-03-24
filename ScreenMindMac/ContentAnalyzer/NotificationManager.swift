import Foundation
import UserNotifications
import ScreenMindCore

/// Sends UNUserNotification alerts with relaxation suggestions.
final class NotificationManager: @unchecked Sendable {

    // MARK: - Setup

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        try? await center.requestAuthorization(options: [.alert, .sound])
    }

    // MARK: - Anxiety alert

    /// Sends a notification with the top 2 suggestions and their travel times.
    func sendAnxietyAlert(score: Double,
                          keywords: [String],
                          suggestions: [SuggestionItem]) async {
        let content = UNMutableNotificationContent()
        content.title = "🧠 ScreenMind — 检测到焦虑内容"
        content.sound = .default

        let scorePercent = Int(score * 100)
        var body = "焦虑指数：\(scorePercent)%"
        if !keywords.isEmpty {
            body += "（\(keywords.prefix(3).joined(separator: "、"))）"
        }

        let topSuggestions = suggestions.prefix(2)
        if !topSuggestions.isEmpty {
            body += "\n\n💡 建议：\n"
            body += topSuggestions.map { item in
                var line = "• \(item.title)"
                if let mins = item.travelMinutes, mins > 0 {
                    line += "（开车约 \(mins) 分钟）"
                }
                return line
            }.joined(separator: "\n")
        }
        content.body = body

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Account alert

    func sendAccountAlert(accountName: String, score: Double, notes: String) async {
        let content = UNMutableNotificationContent()
        content.title = "📱 高焦虑账号：\(accountName)"
        let scorePercent = Int(score * 100)
        content.body = "焦虑指数：\(scorePercent)%\n\(notes)"
        content.sound = .default

        let request = UNNotificationRequest(identifier: "account-\(accountName)",
                                            content: content,
                                            trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
