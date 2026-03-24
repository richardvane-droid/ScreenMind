import Foundation
import ScreenMindCore

/// Monitors the frontmost application and active window title for short-video account names.
/// When 抖音 (Douyin) or WeChat browser is in focus and an account name is detected,
/// runs AccountAssessor to evaluate the creator's anxiety profile.
final class MacAccountMonitor: @unchecked Sendable {

    private let assessor = AccountAssessor()
    private let notificationManager = NotificationManager()

    /// Anxiety score above which a notification is sent.
    var alertThreshold: Double = 0.65

    // Cache: avoid re-assessing the same account within the same session
    private var assessedThisSession: Set<String> = []

    // MARK: - Account detection from OCR text

    /// Called by ScreenCaptureManager's OCR output when the front app is 抖音/微信.
    func checkForAccount(ocrText: String, frontAppBundleID: String) {
        guard isShortVideoApp(bundleID: frontAppBundleID) else { return }
        let platform: AccountPlatform = frontAppBundleID.contains("wechat") ? .wechatMP : .douyin
        guard let accountName = extractAccountName(from: ocrText, platform: platform) else { return }
        guard !assessedThisSession.contains(accountName) else { return }
        assessedThisSession.insert(accountName)

        Task {
            let assessment = await assessor.assess(accountName: accountName, platform: platform)
            if assessment.anxietyScore > alertThreshold {
                await notificationManager.sendAccountAlert(accountName: accountName,
                                                           score: assessment.anxietyScore,
                                                           notes: assessment.styleNotes)
            }
        }
    }

    // MARK: - Helpers

    /// Bundle IDs of apps that host short-video / public-account content.
    private func isShortVideoApp(bundleID: String) -> Bool {
        let targets = ["com.douyin", "com.tencent.wechat", "com.tencent.xinWeChat"]
        return targets.contains(where: { bundleID.lowercased().contains($0) })
    }

    /// Heuristic: extract creator/account name from OCR text.
    /// Douyin: account name usually follows "@" or appears near "关注" button.
    /// WeChat: public account name appears in header area.
    private func extractAccountName(from text: String, platform: AccountPlatform) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        switch platform {
        case .douyin:
            // Look for line starting with "@" — typical Douyin creator name display
            return lines.first { $0.hasPrefix("@") }.map { String($0.dropFirst()) }
        case .wechatMP:
            // WeChat MP: article page title is usually the account name in first non-trivial line
            return lines.first { $0.count > 2 && $0.count < 30 }
        }
    }
}
