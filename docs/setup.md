# 开发环境搭建

## 前置要求

| 工具 | 版本要求 | 说明 |
|------|---------|------|
| macOS | 13.0+ | Ventura 或更高 |
| Xcode | 15.0+ | 含 Swift 5.9+ |
| Ollama | 最新版 | 本地 LLM 运行时 |
| Node.js | 18.0+ | web-config 前端构建 |

## 一键配置

```bash
bash scripts/setup.sh
```

脚本会自动安装：Homebrew、Ollama、qwen2.5:3b 模型、Node.js、前端依赖。

## 手动配置步骤

### 1. 安装 Ollama 并下载模型

```bash
brew install ollama
brew services start ollama
ollama pull qwen2.5:3b      # 推荐，2GB，速度快
# ollama pull qwen2.5:7b    # 可选，质量更高但较慢
```

### 2. 申请火山方舟 API Key（豆包）

1. 访问 https://www.volcengine.com/product/ark
2. 注册账号 → 创建 API Key
3. 模型选择：`doubao-pro-32k`
4. App 首次启动后在「配置页 → 账号评估」中填入

### 3. 构建 Web 配置前端

```bash
cd web-config
npm install
npm run build      # 产物输出到 dist/，会被嵌入 App Bundle
```

### 4. Xcode 项目配置

1. `open ScreenMind.xcodeproj`
2. 在 Signing & Capabilities 中配置你的 Apple 开发者账号
3. 开启必要的 Capabilities：
   - HealthKit
   - CloudKit（Container: iCloud.com.yourname.screenmind）
   - App Groups（group.com.yourname.screenmind）
   - Push Notifications（用于 Notification Service Extension）

### 5. 首次运行权限授权

App 首次启动会依次引导授权：
1. **屏幕录制**（macOS）：系统偏好设置 → 隐私与安全 → 屏幕录制
2. **健康数据**：HealthKit 弹窗，选择授权 HRV 和心率读取
3. **位置权限**：选择「使用 App 期间允许」
4. **通知权限**：允许发送通知

## 常见问题

**Q: Ollama 推理很慢怎么办？**
A: 确认 Ollama 使用 Metal（M1 GPU）：`ollama ps` 查看运行状态，正常应显示 GPU 使用。

**Q: HealthKit 数据为空？**
A: 确认 iPhone 的「健康」App 已开启 iCloud 同步，且 Mac 登录了同一 Apple ID。

**Q: 豆包 API 返回错误？**
A: 检查 API Key 是否正确填入，以及火山方舟控制台中 `doubao-pro-32k` 模型是否已开通。
