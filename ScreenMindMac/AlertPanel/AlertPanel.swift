// =============================================================================
//  AlertPanel.swift
//  ScreenMindMac — Mac 端主应用
// =============================================================================
//
//  【里程碑 M8-Mac：焦虑提醒浮窗（SwiftUI）】
//
//  【产品需求：这个文件解决什么问题？】
//  当 ScreenMind 检测到焦虑时，它不只是发一条系统通知（那太简单了）。
//  M8 在菜单栏图标旁边弹出一个精美的浮窗（Popover），展示：
//
//    区域 1：焦虑状态摘要
//      - 当前焦虑分（配合颜色，视觉直观）
//      - 如果是账号触发：显示账号名 + 风格描述
//      - 当前 HRV 状态（身体状态指示器）
//
//    区域 2（Module 1）：个人预设放松建议
//      - 来自 SuggestionEngine 的 topSuggestions()
//      - 每条建议有"立即下单"按钮（调用 ComputerUseOrderAgent）
//      - 地点类建议显示车程信息
//
//    区域 3（Module 2）：养生达人最新建议
//      - 来自 InfluencerTracker 的 freshTips()
//      - 显示达人名 + 建议内容 + 可靠性评分
//      - 点击可跳转到原帖
//
//  【技术选型：SwiftUI Popover】
//  SwiftUI 是苹果的现代 UI 框架（2019 年推出），比 AppKit 代码少很多。
//  Popover（浮窗）= 点击菜单栏图标时从图标位置弹出的小窗口。
//
//  【架构】
//  AlertPanel 是一个 SwiftUI View（视图），
//  由 AlertPanelController（AppKit 控制器）管理它的显示/隐藏。
//  StatusBarController 在 handleAnxietyAlert() 里调用 AlertPanelController.show()。
//
//  【状态管理：@StateObject 和 AlertPanelViewModel】
//  AlertPanel 的数据（建议列表、下单状态）放在 AlertPanelViewModel 里。
//  SwiftUI 通过 @StateObject / @ObservedObject 在数据变化时自动刷新 UI。
//  "数据变 → 视图自动更新"是 SwiftUI 的核心设计哲学。
//
//  【部署位置】
//  ScreenMindMac/AlertPanel/AlertPanel.swift
//  仅 Mac 端（SwiftUI Popover 绑定菜单栏图标是 macOS 特有功能）
//
// =============================================================================

import SwiftUI         // SwiftUI 视图框架（Apple 现代 UI 框架）
import ScreenMindCore  // SuggestionEngine、InfluencerTracker、ComputerUseOrderAgent、SuggestionItem
import OSLog           // 结构化日志

private let logger = Logger(subsystem: "com.screenmind.mac", category: "AlertPanel")

// =============================================================================
// MARK: - ViewModel：AlertPanel 的数据中心
// =============================================================================

/// AlertPanel 的数据模型（ViewModel 模式）。
///
/// 【什么是 ViewModel？】
/// 视图（View）只负责"显示"，它不直接访问数据库或调用 API。
/// ViewModel 负责"准备数据"：从数据库读取、格式化、提供给视图。
/// 视图只需要"订阅" ViewModel，数据变了视图自动刷新。
///
/// 【@MainActor 说明】
/// AlertPanelViewModel 的所有 @Published 属性必须在主线程修改（AppKit/SwiftUI 要求）。
/// @MainActor 标注类，确保所有方法默认在主线程执行。
///
/// 【ObservableObject 是什么？】
/// SwiftUI 的数据绑定协议。
/// 实现了这个协议的类，当它的 @Published 属性变化时，
/// 所有 @StateObject/@ObservedObject 持有它的 SwiftUI 视图会自动刷新。
@MainActor
final class AlertPanelViewModel: ObservableObject {

    // MARK: - 焦虑状态数据 ────────────────────────────────────────────────────

    /// 当前焦虑分（来自 AnxietyPipeline，0.0–1.0）
    @Published var anxietyScore: Double = 0.0

    /// 触发本次弹窗的动态阈值
    @Published var threshold: Double = 0.60

