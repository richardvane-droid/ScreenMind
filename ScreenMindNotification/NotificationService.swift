import UserNotifications

/// Layer 1 — Notification Service Extension.
/// Intercepts incoming push notifications, extracts text content,
/// and stores it for the main app's anxiety analysis pipeline.
///
/// This extension runs in the background automatically whenever a notification
/// is delivered — no user interaction required.
class NotificationService: UNNotificationServiceExtension {

    private let appGroupID = "group.com.screenmind.app"
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    // MARK: - Extension lifecycle

    override func didReceive(_ request: UNNotificationRequest,
                             with contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        // Extract text from notification body + title
        let notificationText = [content.title, content.subtitle, content.body]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Store for main app to analyse
        storeNotificationText(notificationText)

        // Pass notification through unmodified
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttemptContent {
            handler(content)
        }
    }

    // MARK: - App Group storage

    private func storeNotificationText(_ text: String) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        // Append to a ring buffer of recent notification texts (keep last 20)
        var recent = defaults.array(forKey: "recent_notification_texts") as? [String] ?? []
        recent.append(text)
        if recent.count > 20 { recent.removeFirst(recent.count - 20) }
        defaults.set(recent, forKey: "recent_notification_texts")
        defaults.set(Date().timeIntervalSince1970, forKey: "last_notification_timestamp")
    }
}
