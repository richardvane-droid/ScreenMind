import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Activity Attributes

/// Live Activity attributes for Dynamic Island display.
struct AnxietyActivityAttributes: ActivityAttributes {
    public typealias ContentState = AnxietyStatus

    struct AnxietyStatus: Codable, Hashable {
        var score: Double          // 0.0 – 1.0
        var trend: String          // "rising" | "stable" | "falling"
        var isPaused: Bool
    }
}

// MARK: - Live Activity Manager

/// Manages starting, updating, and ending the Dynamic Island Live Activity.
final class AnxietyActivityManager: @unchecked Sendable {

    private var currentActivity: Activity<AnxietyActivityAttributes>?

    // MARK: - Start

    func startActivity(score: Double) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = AnxietyActivityAttributes()
        let state = AnxietyActivityAttributes.AnxietyStatus(score: score,
                                                             trend: "stable",
                                                             isPaused: false)
        let content = ActivityContent(state: state, staleDate: nil)
        currentActivity = try? Activity.request(attributes: attrs,
                                                content: content,
                                                pushType: nil)
    }

    // MARK: - Update

    func update(score: Double, trend: String) async {
        let state = AnxietyActivityAttributes.AnxietyStatus(score: score,
                                                             trend: trend,
                                                             isPaused: false)
        let content = ActivityContent(state: state, staleDate: nil)
        await currentActivity?.update(content)
    }

    // MARK: - End

    func endActivity() async {
        let state = AnxietyActivityAttributes.AnxietyStatus(score: 0.0,
                                                             trend: "stable",
                                                             isPaused: false)
        let content = ActivityContent(state: state, staleDate: nil)
        await currentActivity?.end(content, dismissalPolicy: .immediate)
        currentActivity = nil
    }
}

// MARK: - Dynamic Island View (Widget Extension companion)
// Note: The actual Live Activity views need to be in the Widget Extension target.
// This file contains the shared data model used by both the app and the extension.
