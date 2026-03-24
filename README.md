# ScreenMind

> 个人情绪健康监控助手 — macOS · iOS

ScreenMind 在后台静默运行，实时感知你屏幕上内容的焦虑传递强度，结合 Apple Watch 的 HRV 生理数据动态调整告警阈值，在需要的时候推送个性化的放松建议。

---

## 核心功能

- **屏幕内容监控**：macOS 实时 OCR 分析，iOS 针对抖音和微信公众号深度监控
- **HRV 动态阈值**：身体越紧绷，告警越灵敏，放松时减少打扰
- **短视频账号识别**：豆包 API 评估创作者整体风格的焦虑传递指数
- **个性化放松建议**：你自己验证过的建议 + MapKit 实时车程
- **跨设备同步**：Mac 和 iPhone 数据通过 CloudKit 自动汇总
- **周报系统**：每周一自动生成精神状态与信息摄入分析报告

## 平台要求

| 平台 | 最低版本 |
|------|---------|
| macOS | 13.0 Ventura |
| iOS | 17.0 |
| Apple Watch | watchOS 9.0 |
| Xcode | 15.0+ |

## 开发环境准备

```bash
# 1. 安装 Ollama（本地 LLM）
bash scripts/setup.sh

# 2. 下载推荐模型
ollama pull qwen2.5:3b

# 3. 申请火山方舟 API Key（豆包账号评估）
# https://www.volcengine.com/product/ark
# 在 App 首次启动后于配置页填入

# 4. 用 Xcode 打开项目
open ScreenMind.xcodeproj
```

## 文档

- [完整架构设计](docs/architecture.md)
- [开发环境搭建](docs/setup.md)

## 开发规范

- Commit 遵循 Conventional Commits（`feat:` / `fix:` / `chore:`）
- 功能开发从 `develop` 切 `feature/xxx` 分支，PR 合并
- 所有 PR 需关联对应 Issue

## License

Private — Personal Use Only
