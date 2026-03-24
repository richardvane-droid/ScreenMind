import SwiftUI
import ScreenMindCore

/// Root view for the ScreenMind iOS app.
/// Shows today's anxiety summary and quick controls.
struct ContentView: View {

    @State private var todayScore: Double = 0.0
    @State private var isLayer2Active: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // ── Today's anxiety gauge ──────────────────
                    AnxietyGaugeView(score: todayScore)
                        .padding(.top, 8)

                    // ── Layer 2 status ─────────────────────────
                    Layer2StatusCard(isActive: isLayer2Active)

                    // ── Navigation cards ───────────────────────
                    NavigationLink("历史记录", destination: HistoryView())
                        .buttonStyle(.bordered)
                    NavigationLink("账号档案", destination: AccountProfilesView())
                        .buttonStyle(.bordered)
                    NavigationLink("设置", destination: IOSSettingsView())
                        .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("ScreenMind")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Subviews (Skeleton)

struct AnxietyGaugeView: View {
    let score: Double
    var body: some View {
        VStack(spacing: 8) {
            Text("今日焦虑指数")
                .font(.headline)
            Text("\(Int(score * 100))%")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(score > 0.6 ? .red : score > 0.4 ? .orange : .green)
            ProgressView(value: score)
                .tint(score > 0.6 ? .red : score > 0.4 ? .orange : .green)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct Layer2StatusCard: View {
    let isActive: Bool
    var body: some View {
        HStack {
            Image(systemName: isActive ? "record.circle.fill" : "record.circle")
                .foregroundStyle(isActive ? .red : .secondary)
            Text(isActive ? "屏幕监控进行中" : "屏幕监控未激活")
                .font(.subheadline)
            Spacer()
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct HistoryView: View {
    var body: some View { Text("历史记录（M4 实现）").navigationTitle("历史") }
}

struct AccountProfilesView: View {
    var body: some View { Text("账号档案（M5 实现）").navigationTitle("账号档案") }
}

struct IOSSettingsView: View {
    var body: some View { Text("设置（M3 实现）").navigationTitle("设置") }
}

// MARK: - Preview

#Preview {
    ContentView()
}