    /// 如果是账号触发：检测到的账号名（nil = 纯内容触发）
    @Published var detectedAccountName: String? = nil

    /// 账号风格描述（由 AccountAssessor 提供）
    @Published var accountStyleNotes: String = ""

    /// HRV 状态描述（如 "HRV 偏低，身体有压力" / "HRV 正常"）
    @Published var hrvStatusText: String = ""

    /// HRV 乘数（供调试信息展示）
    @Published var hrvMultiplier: Double = 1.0

    // MARK: - Module 1 数据 ───────────────────────────────────────────────────

    /// Module 1：个人预设放松建议列表
    @Published var module1Suggestions: [SuggestionItem] = []

    /// 正在执行下单的建议 ID（显示 loading 动画）
    @Published var orderingItemID: UUID? = nil

    /// 最新下单状态
    @Published var orderState: OrderFlowState = .idle

    // MARK: - Module 2 数据 ───────────────────────────────────────────────────

    /// Module 2：养生达人最新建议列表
    @Published var module2Tips: [InfluencerTip] = []

    // MARK: - 加载状态 ────────────────────────────────────────────────────────

    /// 是否正在加载数据（显示 ProgressView 占位）
    @Published var isLoading: Bool = false

    // MARK: - 内部引用 ────────────────────────────────────────────────────────

    private let suggestionEngine = SuggestionEngine()
    private let influencerTracker = InfluencerTracker()
    let orderAgent = ComputerUseOrderAgent()

    // MARK: - 初始化 ──────────────────────────────────────────────────────────

    init() {
        // 监听下单状态变化，更新 @Published var orderState
        orderAgent.onStateChanged = { [weak self] state in
            // onStateChanged 在主线程触发（ComputerUseOrderAgent 是 @MainActor）
            self?.orderState = state

            // 下单完成或失败时，清空 orderingItemID（停止 loading 动画）
            switch state {
            case .completed, .failed:
                self?.orderingItemID = nil
            default:
                break
            }
        }
    }

    // MARK: - 数据加载 ────────────────────────────────────────────────────────

    /// 刷新所有建议数据（弹窗打开时调用）。
    ///
    /// - Parameters:
    ///   - anxietyResult: AnxietyPipeline 产生的完整结果
    ///   - accountResult: 如果是账号触发，传入账号检测结果（可选）
    func refresh(anxietyScore: Double,
                 threshold: Double,
                 hrvMultiplier: Double,
                 accountResult: AccountDetectionResult? = nil) async {
        // 更新焦虑状态数据
        self.anxietyScore  = anxietyScore
        self.threshold     = threshold
        self.hrvMultiplier = hrvMultiplier

        // 账号触发信息
        self.detectedAccountName = accountResult?.detectedAccountName
        self.accountStyleNotes   = accountResult?.styleNotes ?? ""

        // HRV 状态描述（根据乘数判断）
        self.hrvStatusText = describeHRV(multiplier: hrvMultiplier)

        // 加载建议数据（异步）
        isLoading = true

        async let suggestions = suggestionEngine.topSuggestions(maxPerCategory: 2)
        async let tips = influencerTracker.freshTips(limit: 3)

        // await 等待两个异步任务同时完成（并发执行，更快）
        let (s, t) = await (suggestions, tips)

        module1Suggestions = s
        module2Tips        = t
        isLoading          = false
    }

    // MARK: - 下单操作 ────────────────────────────────────────────────────────

    /// 用户点击某条 Module 1 建议的"下单"按钮。
    func placeOrder(for suggestion: SuggestionItem) {
        orderingItemID = suggestion.id  // 显示 loading
        Task {
            await orderAgent.launchOrder(for: suggestion)
        }
    }

    // MARK: - 内部工具 ────────────────────────────────────────────────────────

