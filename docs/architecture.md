# ScreenMind 系统架构设计文档

> 版本：1.0
> 最后更新：2026-03
> 平台：macOS (M1+) · iOS (iPhone 16 Pro)

---

## 一、项目概述

**ScreenMind** 是一个运行在 Mac 和 iPhone 上的个人情绪健康监控系统。它通过实时感知屏幕内容的焦虑传递强度、结合 Apple Watch 的 HRV 生理数据，动态判断是否需要提醒用户调整当前的信息摄入行为，并在适当时机推送个性化的放松建议。

### 设计原则

- **零打扰**：平时完全隐形，只在超过阈值时出现
- **完全本地**：屏幕内容、OCR 结果绝不离开本机
- **全原生**：最大化使用 Apple 原生 Framework，减少第三方依赖
- **跨设备**：Mac 与 iPhone 数据通过 CloudKit 自动同步，周报汇总双端数据

---

## 二、技术栈

| 层级 | 技术 | 用途 |
|------|------|------|
| 屏幕采集 | ScreenCaptureKit (macOS) | Mac 截图 |
| 文字识别 | Vision Framework | OCR，M1 Neural Engine 加速 |
| 快速情感预判 | NaturalLanguage Framework | Stage 1 过滤，< 10ms |
| 深度焦虑分析 | Ollama (qwen2.5:3b) | Stage 2，本地 LLM，按需触发 |
| 账号风格评估 | 火山方舟 API（豆包） | 联网查询创作者风格，主引擎 |
| 账号评估 fallback | Ollama 本地 | 陌生账号兜底分析 |
| 生理数据 | HealthKit | HRV + 心率，Apple Watch 来源 |
| 位置服务 | CoreLocation | 用于计算放松建议车程 |
| 地图路径 | MapKit / MKDirections | 地址解析 + 车程计算，零 API Key |
| iOS 行为监控 | DeviceActivity (Layer 1) | App 使用时长和频次 |
| iOS 深度监控 | ReplayKit Broadcast Extension (Layer 2) | 抖音 + 微信公众号屏幕文字识别 |
| iOS 通知拦截 | Notification Service Extension | 推送通知内容焦虑分析 |
| 系统通知 | UserNotifications | 分类型告警通知 |
| 主界面 | SwiftUI | 全部 UI |
| macOS 菜单栏 | MenuBarExtra | 状态指示 + 快捷操作 |
| iOS 小组件 | WidgetKit | 锁屏 / 主屏焦虑状态 |
| iOS 动态岛 | Live Activities | 低打扰实时状态 |
| 数据持久化 | Core Data + CloudKit | 本地存储 + 双端同步 |
| API Key 安全存储 | Keychain | 豆包 API Key |
| 配置界面 (macOS) | WKWebView + React | 嵌入式 Web 配置页 |
| 配置界面 (iOS) | SwiftUI Settings | 原生配置页 |
| 周报 | Swift Charts + PDF Export | 每周一生成，CloudKit 存储 |

---

## 三、系统架构总图

```
                        Apple Watch
                      HRV / 心率采集
                      ↙            ↘
              直接同步(快)      iCloud中转(慢)
                  ↓                  ↓
        ┌─────────────────┐  ┌──────────────────────┐
        │     iPhone       │  │         Mac          │
        │                 │  │                      │
        │  Layer 1(常驻)  │  │  ScreenCaptureKit    │
        │  DeviceActivity │  │  Vision OCR          │
        │  HRV实时        │  │  NaturalLanguage      │
        │  通知内容分析   │  │  Ollama qwen2.5:3b   │
        │                 │  │  豆包API账号评估      │
        │  Layer 2(触发)  │  │  MenuBar             │
        │  Broadcast Ext  │  │  Web配置页           │
        │  仅抖音+公众号  │  │                      │
        │  Vision OCR     │  │                      │
        │                 │  │                      │
        │  动态岛状态     │  │                      │
        │  Widget         │  │                      │
        └────────┬────────┘  └──────────┬───────────┘
                 │                      │
                 └──────────┬───────────┘
                            ↓
                    ┌───────────────┐
                    │   CloudKit    │
                    │  iCloud 同步  │
                    │  焦虑历史     │
                    │  账号画像     │
                    │  建议库       │
                    │  HRV基线      │
                    │  周报文件     │
                    └───────┬───────┘
                            ↓
                    ┌───────────────┐
                    │  周报生成引擎  │
                    │  每周一09:00  │
                    │  Swift Charts │
                    │  PDF 导出     │
                    └───────────────┘
```

---

## 四、macOS 模块详解

### 4.1 屏幕监控流水线

