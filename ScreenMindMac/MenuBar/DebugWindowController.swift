// =============================================================================
//  DebugWindowController.swift
//  ScreenMindMac — Mac 端主应用
// =============================================================================
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenMind 在后台静默运行，开发者（和进阶用户）需要一种方式来：
//    - 实时查看 OCR 识别了哪些文字
//    - 确认焦虑评分是否合理
//    - 调试动态阈值是否按预期工作
//    - 查看哪些 App 产生了高焦虑评分
//
//  这个"调试窗口"就是专门为此目的设计的工具窗口（类似浏览器的 DevTools）。
//
//  【窗口外观（UI 布局描述）】
//  ┌─────────────────────────────────────────────────────────────────┐
//  │  共 47 条 | 最近: Safari — score 0.34 / threshold 0.61    [清空] │ ← 状态栏
//  ├─────────────────────────────────────────────────────────────────┤
//  │  焦虑指数：[████████████░░░░░░░░] 0.72 [LLM] 🔴ALERT             │ ← 分数条
//  ├─────────────────────────────────────────────────────────────────┤
//  │  ── [14:30:25]  微信  lang=zh  1234字  87ms                      │
//  │     anxiety=0.72/0.65 [LLM] ⚠️ ──                               │ ← 日志区
//  │  关键词：股市暴跌、失业率、经济危机                                 │
//  │  以下是识别出的文字……（最多 300 字的预览）                          │
//  │                                                                  │
//  │  ── [14:31:01]  Safari  lang=en  543字  12ms                     │
//  │     anxiety=0.31/0.61 [NL] ──                                   │
//  │  今天天气真好……                                                   │
//  └─────────────────────────────────────────────────────────────────┘
//
//  【M3 更新内容（相比 M2）】
//  M2：只显示 OCR 文字和语言/时间信息。
//  M3：新增顶部焦虑分数进度条 + 每条日志旁边显示焦虑分/阈值/来源/关键词。
//
//  【M4 更新内容（相比 M3）】
//  M4：日志标题行新增 "hrv×乘数" 字段，例如：
//    anxiety=0.72/0.61 [LLM] hrv×0.75 ⚠️
//                             ↑ M4 新增
//  帮助开发者理解：最终阈值 = 文本阈值 × HRV乘数（这里 0.61 已经是相乘后的结果）
//  HRV乘数 = 1.0 表示没有 HRV 数据（Level 4），阈值仅由文本决定。
//
//  【部署位置】
//  ScreenMindMac/MenuBar/DebugWindowController.swift
//  这是纯 Mac 端文件，iOS 端不需要调试窗口。
//
//  【初学者：NSWindowController 是什么？】
//  NSWindowController 是 macOS 的窗口控制器基类，负责管理一个 NSWindow 的生命周期。
//  我们继承它，实现自己的调试窗口。
//
// =============================================================================

import AppKit         // macOS 界面框架，提供 NSWindow、NSTextView、NSProgressIndicator 等
import ScreenMindCore // 共享包，提供 AnxietyResult 等数据类型

/// 调试窗口控制器。
/// 显示实时 OCR + 焦虑评分日志，供开发调试使用。
///
/// 使用时机：用户点击菜单栏 → "OCR / 焦虑调试窗口"，弹出本窗口。
/// 关闭后不销毁（isReleasedWhenClosed = false），再次打开时继续显示历史日志。
final class DebugWindowController: NSWindowController {

    // MARK: - UI 组件声明 ──────────────────────────────────────────────────

    /// 底部状态文字（显示总条数 + 最近一帧的摘要）。
    /// NSTextField(labelWithString:) 创建只读文本标签。
    private var statusLabel: NSTextField!

    /// 实时焦虑分数进度条（顶部那条彩色进度条）。
    private var scoreBar: NSProgressIndicator!

    /// 进度条右边的数字标签（如 "0.72 [LLM] 🔴ALERT"）。
    private var scoreValueLabel: NSTextField!

    /// 日志文本区（可滚动、不可编辑的文本视图）。
    private var textView: NSTextView!

    // MARK: - 状态变量 ────────────────────────────────────────────────────

    /// 已记录的总条数（用于显示 "共 N 条"）。
    private var entryCount = 0

    /// 最大记录条数（超出时删掉最旧的，防止窗口占用过多内存）。
    private let maxEntries = 200

    // MARK: - 初始化 ──────────────────────────────────────────────────────