    /// 根据 HRV 乘数生成用户友好的状态描述。
    ///
    /// 乘数 < 0.7 → 身体压力较大（HRV 低）
    /// 乘数 0.7–1.0 → 身体偏紧张
    /// 乘数 1.0–1.2 → 正常
    /// 乘数 > 1.2 → 身体状态良好（HRV 高）
    private func describeHRV(multiplier: Double) -> String {
        switch multiplier {
        case ..<0.7:  return "⚠️ HRV 偏低，身体承受压力，今天更需要放松"
        case 0.7..<1.0: return "🟡 HRV 偏低，建议减少信息摄入"
        case 1.0...1.2: return "🟢 HRV 正常，身体状态稳定"
        default:        return "💚 HRV 较高，身体状态良好"
        }
    }
}

// =============================================================================
// MARK: - 主视图：AlertPanel
// =============================================================================

/// 焦虑提醒浮窗的主 SwiftUI 视图。
///
/// 【View 协议是什么？】
/// SwiftUI 里所有视图都实现 View 协议，要求提供一个 `body` 计算属性（描述视图内容）。
/// `body` 里是视图的描述（声明式 UI），不是命令式的"执行这一步"。
///
/// 【声明式 UI 的含义】
/// 你告诉 SwiftUI "这个界面应该长什么样"，而不是"怎么一步步画它"。
/// 当数据变化时，SwiftUI 自动计算最小更新量，只刷新需要改变的部分。
struct AlertPanel: View {

    // @StateObject：创建并持有 ViewModel，视图销毁时 ViewModel 也销毁
    // 只在视图第一次创建时初始化，后续重建视图时复用同一个实例
    @StateObject private var viewModel = AlertPanelViewModel()

    // 弹窗显示时需要的初始数据（从 StatusBarController 传入）
    let initialAnxietyScore: Double
    let initialThreshold: Double
    let initialHRVMultiplier: Double
    let initialAccountResult: AccountDetectionResult?

    // 关闭浮窗的回调（用户点"关闭"按钮时调用）
    var onDismiss: (() -> Void)?

    // MARK: - 视图主体 ────────────────────────────────────────────────────────

    /// 视图的内容描述（SwiftUI 要求实现这个 body 属性）
    var body: some View {
        // VStack：垂直排列的容器（子视图从上到下排列）
        // spacing：子视图之间的间距
        VStack(alignment: .leading, spacing: 0) {

            // ── 顶部标题栏 ────────────────────────────────────────────────
            headerSection

            // ── 焦虑状态摘要区 ────────────────────────────────────────────
            anxietySummarySection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            // ── 分隔线 ────────────────────────────────────────────────────
            Divider()

            if viewModel.isLoading {
                // 数据加载中：显示进度动画
                loadingView

            } else {
                // ScrollView：当内容超过固定高度时可以滚动
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {

                        // ── Module 1：个人预设建议 ────────────────────────
                        if !viewModel.module1Suggestions.isEmpty {
                            module1Section
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        }

                        // ── 分隔线（如果两个模块都有数据） ───────────────
                        if !viewModel.module1Suggestions.isEmpty &&
                           !viewModel.module2Tips.isEmpty {
                            Divider()
                                .padding(.vertical, 8)
                        }

                        // ── Module 2：养生达人建议 ────────────────────────
                        if !viewModel.module2Tips.isEmpty {
                            module2Section
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }

                        // 两个模块都没有数据（空状态）
                        if viewModel.module1Suggestions.isEmpty &&
                           viewModel.module2Tips.isEmpty {
                            emptyStateView
                        }
                    }
                }
                .frame(maxHeight: 400) // 限制最大高度，超出时可滚动
            }

            // ── 底部操作栏 ────────────────────────────────────────────────
            Divider()
            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 360)  // 浮窗固定宽度
        .background(Color(NSColor.windowBackgroundColor))  // 跟随系统主题的背景色

