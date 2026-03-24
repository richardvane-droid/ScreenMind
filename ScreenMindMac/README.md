# ScreenMindMac

macOS Target — 菜单栏常驻应用。

## 模块

- `ScreenCapture/` — ScreenCaptureKit 定时截图（30秒间隔，可配置）
- `OCREngine/` — Vision Framework 文字提取，支持中英文
- `ContentAnalyzer/` — NaturalLanguage Stage 1 + Ollama Stage 2 两段式焦虑分析
- `AccountMonitor/` — 短视频账号 ROI-OCR 识别 + 豆包 API 风格评估 + Ollama fallback
- `MenuBar/` — MenuBarExtra 图标（颜色随焦虑值变化）+ 迷你趋势面板
- `WebConfig/` — WKWebView 加载本地 React 配置页，WKScriptMessageHandler 双向通信
