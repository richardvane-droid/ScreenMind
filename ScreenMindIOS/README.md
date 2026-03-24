# ScreenMindIOS

iOS Target — iPhone 16 Pro 监控与提醒。

## 监控层级

### Layer 1：常驻后台（零感知）
- `DeviceMonitor/` — DeviceActivity Framework，监控 App 使用时长和频次
- `NotificationExtension/` — Notification Service Extension，拦截并分析推送通知内容

### Layer 2：深度监控（触发条件：抖音 or 微信公众号进入前台）
- `BroadcastExtension/` — ReplayKit Broadcast Upload Extension
  - 降采样：每 10 秒分析一帧
  - Vision OCR → App Group 共享内存 → 主 App 分析
  - 用户知情（状态栏红色指示器）

## 其他模块

- `Widget/` — WidgetKit 锁屏/主屏小组件（今日焦虑指数 + HRV 状态）
- `LiveActivity/` — Dynamic Island 低打扰实时状态
- `Settings/` — SwiftUI 原生配置页

## iPhone 16 Pro 特性

- **Action Button**：映射为「暂停监控 15 分钟」
- **Dynamic Island**：焦虑值升高时颜色渐变提示