```
定时器（30秒，可配置）
  → ScreenCaptureKit 截图（活跃窗口）
  → 应用白名单检查（过滤掉不需要监控的 App）
  → Vision Framework OCR（提取屏幕文字）
  → 两段式焦虑分析
      Stage 1: NaturalLanguage sentimentScore（< 10ms）
               得分 > -0.2 → 焦虑分 0~25，跳过 Stage 2
               得分 ≤ -0.2 → 进入 Stage 2
      Stage 2: Ollama qwen2.5:3b（1~2秒）
               Prompt → 返回 {"score": 0~100, "reason": "一句话"}
  → 滑动窗口均值（最近5次，防误触发）
  → 对比动态阈值 → 告警决策
```

### 4.2 短视频账号监控

```
NSWorkspace 检测前台 App
  → 识别到短视频平台（抖音 Mac App / 浏览器抖音页面）
  → Vision ROI-OCR 提取账号名称区域
  → 查 Core Data 账号画像缓存
      有缓存且未过期（30天内）→ 直接使用
      无缓存或已过期：
          → 豆包 API 查询（主引擎）
              known=true  → 高置信评估结果
              known=false → fallback Ollama 本地分析
          → 结果存入 Core Data（标记数据来源）
  → 账号焦虑分（40%权重）+ 内容焦虑分（60%权重）= 综合分
```

### 4.3 两段式分析效率

日常屏幕内容约 60~70% 为中性内容，Stage 1 会直接过滤，Ollama 实际调用频率约每 3~5 分钟一次，M1 16GB 资源占用极低。

---

## 五、iOS 模块详解

### 5.1 Layer 1：常驻后台监控（零感知）

| 子模块 | Framework | 获取信号 |
|--------|-----------|---------|
| App 行为监控 | DeviceActivity | App 使用时长、频次、分类 |
| HRV 实时读取 | HealthKit | Apple Watch 直接同步，延迟 < 5 分钟 |
| 心率监听 | HealthKit | 连续采集，HRV 降级备用 |
| 通知内容分析 | Notification Service Extension | 推送通知文字焦虑分析 |

**iOS 综合焦虑分计算**：
```
iOS焦虑分 = 高焦虑App时长权重(40%)
          + HRV偏离基线程度(40%)
          + 使用频次异常(20%)
```

### 5.2 Layer 2：深度屏幕监控（用户主动触发）

**触发条件**：仅当检测到以下 App 进入前台时，提示用户开启：
- **抖音**（com.ss.iphone.ugc.Aweme）
- **微信**中的**公众号文章**（通过 URL Pattern 识别 mp.weixin.qq.com）

**技术实现**：ReplayKit Broadcast Upload Extension

```swift
// BroadcastUploadExtension
class SampleHandler: RPBroadcastSampleHandler {
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with type: RPSampleBufferType) {
        guard type == .video, shouldProcessThisFrame() else { return }
        // 降采样：每10秒分析一帧
        // Vision OCR → App Group → 主 App 分析
    }
}
```

**用户体验**：
- 状态栏显示红色录制指示器（用户知情）
- 首次进入抖音/公众号时，ScreenMind 发一条建议通知："开启深度监控可获得更准确的焦虑评估"
- Shortcuts 个人自动化可配置为 App 打开时自动提示

### 5.3 iPhone 16 Pro 专属特性

| 特性 | 用途 |
|------|------|
| **Action Button** | 按一下暂停所有监控 15 分钟（主动休息时使用） |
| **Dynamic Island** | 焦虑值升高但未告警时，颜色变化低打扰提示（绿→黄→橙） |
| **锁屏 Widget** | 今日焦虑指数 + HRV 状态，一眼可见 |
| **主屏 Widget** | 本周趋势迷你图 |

---

## 六、HRV 动态阈值引擎

### 6.1 工作原理

```
动态告警阈值 = 基础阈值 × HRV比值系数

HRV比值 = 当前HRV / 个人30天滚动基线HRV
         （钳位在 0.4 ~ 1.6 之间）
```

| 身体状态 | HRV比值 | 基础阈值70 → 动态阈值 | 效果 |
|---------|---------|---------------------|------|
| 已经很焦虑 | 0.5 | **35** | 轻微焦虑内容就提醒 |
| 略微紧张 | 0.75 | **52** | 中等焦虑内容提醒 |
| 正常状态 | 1.0 | **70** | 标准阈值 |
| 非常放松 | 1.3 | **91** | 只有强烈焦虑内容才提醒 |

### 6.2 数据降级策略