    init() {
        // 创建窗口（大小、样式都在这里定义）
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), // 初始大小 720x540
            styleMask: [
                .titled,        // 有标题栏
                .closable,      // 有关闭按钮
                .resizable,     // 可以调整大小
                .miniaturizable // 可以最小化
            ],
            backing: .buffered, // 双缓冲渲染（防止闪烁）
            defer: false        // 立刻创建，不延迟
        )
        window.title = "ScreenMind — OCR / 焦虑调试"
        window.center() // 居中显示
        window.isReleasedWhenClosed = false // 关闭时不销毁，下次再打开可以继续看

        super.init(window: window) // 调用父类 NSWindowController 的初始化
        setupUI() // 构建窗口内的所有 UI 元素
    }

    // NSWindowController 要求这个初始化器，我们不需要用 Storyboard，所以直接 fatalError
    required init?(coder: NSCoder) { fatalError("使用代码初始化，不支持 Storyboard") }

    // MARK: - UI 布局 ──────────────────────────────────────────────────────

    /// 构建窗口内部的所有 UI 控件，并设置自动布局约束。
    ///
    /// 【Auto Layout 简述】
    /// iOS/macOS 的界面不能用固定像素坐标（不同分辨率/窗口大小要适配）。
    /// Auto Layout 通过"约束"描述元素之间的位置关系：
    ///   "按钮的左边距 = 父视图左边 + 12 点"
    ///   "进度条的宽度 = 右标签左边 - 左标签右边 - 12 点"
    /// macOS 用 NSLayoutConstraint.activate([...]) 批量激活约束。
    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // ── 状态标签（左上角）──────────────────────────────────────────
        statusLabel = NSTextField(labelWithString: "等待 OCR 输出…")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false  // 使用 Auto Layout（不用 frame）
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular) // 等宽字体（对齐美观）
        statusLabel.textColor = .secondaryLabelColor // 灰色（次要信息）
        contentView.addSubview(statusLabel)

        // ── 清空按钮（右上角）──────────────────────────────────────────
        let clearButton = NSButton(title: "清空", target: self, action: #selector(clearLog))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .rounded // macOS 标准圆角按钮样式
        contentView.addSubview(clearButton)

        // ── 焦虑分数行容器（状态标签下方）─────────────────────────────
        // 用一个透明的 NSView 作为行容器，方便设置约束
        let scoreRowView = NSView()
        scoreRowView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scoreRowView)

        // 分数行的三个子元素：左侧标题 + 中间进度条 + 右侧数值
        let scoreTitleLabel = NSTextField(labelWithString: "焦虑指数：")
        scoreTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        scoreTitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        scoreRowView.addSubview(scoreTitleLabel)

        // NSProgressIndicator：苹果内置的进度条控件
        scoreBar = NSProgressIndicator()
        scoreBar.translatesAutoresizingMaskIntoConstraints = false
        scoreBar.style = .bar      // 水平进度条样式（区别于 spinning wheel）
        scoreBar.minValue = 0      // 最小值 0
        scoreBar.maxValue = 100    // 最大值 100（我们把 0-1 的分数乘以 100 来显示）
        scoreBar.doubleValue = 0   // 初始值
        scoreBar.isIndeterminate = false // 有确定数值（不是那种转圈圈的不确定进度条）
        scoreRowView.addSubview(scoreBar)

        scoreValueLabel = NSTextField(labelWithString: "—")
        scoreValueLabel.translatesAutoresizingMaskIntoConstraints = false
        scoreValueLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold) // 粗一点，显眼
        scoreValueLabel.alignment = .right // 右对齐
        scoreRowView.addSubview(scoreValueLabel)

        // ── 日志文本区（可滚动）────────────────────────────────────────
        // NSScrollView 是一个可滚动的容器，里面放 NSTextView
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true     // 有垂直滚动条
        scrollView.hasHorizontalScroller = false  // 没有水平滚动条（内容自动换行）
        scrollView.autohidesScrollers = true       // 没内容时滚动条自动隐藏
        scrollView.borderType = .bezelBorder       // macOS 内嵌边框样式
        contentView.addSubview(scrollView)

        // NSTextView：富文本编辑器（我们只用它来显示，设置不可编辑）
        textView = NSTextView()
        textView.isEditable = false   // 只读（不允许用户修改）
        textView.isSelectable = true  // 允许用户选中文本（可以复制）
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = .textBackgroundColor // 跟随系统主题（深色模式自动变深）
        textView.textContainerInset = NSSize(width: 8, height: 8) // 内边距（防止文字贴边）
        scrollView.documentView = textView // 把 textView 放进滚动区

        // ── Auto Layout 约束 ────────────────────────────────────────────
        // NSLayoutConstraint.activate 批量激活约束（一次性，高效）
        NSLayoutConstraint.activate([
            // 状态标签：左上角，距顶部 10pt，距左边 12pt
            statusLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),

            // 清空按钮：与状态标签垂直居中，右边距 12pt
            clearButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            // 分数行：在状态标签下方 6pt，左右各 12pt，高度固定 22pt
            scoreRowView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scoreRowView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scoreRowView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scoreRowView.heightAnchor.constraint(equalToConstant: 22),

            // 分数行内部：标题 | 进度条 | 数值  （弹性中间，两端固定宽）
            scoreTitleLabel.leadingAnchor.constraint(equalTo: scoreRowView.leadingAnchor),
            scoreTitleLabel.centerYAnchor.constraint(equalTo: scoreRowView.centerYAnchor),
            scoreTitleLabel.widthAnchor.constraint(equalToConstant: 72), // 固定宽 72pt

            scoreValueLabel.trailingAnchor.constraint(equalTo: scoreRowView.trailingAnchor),
            scoreValueLabel.centerYAnchor.constraint(equalTo: scoreRowView.centerYAnchor),
            scoreValueLabel.widthAnchor.constraint(equalToConstant: 80), // 固定宽 80pt

            // 进度条填满中间剩余空间
            scoreBar.leadingAnchor.constraint(equalTo: scoreTitleLabel.trailingAnchor, constant: 6),
            scoreBar.trailingAnchor.constraint(equalTo: scoreValueLabel.leadingAnchor, constant: -6),
            scoreBar.centerYAnchor.constraint(equalTo: scoreRowView.centerYAnchor),

            // 滚动文本区：占满分数行以下的全部空间
            scrollView.topAnchor.constraint(equalTo: scoreRowView.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - 核心方法：追加一条日志记录 ──────────────────────────────────

    /// 追加一帧分析结果到调试窗口（M3 版本：包含 OCR + 焦虑评分）。
    ///
    /// 这是外部唯一的公开方法。
    /// 由 StatusBarController 的 anxietyPipeline.onScore 回调触发。
    ///
    /// 每次调用会做三件事：
    ///   1. 更新顶部分数进度条（实时反映最新分数）
    ///   2. 向日志文本区追加一条彩色格式化记录
    ///   3. 更新底部状态标签
    ///
    /// - Parameter result: AnxietyPipeline 产生的完整分析结果
    func appendEntry(_ result: AnxietyPipelineResult) {
        // 解包常用的子字段（让下面的代码更简洁）
        let ocr       = result.pipeline.ocrResult  // OCR 结果
        let anxiety   = result.anxiety              // 焦虑评分结果
        let threshold = result.dynamicThreshold    // 本帧使用的阈值
        let alerted   = result.didTriggerAlert     // 是否触发了提醒

        entryCount += 1 // 计数 +1

        // ── 更新顶部分数进度条 ───────────────────────────────────────────
        let scorePercent = anxiety.score * 100  // 0–1 → 0–100（进度条用百分制）
        scoreBar.doubleValue = scorePercent
        // 根据分数和阈值的比例设置进度条颜色
        scoreBar.contentTintColor = scoreBarColor(for: anxiety.score, threshold: threshold)

        // 分数标签文字，例如 "72% [LLM] 🔴ALERT" 或 "34% [NL]"
        let srcTag = anxiety.source == .ollama ? "LLM" : "NL" // 评分来源缩写
        let alertTag = alerted ? " 🔴ALERT" : ""              // 触发提醒时加红色标记
        scoreValueLabel.stringValue = String(format: "%.0f%% [\(srcTag)]\(alertTag)", scorePercent)

        // ── 构建日志条目（NSAttributedString 富文本）────────────────────
        // 获取各字段的显示文字
        let time  = DateFormatter.localizedString(from: ocr.timestamp,
                                                  dateStyle: .none,
                                                  timeStyle: .medium) // 只显示时间，不显示日期
        let app   = result.pipeline.frontAppName ?? "?"   // 当时的前景 App
        let lang  = ocr.language.rawValue                 // 语言代码（"zh"/"en"/"mixed"）
        let ms    = ocr.durationMs                        // OCR 耗时（毫秒）
        let chars = ocr.text.count                        // 识别字数

        let scoreStr  = String(format: "%.2f", anxiety.score)       // 格式化分数，保留 2 位小数
        let threshStr = String(format: "%.2f", threshold)           // 格式化阈值
        let alertMark = alerted ? " ⚠️" : ""                       // 触发提醒标记

        // M4 新增：HRV 乘数信息（供开发者理解阈值的构成）
        // result.hrvMultiplier 是本帧使用的 HRV 乘数（由 HRVIntegrator 计算）
        // 格式：hrv×0.75（如果乘数明显偏离 1.0，用颜色区分）
        let hrvMult   = result.hrvMultiplier                         // 从 AnxietyPipelineResult 取
        let hrvStr    = String(format: "hrv×%.2f", hrvMult)         // 格式化：hrv×0.75

        // 标题行文字（一行摘要，M4 新增 HRV 乘数字段）
        // 格式：── [14:30:25]  微信  lang=zh  1234字  87ms  anxiety=0.72/0.61 [LLM] hrv×0.75 ⚠️ ──
        let header = "── [\(time)]  \(app)  lang=\(lang)  \(chars)字  \(ms)ms  " +
                     "anxiety=\(scoreStr)/\(threshStr) [\(srcTag)] \(hrvStr)\(alertMark) ──\n"

        // 关键词行（只有 Ollama Stage 2 才会有关键词）
        var keywordLine = ""
        if !anxiety.dominantKeywords.isEmpty {
            keywordLine = "关键词：\(anxiety.dominantKeywords.joined(separator: "、"))\n"
            // joined(separator:) 把数组元素用分隔符连接成字符串
        }

        // 文本预览（最多显示 300 字，避免窗口内容太多）
        let preview = String(ocr.text.prefix(300))
        let ellipsis = ocr.text.count > 300 ? "\n…（省略）" : "" // 超过 300 字加省略号

        // ── NSMutableAttributedString：带格式的富文本 ───────────────────
        // NSMutableAttributedString 可以对不同部分设置不同的字体、颜色
        let attrStr = NSMutableAttributedString()

        // 标题行：触发提醒时用红色，正常时用蓝色
        let headerColor: NSColor = alerted ? .systemRed : .systemBlue
        attrStr.append(NSAttributedString(
            string: header,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), // 半粗等宽字体
                .foregroundColor: headerColor
            ]
        ))

        // 关键词行：橙色（醒目但不如红色紧张）
        if !keywordLine.isEmpty {
            attrStr.append(NSAttributedString(
                string: keywordLine,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.systemOrange
                ]
            ))
        }

        // 文本内容：正常颜色
        attrStr.append(NSAttributedString(
            string: preview + ellipsis + "\n\n", // \n\n 让条目之间有空行
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor // 跟随系统主题（深色模式下是白色）
            ]
        ))

        // 追加到文本区
        textView.textStorage?.append(attrStr)
        // 自动滚动到最底部（始终显示最新内容）
        textView.scrollToEndOfDocument(nil)

        // ── 超出上限时删除最旧内容（防止内存占用过大）──────────────────
        if entryCount > maxEntries {
            if let storage = textView.textStorage {
                // lineRange(for:) 找到文本开头所在行的范围
                let removeRange = (storage.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
                storage.deleteCharacters(in: removeRange) // 删除第一行
            }
        }

        // ── 更新底部状态标签 ─────────────────────────────────────────────
        let mean = String(format: "%.2f", anxiety.score)
        statusLabel.stringValue = "共 \(entryCount) 条 | 最近: \(app) — score \(mean) / threshold \(threshStr)"
    }

    // MARK: - 辅助函数 ────────────────────────────────────────────────────

    /// 根据焦虑分和阈值决定进度条的颜色。
    ///
    /// 颜色逻辑（交通灯配色，直觉友好）：
    ///   - 超过阈值                 → 红色（警告！）
    ///   - 超过阈值的 75%           → 橙色（接近警戒线，留意）
    ///   - 低于阈值的 75%           → 绿色（安全）
    ///
    /// - Parameters:
    ///   - score: 当前焦虑分（0.0–1.0）
    ///   - threshold: 当前动态阈值（0.0–1.0）
    private func scoreBarColor(for score: Double, threshold: Double) -> NSColor {
        if score >= threshold {
            return .systemRed    // 超过阈值：红色
        }
        if score >= threshold * 0.75 {
            return .systemOrange // 接近阈值（达到 75%）：橙色
        }
        return .systemGreen      // 低于 75%：绿色（安全）
    }

    // MARK: - 清空日志 ────────────────────────────────────────────────────

    /// 清空所有日志内容，重置状态。
    ///
    /// @objc 因为这个方法绑定到 NSButton 的 action，需要 ObjC 兼容。
    @objc private func clearLog() {
        textView.string = ""         // 清空文本区
        entryCount = 0               // 重置计数
        statusLabel.stringValue = "已清空"
        scoreBar.doubleValue = 0     // 进度条归零
        scoreValueLabel.stringValue = "—"
    }
}
