import AppKit

/// M2 调试窗口：实时显示 OCR 识别结果。
/// 菜单栏 -> "OCR 调试窗口" 打开。
/// M3 完成后此窗口会同时显示焦虑评分。
final class DebugWindowController: NSWindowController {

    private var textView: NSTextView!
    private var statusLabel: NSTextField!
    private var entryCount = 0
    private let maxEntries = 200

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenMind — OCR 调试"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // 顶部状态栏
        statusLabel = NSTextField(labelWithString: "等待 OCR 输出…")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)

        // 清空按钮
        let clearButton = NSButton(title: "清空", target: self, action: #selector(clearLog))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .rounded
        contentView.addSubview(clearButton)

        // 滚动文本区
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        contentView.addSubview(scrollView)

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor(named: "debugBackground") ?? .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scrollView.documentView = textView

        // 约束
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),

            clearButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - Log append (called from main thread via coordinator)

    func appendLog(_ result: PipelineResult) {
        entryCount += 1

        let time = DateFormatter.localizedString(from: result.ocrResult.timestamp,
                                                  dateStyle: .none,
                                                  timeStyle: .medium)
        let app  = result.frontAppName ?? "?"
        let lang = result.ocrResult.language.rawValue
        let ms   = result.ocrResult.durationMs
        let chars = result.ocrResult.text.count

        // 标题行
        let header = "── [\(time)]  \(app)  lang=\(lang)  \(chars)字  \(ms)ms ──\n"
        // 文本内容（最多 300 字）
        let preview = String(result.ocrResult.text.prefix(300))
        let entry = header + preview + (result.ocrResult.text.count > 300 ? "\n…（省略）" : "") + "\n\n"

        // 转 attributed string（标题用粗体）
        let attrStr = NSMutableAttributedString()
        let headerAttr = NSAttributedString(string: header, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.systemBlue
        ])
        let bodyAttr = NSAttributedString(string: preview + "\n\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
        attrStr.append(headerAttr)
        attrStr.append(bodyAttr)

        textView.textStorage?.append(attrStr)

        // 自动滚动到底部
        textView.scrollToEndOfDocument(nil)

        // 超出上限，删除最旧的段落
        if entryCount > maxEntries {
            if let storage = textView.textStorage {
                let removeRange = (storage.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
                storage.deleteCharacters(in: removeRange)
            }
        }

        // 更新状态栏
        statusLabel.stringValue = "共 \(entryCount) 条 | 最近: \(app) — \(chars) 字"
    }

    @objc private func clearLog() {
        textView.string = ""
        entryCount = 0
        statusLabel.stringValue = "已清空"
    }
}
