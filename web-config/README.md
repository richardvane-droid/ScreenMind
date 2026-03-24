# web-config

macOS 配置页前端，React 单页应用，通过 WKWebView 内嵌在 App 中。

## 页面结构

- **基础设置** — 采样频率、基础阈值、冷却时间
- **HRV 设置** — 查看个人基线、手动重置
- **应用过滤** — 白名单 / 黑名单 App 列表
- **建议库管理** — 放松建议 CRUD，含地址验证（MapKit 预计算车程）
- **账号画像库** — 按平台分组，手动覆盖焦虑分，标记白名单
- **数据与历史** — 焦虑历史曲线 + HRV 叠加图

## 开发

```bash
npm install
npm run dev      # 本地开发
npm run build    # 构建，产物到 dist/（被 Xcode 打包进 App Bundle）
```

## 与 Swift 通信

通过 `WKScriptMessageHandler` 双向通信，无需网络端口：

```javascript
// JS → Swift
window.webkit.messageHandlers.screenMind.postMessage({ action: 'saveConfig', data: {...} })

// Swift → JS
webView.evaluateJavaScript("window.onSwiftMessage({...})")
```