        // .task { } 等同于 onAppear + 异步执行
        // 视图出现时加载数据
        .task {
            await viewModel.refresh(
                anxietyScore: initialAnxietyScore,
                threshold: initialThreshold,
                hrvMultiplier: initialHRVMultiplier,
                accountResult: initialAccountResult
            )
        }
    }

    // MARK: - 子视图：顶部标题栏 ──────────────────────────────────────────────

    /// 浮窗顶部：标题 + 关闭按钮
    private var headerSection: some View {
        HStack {
            // 大脑图标（SF Symbols）
            Image(systemName: "brain.head.profile.fill")
                .foregroundColor(.red)
                .font(.system(size: 16))

            Text("ScreenMind — 放松一下")
                .font(.headline)
                .foregroundColor(.primary)

            Spacer()  // 把关闭按钮推到右边

            // 关闭按钮
            Button(action: { onDismiss?() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)  // 去掉 macOS 默认按钮样式
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - 子视图：焦虑状态摘要 ────────────────────────────────────────────

    /// 显示当前焦虑分、账号信息、HRV 状态
    private var anxietySummarySection: some View {
        VStack(alignment: .leading, spacing: 6) {

            // 焦虑分数 + 颜色指示
            HStack(alignment: .center, spacing: 8) {
                // 圆形颜色指示器
                Circle()
                    .fill(anxietyColor(score: viewModel.anxietyScore))
                    .frame(width: 12, height: 12)

                Text("焦虑指数")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // 百分比数字
                Text("\(Int(viewModel.anxietyScore * 100))%")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(anxietyColor(score: viewModel.anxietyScore))

                Spacer()

                // HRV 状态小标签
                Text(viewModel.hrvStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            // 如果是账号触发，显示账号信息
            if let accountName = viewModel.detectedAccountName {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("@\(accountName)")
                        .font(.caption)
                        .foregroundColor(.orange)
                    if !viewModel.accountStyleNotes.isEmpty {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(viewModel.accountStyleNotes)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - 子视图：Module 1（个人建议）────────────────────────────────────

    /// Module 1 区域：标题 + 建议卡片列表
    private var module1Section: some View {
        VStack(alignment: .leading, spacing: 8) {

            // 模块标题
            Label("放松建议", systemImage: "heart.text.square.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)

            // 建议卡片列表
            // ForEach 是 SwiftUI 的循环视图，类似 for...in 但生成视图
            ForEach(viewModel.module1Suggestions) { suggestion in
                SuggestionCard(
                    suggestion: suggestion,
                    isOrdering: viewModel.orderingItemID == suggestion.id,
                    orderState: viewModel.orderState,
                    onOrderTapped: {
                        viewModel.placeOrder(for: suggestion)
                    }
                )
            }
        }
    }

    // MARK: - 子视图：Module 2（达人建议）────────────────────────────────────

    /// Module 2 区域：标题 + 达人建议卡片
    private var module2Section: some View {
        VStack(alignment: .leading, spacing: 8) {

            // 模块标题
            Label("达人推荐", systemImage: "star.bubble.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)

            // InfluencerTip 列表
            // 注意：InfluencerTip 是 Core Data NSManagedObject，有 id 属性供 ForEach 识别
            ForEach(viewModel.module2Tips, id: \.id) { tip in
                InfluencerTipCard(tip: tip)
            }
        }
    }

    // MARK: - 子视图：加载中 ──────────────────────────────────────────────────

    private var loadingView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                ProgressView()  // macOS 转圈动画
                Text("正在加载放松建议…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(24)
            Spacer()
        }
    }

    // MARK: - 子视图：空状态 ──────────────────────────────────────────────────

    private var emptyStateView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("暂无建议")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("去设置里添加你喜欢的放松方式")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(24)
            Spacer()
        }
    }

    // MARK: - 子视图：底部操作栏 ──────────────────────────────────────────────

    private var bottomBar: some View {
        HStack {
            // 暂停监控按钮（快速操作）
            Button("暂停 15 分钟") {
                // 通知 StatusBarController 暂停
                NotificationCenter.default.post(
                    name: NSNotification.Name("com.screenmind.pauseRequested"),
                    object: nil,
                    userInfo: ["minutes": 15]
                )
                onDismiss?()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            // 关闭按钮
            Button("知道了") {
                onDismiss?()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: - 工具方法 ────────────────────────────────────────────────────────

    /// 根据焦虑分返回对应的颜色（视觉反馈）。
    ///
    /// < 50%：绿色（轻度）
    /// 50–70%：橙色（中度）
    /// > 70%：红色（高度）
    private func anxietyColor(score: Double) -> Color {
        if score < 0.5 { return .green }
        if score < 0.7 { return .orange }
        return .red
    }
}

// =============================================================================
// MARK: - 子组件：SuggestionCard（Module 1 建议卡片）
// =============================================================================

/// 一条 Module 1 放松建议的卡片视图。
///
/// 显示：分类图标、标题、详情、车程（地点类）、下单按钮（服务类）
private struct SuggestionCard: View {

    let suggestion: SuggestionItem
    let isOrdering: Bool        // 这张卡片是否正在执行下单（显示 loading）
    let orderState: OrderFlowState  // 当前下单状态（用于显示状态文字）
    let onOrderTapped: () -> Void  // 点击"下单"时的回调

    var body: some View {
        HStack(alignment: .top, spacing: 10) {

            // 分类图标
            Image(systemName: suggestion.category.symbolName)
                .font(.system(size: 20))
                .foregroundColor(categoryColor(suggestion.category))
                .frame(width: 28, alignment: .center)

            // 建议内容
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)

                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                // 地点类：显示车程信息
                if suggestion.category == .place,
                   let minutes = suggestion.travelMinutes {
                    Label("约 \(minutes) 分钟车程", systemImage: "car.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // 下单状态文字（仅当这张卡片正在下单时显示）
                if isOrdering {
                    orderStatusLabel
                }
            }

            Spacer()

            // 右侧操作按钮
            actionButton
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
    }

    /// 下单按钮或地图按钮
    @ViewBuilder
    private var actionButton: some View {
        if suggestion.serviceConfig != nil {
            // 线上服务：显示"下单"按钮
            if isOrdering {
                // 下单中：显示 ProgressView
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 44)
            } else {
                Button("下单") {
                    onOrderTapped()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(categoryColor(suggestion.category))
            }
        } else if suggestion.category == .place {
            // 地点类：显示"导航"按钮
            Button(action: openInMaps) {
                Label("导航", systemImage: "map.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    /// 下单状态文字标签
    @ViewBuilder
    private var orderStatusLabel: some View {
        switch orderState {
        case .launching:
            Label("正在打开浏览器…", systemImage: "safari")
                .font(.caption)
                .foregroundColor(.blue)
        case .browserOpened:
            Label("浏览器已打开", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .agentNavigating(let step):
            Label(step, systemImage: "gearshape.2.fill")
                .font(.caption)
                .foregroundColor(.orange)
        case .readyForPayment(let pkg):
            Label("已选好"\(pkg)"，请完成支付", systemImage: "creditcard.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
        default:
            EmptyView()  // idle / completed：不显示状态文字
        }
    }

    /// 在苹果地图 App 里打开地址
    private func openInMaps() {
        guard let address = suggestion.address else { return }
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? address
        if let url = URL(string: "maps://?q=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 分类对应的颜色
    private func categoryColor(_ category: SuggestionCategory) -> Color {
        switch category {
        case .place:         return .green
        case .fitness:       return .orange
        case .course:        return .blue
        case .food:          return .red
        case .entertainment: return .purple
        case .homeService:   return .teal
        }
    }
}

// =============================================================================
// MARK: - 子组件：InfluencerTipCard（Module 2 达人建议卡片）
// =============================================================================

/// 一条 Module 2 养生达人建议的卡片视图。
///
/// 显示：达人名、建议内容、置信度指示器、查看原帖链接
private struct InfluencerTipCard: View {

    /// InfluencerTip 是 Core Data 的 NSManagedObject
    let tip: InfluencerTip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // 达人名 + 置信度
            HStack {
                // 达人名标签
                Label(tip.influencerName ?? "未知达人", systemImage: "person.fill.checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Spacer()

                // 置信度标签（显示为小圆点）
                confidenceBadge(score: tip.confidenceScore)
            }

            // 行动标题
            Text(tip.actionTitle ?? "")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)

            // 建议摘要
            Text(tip.processedTip ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)  // 最多显示 3 行

            // 原帖链接（如果有）
            if let urlString = tip.sourceURL,
               let url = URL(string: urlString) {
                Link("查看原帖 →", destination: url)
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
    }

    /// 置信度小标签（根据分数显示不同颜色和文字）
    @ViewBuilder
    private func confidenceBadge(score: Double) -> some View {
        let (text, color): (String, Color) = {
            if score >= 0.8 { return ("高可靠", .green) }
            if score >= 0.6 { return ("中可靠", .orange) }
            return ("仅参考", .secondary)
        }()

        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }
}

// =============================================================================
// MARK: - AlertPanelController（AppKit 控制器，管理 SwiftUI 浮窗的显示）
// =============================================================================

/// 管理 AlertPanel SwiftUI 视图的显示和关闭。
///
/// 【为什么需要这个 AppKit 包装层？】
/// ScreenMindMac 是 AppKit 应用（MenuBar App）。
/// SwiftUI Popover 需要绑定到 NSStatusItem（菜单栏图标）。
/// NSHostingController 是"把 SwiftUI View 嵌入 AppKit 视图层级"的桥接器。
///
/// 【NSPopover 是什么？】
/// macOS 的 Popover 是从某个 "anchor view"（锚点）弹出的浮窗。
/// 这里的锚点是菜单栏图标的按钮（statusItem.button）。
@MainActor
final class AlertPanelController {

    // MARK: - 属性 ────────────────────────────────────────────────────────────

    /// macOS 内置 Popover 控制器
    private var popover: NSPopover?

    /// 最后一次展示时的焦虑数据（供 AlertPanel 刷新时使用）
    private var lastAnxietyScore: Double = 0
    private var lastThreshold: Double = 0.6
    private var lastHRVMultiplier: Double = 1.0
    private var lastAccountResult: AccountDetectionResult? = nil

    // MARK: - 显示浮窗 ────────────────────────────────────────────────────────

    /// 在菜单栏图标旁边弹出 AlertPanel。
    ///
    /// 每次展示时用最新的焦虑数据创建新的 SwiftUI 视图（确保数据是最新的）。
    ///
    /// - Parameters:
    ///   - button: 菜单栏图标按钮（作为弹出的锚点）
    ///   - anxietyScore: 当前焦虑分
    ///   - threshold: 触发阈值
    ///   - hrvMultiplier: HRV 乘数
    ///   - accountResult: 账号检测结果（可选）
    func show(from button: NSButton,
              anxietyScore: Double,
              threshold: Double,
              hrvMultiplier: Double = 1.0,
              accountResult: AccountDetectionResult? = nil) {

        // 更新缓存的数据
        lastAnxietyScore    = anxietyScore
        lastThreshold       = threshold
        lastHRVMultiplier   = hrvMultiplier
        lastAccountResult   = accountResult

        // 关闭旧的 popover（如果存在）
        popover?.close()

        // 创建新的 NSPopover
        let newPopover = NSPopover()
        newPopover.behavior = .transient  // 点击浮窗外部自动关闭

        // 创建 SwiftUI 视图（AlertPanel）
        let alertView = AlertPanel(
            initialAnxietyScore: anxietyScore,
            initialThreshold: threshold,
            initialHRVMultiplier: hrvMultiplier,
            initialAccountResult: accountResult,
            onDismiss: { [weak newPopover] in
                newPopover?.close()
            }
        )

        // NSHostingController：SwiftUI → AppKit 的桥接器
        // 把 SwiftUI View 包装成 AppKit 的 NSViewController
        let hostingController = NSHostingController(rootView: alertView)
        newPopover.contentViewController = hostingController

        // 从菜单栏按钮弹出 popover
        // .maxX：弹出位置在按钮右侧
        // .minY：弹出方向朝下
        newPopover.show(relativeTo: button.bounds,
                       of: button,
                       preferredEdge: .minY)

        self.popover = newPopover
        logger.info("AlertPanel 已显示 (score=\(String(format: "%.2f", anxietyScore)))")
    }

    /// 关闭浮窗。
    func close() {
        popover?.close()
        popover = nil
    }

    /// 浮窗是否当前显示中。
    var isShowing: Bool {
        popover?.isShown ?? false
    }
}