```
优先级1: HealthKit HRV < 1小时前    → 最准确，完整权重
优先级2: HealthKit HRV 1~4小时前   → 参考使用，权重 70%
优先级3: 实时心率（Apple Watch）    → HRV代理，粗粒度
优先级4: 无生物数据                  → 回退固定阈值 70，正常运行
```

---

## 七、个性化放松建议系统

### 7.1 建议数据模型

```
RelaxationSuggestion
├── title           "去楼下咖啡馆坐坐"
├── description     "点热拿铁，不看手机，发20分钟呆"
├── address         "上海市xxx路xx号"（可选）
├── coordinates     CLLocationCoordinate2D（地理编码预处理后存储）
├── category        散步 / 咖啡 / 冥想 / 运动 / 社交 / 其他
├── triggerLevel    最低触发焦虑分（如：≥60 才推送）
├── timeSlots       适用时段 [早晨, 下午, 傍晚, 夜间, 任意]
├── estimatedMins   预估时长（分钟）
├── displayCount    累计展示次数（防疲劳）
└── lastDisplayedAt 上次展示时间
```

### 7.2 告警触发完整流程

```
焦虑分 > 动态阈值（HRV调整后）
  → 冷却检查（15分钟内是否已提醒）→ 未在冷却期
  → 建议筛选（时段 + 焦虑分 + 展示疲劳度）
  → MapKit 并发计算有地址建议的车程（MKDirections）
  → 触发系统通知（含建议 + 车程）
  → 点击通知 → SwiftUI 浮窗（macOS）/ 详情页（iOS）
  → 地图按钮 → MKMapItem.openInMaps()
```

---

## 八、创作者账号评估系统

### 8.1 双引擎架构

```
主引擎：火山方舟 API（豆包 doubao-pro-32k）
  · 识别头部/腰部创作者，置信度高
  · 返回：{"known": bool, "style": "描述", "score": 0~100, "reason": "一句话"}
  · 缓存30天，API Key 存 Keychain

副引擎：Ollama 本地（qwen2.5:3b）
  · 处理豆包不认识的陌生/新兴创作者
  · 基于屏幕可见文字（账号名+视频标题+标签）推断
  · 缓存7天（置信度低，频繁刷新）
```

### 8.2 置信度分级

| 来源 | 标识 | 置信度 |
|------|------|--------|
| 豆包 API，known=true | `[豆包评估 · 高置信]` | 高 |
| 豆包 API，known=false + Ollama | `[本地推测 · 低置信]` | 低 |
| 用户手动标记 | `[你标记的 · 最高优先级]` | 最高 |

---

## 九、CloudKit 数据同步

使用 `NSPersistentCloudKitContainer`，Core Data 数据自动双向同步。

| 实体 | 同步策略 | 说明 |
|------|---------|------|
| RelaxationSuggestion | ✅ 同步 | 任一设备录入，全平台生效 |
| VideoAccountProfile | ✅ 同步 | Mac识别的账号，iPhone直接复用 |
| AnxietyRecord | ✅ 同步 | 双端写入，汇总到一处 |
| HRVBaseline | ✅ 同步（iPhone为准） | iPhone数据更新鲜 |
| WeeklyReport | ✅ 同步 | PDF文件，双端可查看 |
| AppConfig | ✅ 同步 | 修改一端，另一端自动生效 |
| 截图临时文件 | ❌ 不同步 | 敏感，仅本地 |
| OCR 原始文字 | ❌ 不同步 | 敏感，仅本地 |

---

## 十、周报系统

### 10.1 触发机制

每周一 09:00，BackgroundTasks 触发周报生成，完成后推送系统通知。

### 10.2 报告内容

**第一部分：本周总览**
- Mac + iPhone 合并综合情绪健康评分（0~100）
- 与上周对比（↑↓ 百分比）
- 最平静的一天 / 最焦虑的一天

**第二部分：信息摄入分析**
- 高焦虑内容接触时长（按天柱状图）
- 告警触发次数 + 分布时段热力图
- Mac 端：触发告警的主要内容类型
- iPhone 端：高焦虑 App 使用时长排名

**第三部分：账号风险榜**
- 本周遇到次数最多的高焦虑账号 Top 5
- 新识别的高风险账号

**第四部分：身体状态**
- HRV 全周趋势折线图
- 平均 HRV vs 个人基线对比
- HRV 最低时段分析

**第五部分：应对行动**
- 本周共接受放松建议次数
- 最常采用的建议类型

### 10.3 技术实现

Swift Charts 生成图表 → SwiftUI 排版 → PDF 导出 → 存入 CloudKit

---

## 十一、权限申请清单

