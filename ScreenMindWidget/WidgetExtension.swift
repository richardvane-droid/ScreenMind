import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Provider

struct AnxietyEntry: TimelineEntry {
    let date: Date
    let anxietyScore: Double
    let hrvStatus: String
}

struct AnxietyWidgetProvider: TimelineProvider {
    private let appGroupID = "group.com.screenmind.app"

    func placeholder(in context: Context) -> AnxietyEntry {
        AnxietyEntry(date: .now, anxietyScore: 0.3, hrvStatus: "正常")
    }

    func getSnapshot(in context: Context, completion: @escaping (AnxietyEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AnxietyEntry>) -> Void) {
        let entry = loadEntry()
        // Refresh every 15 minutes
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }

    private func loadEntry() -> AnxietyEntry {
        let defaults = UserDefaults(suiteName: appGroupID)
        let score = defaults?.double(forKey: "today_anxiety_score") ?? 0.0
        let hrv = defaults?.string(forKey: "hrv_status") ?? "—"
        return AnxietyEntry(date: .now, anxietyScore: score, hrvStatus: hrv)
    }
}

// MARK: - Widget View

struct AnxietyWidgetView: View {
    var entry: AnxietyEntry
    @Environment(\.widgetFamily) var family

    var scoreColor: Color {
        entry.anxietyScore > 0.6 ? .red :
        entry.anxietyScore > 0.4 ? .orange : .green
    }

    var body: some View {
        switch family {
        case .systemSmall, .accessoryCircular:
            smallView
        case .accessoryRectangular:
            rectangularView
        default:
            smallView
        }
    }

    private var smallView: some View {
        VStack(spacing: 4) {
            Text("焦虑指数")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(Int(entry.anxietyScore * 100))%")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(scoreColor)
            Text("HRV \(entry.hrvStatus)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private var rectangularView: some View {
        HStack {
            Text("焦虑 \(Int(entry.anxietyScore * 100))%")
                .font(.headline)
                .foregroundStyle(scoreColor)
            Spacer()
            Text("HRV \(entry.hrvStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

// MARK: - Widget Bundle

@main
struct ScreenMindWidgetBundle: WidgetBundle {
    var body: some Widget {
        ScreenMindWidget()
    }
}

struct ScreenMindWidget: Widget {
    let kind = "ScreenMindAnxietyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AnxietyWidgetProvider()) { entry in
            AnxietyWidgetView(entry: entry)
        }
        .configurationDisplayName("ScreenMind")
        .description("今日焦虑指数与 HRV 状态")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    ScreenMindWidget()
} timeline: {
    AnxietyEntry(date: .now, anxietyScore: 0.45, hrvStatus: "良好")
    AnxietyEntry(date: .now, anxietyScore: 0.72, hrvStatus: "偏低")
}