| 权限 | 平台 | Framework | 用途 |
|------|------|-----------|------|
| 屏幕录制 | macOS | ScreenCaptureKit | 截图监控 |
| 屏幕录制 | iOS | ReplayKit | Layer 2 深度监控 |
| 健康数据读取 | 双端 | HealthKit | HRV + 心率 |
| 位置（使用期间） | 双端 | CoreLocation | 计算建议车程 |
| 系统通知 | 双端 | UserNotifications | 告警推送 |
| App 使用数据 | iOS | FamilyControls | DeviceActivity Layer 1 |

---

## 十二、Xcode 项目结构

```
ScreenMind.xcodeproj
│
├── ScreenMindCore/              # Swift Package（共享逻辑）
│   ├── Models/                  # Core Data 模型
│   ├── HRVManager/              # HealthKit 读取（双端共用）
│   ├── AnxietyScorer/           # 焦虑分计算
│   ├── SuggestionEngine/        # 建议筛选 + MapKit
│   └── CloudKitSync/            # 数据同步
│
├── ScreenMindMac/               # macOS Target
│   ├── ScreenCapture/           # ScreenCaptureKit
│   ├── OCREngine/               # Vision OCR
│   ├── ContentAnalyzer/         # NaturalLanguage + Ollama
│   ├── AccountMonitor/          # 账号识别 + 豆包API
│   ├── MenuBar/                 # MenuBarExtra
│   └── WebConfig/               # WKWebView + React
│
├── ScreenMindIOS/               # iOS Target
│   ├── DeviceMonitor/           # DeviceActivity
│   ├── BroadcastExtension/      # ReplayKit Layer 2
│   ├── NotificationExtension/   # Notification Service Extension
│   ├── Widget/                  # WidgetKit
│   ├── LiveActivity/            # Dynamic Island
│   └── Settings/                # SwiftUI 配置页
│
└── web-config/                  # React 前端（macOS 配置页）
    ├── src/
    └── dist/                    # 构建产物，内嵌 App Bundle
```

---

## 十三、开发里程碑

| Milestone | 内容 | 平台 |
|-----------|------|------|
| **M1** | 项目骨架、CloudKit 配置、Core Data 模型、GitHub 规范 | 双端 |
| **M2** | ScreenCaptureKit 截图 + Vision OCR | macOS |
| **M3** | NaturalLanguage Stage 1 + Ollama Stage 2 内容分析 | macOS |
| **M4** | HealthKit HRV 接入 + 动态阈值引擎 | 双端共享 |
| **M5** | DeviceActivity 行为监控 + 通知内容拦截 | iOS Layer 1 |
| **M6** | Broadcast Extension OCR（仅抖音+公众号触发）| iOS Layer 2 |
| **M7** | 豆包 API 账号评估 + Ollama fallback + 缓存 | macOS 先，iOS 复用 |
| **M8** | MapKit 车程 + 建议筛选 + 通知 + SuggestionPanel | 双端 |
| **M9** | macOS Web 配置页 + iOS SwiftUI 配置页 | 双端 |
| **M10** | 周报生成 + Swift Charts + PDF 导出 + CloudKit 存储 | 双端 |
| **M11** | 全流程联调、性能优化、权限引导、打包发布 | 双端 |

---

## 十四、M1 16GB 资源占用估算

```
常驻内存：
  macOS 系统              ~4-5 GB
  日常应用（Chrome等）     ~2-3 GB
  ScreenMind App          ~150 MB
  Ollama qwen2.5:3b 常驻  ~2.0 GB
  ─────────────────────────────
  合计                    ~8.5 GB（充裕）

CPU 负荷（30秒采样周期）：
  截图 + OCR               < 0.5秒，峰值 ~15% CPU
  Ollama 推理（按需）       1~2秒，主要用 Neural Engine
  豆包 API 调用             异步网络，< 1秒
  其余时间                  接近 0%
```

结论：M1 16GB 完全充裕，日常使用感知不到此服务的存在。

---

## 十五、Git 规范

### Commit Message

遵循 Conventional Commits：

```
feat(ocr): 实现 Vision Framework 中文文字提取
fix(hrv): 修复 HRV 基线计算在无数据时崩溃的问题
chore(ci): 添加 macOS build GitHub Actions
refactor(analyzer): 将 NL 过滤逻辑提取为独立 Stage
```

### 分支策略

```
main          生产就绪代码，PR 合并，不直接推送
develop       集成分支
feature/xxx   功能开发分支（从 develop 切出）
fix/xxx       Bug 修复分支
```

### PR 规范

每个 PR 关联对应 Issue，合并前需要 CI 构建通过。
