#!/usr/bin/env python3
"""
ScreenMind GitHub Issues 批量初始化脚本
用法: GITHUB_TOKEN=xxx GITHUB_USER=xxx python3 scripts/github_issues.py
"""

import os, json, time
import urllib.request, urllib.error

TOKEN = os.environ.get("GITHUB_TOKEN")
USER  = os.environ.get("GITHUB_USER")
REPO  = "ScreenMind"

if not TOKEN or not USER:
    print("❌ 请设置环境变量：GITHUB_TOKEN 和 GITHUB_USER")
    exit(1)

BASE = f"https://api.github.com/repos/{USER}/{REPO}"
HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Content-Type": "application/json",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
}

def api(method, path, data=None):
    url = BASE + path if path.startswith("/") else f"https://api.github.com{path}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        print(f"  ⚠️  HTTP {e.code}: {e.read().decode()}")
        return {}

def create_label(name, color, description=""):
    result = api("POST", "/labels", {"name": name, "color": color, "description": description})
    if result.get("name"):
        print(f"  ✓ Label: {name}")
    time.sleep(0.3)

def create_milestone(title, description):
    result = api("POST", "/milestones", {"title": title, "description": description})
    mid = result.get("number")
    if mid:
        print(f"  ✓ Milestone #{mid}: {title}")
    time.sleep(0.3)
    return mid

def create_issue(title, body, labels, milestone_id):
    result = api("POST", "/issues", {
        "title": title, "body": body,
        "labels": labels, "milestone": milestone_id
    })
    num = result.get("number")
    if num:
        print(f"    ✓ Issue #{num}: {title}")
    time.sleep(0.4)
    return num

# ─── Labels ────────────────────────────────────────────────────────────────
print("\n🏷  创建标签...")
LABELS = [
    ("macOS",       "0075ca", "macOS 平台相关"),
    ("iOS",         "e4e669", "iOS 平台相关"),
    ("shared",      "0e8a16", "双端共享逻辑"),
    ("infra",       "d4c5f9", "基础设施、CI、配置"),
    ("ml",          "f9d0c4", "机器学习、LLM 相关"),
    ("healthkit",   "c2e0c6", "HealthKit、HRV 相关"),
    ("ui",          "bfd4f2", "UI 界面相关"),
    ("data",        "fef2c0", "数据层、Core Data、CloudKit"),
    ("api",         "fbca04", "外部 API 集成"),
]
for name, color, desc in LABELS:
    create_label(name, color, desc)

# ─── Milestones ─────────────────────────────────────────────────────────────
print("\n🏁 创建 Milestones...")
MILESTONES = [
    ("M1: 项目骨架 & 基础设施",
     "Xcode多Target初始化、CloudKit配置、Core Data模型、App Groups、GitHub Actions CI"),
    ("M2: macOS 屏幕采集 & OCR",
     "ScreenCaptureKit截图模块、Vision Framework OCR、定时采样调度器、应用过滤"),
    ("M3: 内容焦虑分析引擎",
     "NaturalLanguage Stage 1过滤、Ollama Stage 2深度分析、滑动窗口均值、Prompt优化"),
    ("M4: HRV 集成 & 动态阈值",
     "HealthKit HRV读取、个人基线计算、动态阈值引擎、告警冷却管理器"),
    ("M5: iOS Layer 1 行为监控",
     "DeviceActivity行为监控、FamilyControls权限、iOS行为焦虑评分、通知内容拦截"),
    ("M6: iOS Layer 2 深度监控",
     "Broadcast Upload Extension、抖音+公众号触发检测、App Group通信、降采样OCR"),
    ("M7: 账号风格评估",
     "火山方舟API(豆包)集成、双引擎路由、账号画像缓存、置信度分级、Keychain存储"),
    ("M8: 放松建议系统 & MapKit",
     "CLGeocoder地址预处理、MKDirections并发车程、建议筛选引擎、SuggestionPanel浮窗"),
    ("M9: 配置界面",
     "macOS Web配置页(React+WKWebView)、iOS SwiftUI配置页、建议库CRUD、Action Button"),
    ("M10: 周报系统",
     "数据聚合引擎、Swift Charts图表、PDF导出、每周一触发、CloudKit存储"),
    ("M11: 联调优化 & 发布",
     "全流程联调、性能优化、权限引导流程、打包macOS .app + iOS .ipa"),
]
milestone_ids = {}
for title, desc in MILESTONES:
    mid = create_milestone(title, desc)
    milestone_ids[title] = mid

M = milestone_ids  # shorthand

# ─── Issues ──────────────────────────────────────────────────────────────────
print("\n📋 创建 Issues...")

ISSUES = [
    # M1
    ("M1", "[M1] 初始化 Xcode 多 Target 项目（Core / Mac / iOS）",
     "创建 `ScreenMind.xcodeproj`，配置三个 Target：`ScreenMindCore`（Swift Package）、`ScreenMindMac`（macOS App）、`ScreenMindIOS`（iOS App）。",
     ["infra", "shared"]),
    ("M1", "[M1] 配置 Core Data 数据模型",
     "创建以下 Entity：\n- `AnxietyRecord`\n- `RelaxationSuggestion`\n- `VideoAccountProfile`\n- `HRVBaseline`\n- `AppConfig`\n\n参考 `docs/architecture.md` 第九节字段定义。",
     ["data", "shared"]),
    ("M1", "[M1] 配置 CloudKit + NSPersistentCloudKitContainer",
     "开启 CloudKit Capability，配置 iCloud Container，将 Core Data stack 升级为 `NSPersistentCloudKitContainer`，验证双端数据同步。",
     ["data", "infra", "shared"]),
    ("M1", "[M1] 配置 App Groups（Extension 共享内存）",
     "配置 App Group `group.com.xxx.screenmind`，供 Broadcast Extension、Notification Extension 与主 App 共享数据。",
     ["infra", "iOS"]),
    ("M1", "[M1] 配置 GitHub Actions CI（macOS + iOS 双端构建）",
     "`.github/workflows/build-mac.yml` 和 `build-ios.yml` 已存在，配置正确的 Scheme 名称后验证 CI 构建通过。",
     ["infra"]),

    # M2
    ("M2", "[M2] 实现 ScreenCaptureKit 权限请求与截图模块",
     "封装 `ScreenCapturer` 类，处理权限申请、活跃窗口截图，返回 `CGImage`。",
     ["macOS"]),
    ("M2", "[M2] 实现 Vision Framework OCR 文字提取",
     "封装 `OCREngine`，输入 `CGImage`，输出识别文字字符串。支持中英文，利用 M1 Neural Engine 加速。",
     ["macOS", "ml"]),
    ("M2", "[M2] 实现定时采样调度器",
     "默认每 30 秒触发一次截图+OCR，间隔可配置（最小 10 秒，最大 120 秒）。",
     ["macOS"]),
    ("M2", "[M2] 实现应用白名单/黑名单过滤",
     "通过 `NSWorkspace` 获取前台 App bundle ID，对白名单 App 跳过本次分析。",
     ["macOS"]),

    # M3
    ("M3", "[M3] 实现 NaturalLanguage Stage 1 情感预判",
     "使用 `NLTagger` 的 `.sentimentScore` 对提取文字快速评分。得分 > -0.2 时跳过 Stage 2，焦虑分直接取 0~25。",
     ["macOS", "ml"]),
    ("M3", "[M3] 实现 Ollama Stage 2 深度焦虑分析",
     "封装 `OllamaClient`，调用本地 Ollama API（`qwen2.5:3b`），发送焦虑评分 Prompt，解析返回 JSON `{score, reason}`。",
     ["macOS", "ml"]),
    ("M3", "[M3] 实现滑动窗口均值（防误触发）",
     "维护最近 5 次焦虑分的滑动队列，取均值作为当前综合焦虑分。",
     ["shared", "ml"]),
    ("M3", "[M3] 优化中文焦虑评分 Prompt",
     "迭代 Prompt，确保评估的是"对读者的情绪感染力"而非"内容本身的情绪"。建立评分参考案例库（test cases）。",
     ["ml"]),

    # M4
    ("M4", "[M4] 实现 HealthKit HRV 数据读取（双端共享）",
     "在 `ScreenMindCore/HRVManager` 中封装 HRV 查询，读取 `HKQuantityTypeIdentifier.heartRateVariabilitySDNN`，支持 macOS 和 iOS。",
     ["healthkit", "shared"]),
    ("M4", "[M4] 实现个人 HRV 基线计算（30 天滚动均值）",
     "首次使用需 7 天数据积累。持续维护滚动 30 天均值，存入 Core Data `HRVBaseline`。",
     ["healthkit", "shared"]),
    ("M4", "[M4] 实现动态阈值计算引擎",
     "公式：`动态阈值 = 基础阈值 × (当前HRV / 基线HRV)`，比值钳位 0.4~1.6。实现降级策略（HRV 过期时用心率代理）。",
     ["healthkit", "shared"]),
    ("M4", "[M4] 实现告警冷却管理器",
     "触发通知后进入 15 分钟冷却期（可配置），冷却期内不重复提醒。",
     ["shared"]),

    # M5
    ("M5", "[M5] 集成 DeviceActivity Framework 行为监控",
     "配置 `FamilyControls` 授权，使用 `DeviceActivityMonitor` 监控高焦虑 App 分类的使用时长和频次。",
     ["iOS"]),
    ("M5", "[M5] 实现 iOS 行为焦虑评分模型",
     "公式：`iOS焦虑分 = 高焦虑App时长(40%) + HRV偏离基线(40%) + 使用频次异常(20%)`",
     ["iOS", "ml"]),
    ("M5", "[M5] 实现 Notification Service Extension",
     "创建 Extension，拦截来自高焦虑 App（微博、今日头条等）的推送通知，对通知正文做 NaturalLanguage 快速评分。",
     ["iOS"]),

    # M6
    ("M6", "[M6] 实现 Broadcast Upload Extension（ReplayKit）",
     "创建 `BroadcastUploadExtension` Target，接收屏幕视频流，降采样（每 10 秒一帧），对帧做 Vision OCR，结果写入 App Group 共享存储。",
     ["iOS"]),
    ("M6", "[M6] 实现抖音前台检测 → Layer 2 开启提示",
     "当 DeviceActivity 检测到抖音进入前台，发送系统通知提示用户开启深度监控（Broadcast Extension）。",
     ["iOS"]),
    ("M6", "[M6] 实现微信公众号检测 → Layer 2 开启提示",
     "通过 URL 模式识别（`mp.weixin.qq.com`），检测到用户在微信内浏览公众号时触发提示。",
     ["iOS"]),
    ("M6", "[M6] 实现 App Group 通信（Extension → 主 App）",
     "Broadcast Extension 通过共享 `UserDefaults(suiteName:)` 将 OCR 结果传递给主 App，主 App 用 Darwin 通知监听数据变化。",
     ["iOS", "infra"]),

    # M7
    ("M7", "[M7] 集成火山方舟 API（豆包 doubao-pro-32k）",
     "封装 `DoubaoClient`，调用 `https://ark.cn-beijing.volces.com/api/v3/chat/completions`，发送创作者评估 Prompt，解析 `{known, style, score, reason}`。",
     ["macOS", "api"]),
    ("M7", "[M7] 实现创作者评估双引擎路由",
     "豆包 `known=true` → 高置信使用豆包结果；`known=false` → fallback 至 Ollama 本地分析（基于屏幕可见文字）。",
     ["macOS", "ml"]),
    ("M7", "[M7] 实现账号画像 Core Data 缓存",
     "豆包结果缓存 30 天，Ollama 结果缓存 7 天，相同账号命中缓存直接返回，标记数据来源（doubao / ollama / manual）。",
     ["data", "macOS"]),
    ("M7", "[M7] 实现 API Key 安全存储（Keychain）",
     "豆包 API Key 存储在 macOS / iOS Keychain 中，不写入任何配置文件，首次启动时通过配置页录入。",
     ["infra", "api"]),

    # M8
    ("M8", "[M8] 实现 CLGeocoder 地址预处理",
     "建议录入地址时，后台调用 `CLGeocoder.geocodeAddressString` 将地址解析为坐标，存入 Core Data，避免告警时实时解析。",
     ["shared"]),
    ("M8", "[M8] 实现 MKDirections 并发车程计算",
     "告警触发时，对筛选出的有地址建议并发调用 `MKDirections.calculateETA`，获取步行 + 驾车时间。",
     ["shared"]),
    ("M8", "[M8] 实现建议筛选引擎",
     "按条件过滤：`isEnabled=true` + `triggerLevel ≤ 当前焦虑分` + 当前时段 ∈ `timeSlots`；疲劳度排序：优先展示最近展示次数最少的建议。",
     ["shared"]),
    ("M8", "[M8] 实现 macOS SuggestionPanel 浮窗",
     "SwiftUI 小窗口，触发告警后出现在屏幕右下角，展示 2~3 条建议（含车程），5 秒无操作自动消失，包含「在地图中打开」按钮。",
     ["macOS", "ui"]),
    ("M8", "[M8] 实现 iOS 通知建议卡片",
     "通知展开后显示建议内容和车程，Tap Action 跳转至 MapKit。",
     ["iOS", "ui"]),

    # M9
    ("M9", "[M9] 实现 macOS Web 配置页（React + WKWebView）",
     "React 构建产物内嵌 App Bundle，通过 WKScriptMessageHandler 与 Swift 双向通信。实现所有配置页面（基础设置、HRV、应用过滤、建议库、账号画像库、历史图表）。",
     ["macOS", "ui"]),
    ("M9", "[M9] 实现建议库 CRUD 与地址验证",
     "新建/编辑建议表单，包含地址字段，填写后实时调用 CLGeocoder 验证并预显示车程。支持拖拽排序。",
     ["macOS", "ui"]),
    ("M9", "[M9] 实现账号画像库管理界面",
     "按平台分组展示账号列表，支持手动覆盖焦虑分、标记永久白名单、手动添加账号。",
     ["macOS", "ui"]),
    ("M9", "[M9] 实现 iOS SwiftUI 配置页",
     "原生 SwiftUI Settings 风格，功能与 macOS Web 配置页对齐，通过 CloudKit 同步配置。",
     ["iOS", "ui"]),
    ("M9", "[M9] 实现 iPhone 16 Pro Action Button 映射",
     "将 Action Button 映射为「暂停所有监控 15 分钟」，提供用户主动休息时的快捷操作。",
     ["iOS", "ui"]),

    # M10
    ("M10", "[M10] 实现周报数据聚合引擎",
     "从 CloudKit 同步的 `AnxietyRecord` 中聚合上周 Mac + iPhone 双端数据，计算各维度指标。",
     ["data", "shared"]),
    ("M10", "[M10] 实现 Swift Charts 图表组件",
     "开发报告所需图表：日焦虑趋势柱状图、HRV 折线图、时段热力图、App 使用时长排名。",
     ["ui", "shared"]),
    ("M10", "[M10] 实现周报 PDF 导出",
     "将 Swift Charts 图表 + SwiftUI 文字排版导出为 PDF，存入 CloudKit，供双端查看。",
     ["data", "shared"]),
    ("M10", "[M10] 实现每周一 09:00 后台自动触发",
     "使用 `BGProcessingTask`（iOS）和 `NSBackgroundActivityScheduler`（macOS）在每周一 09:00 触发周报生成，完成后推送通知。",
     ["infra", "shared"]),

    # M11
    ("M11", "[M11] macOS + iOS 全流程联调",
     "端到端测试：屏幕监控 → OCR → 分析 → 阈值对比 → 通知 → 建议 → 报告，验证 CloudKit 数据双向同步。",
     ["macOS", "iOS"]),
    ("M11", "[M11] 性能优化（内存 / 电量）",
     "Profile Ollama 推理时的 CPU/GPU 占用，优化 Broadcast Extension 帧率，监控 iOS 后台电量消耗。",
     ["macOS", "iOS"]),
    ("M11", "[M11] 权限引导流程优化",
     "设计首次启动引导页（屏幕录制 → HealthKit → 位置 → 通知），处理各权限被拒绝时的降级逻辑。",
     ["macOS", "iOS", "ui"]),
    ("M11", "[M11] 打包 macOS .app + iOS .ipa",
     "配置 Archive Scheme，生成可分发的 macOS App Bundle 和 iOS Ad Hoc 包，验证在目标设备（M1 Mac + iPhone 16 Pro）上正常运行。",
     ["macOS", "iOS", "infra"]),
]

# 将 Milestone 标题映射到 ID
def get_mid(prefix):
    for title, mid in M.items():
        if title.startswith(prefix):
            return mid
    return None

for m_prefix, title, body, labels in ISSUES:
    mid = get_mid(m_prefix + ":")
    print(f"\n  [{m_prefix}]")
    create_issue(title, body, labels, mid)

print("\n\n🎉 所有 Issues 创建完成！")
print(f"🔗 https://github.com/{USER}/{REPO}/issues")
print(f"📊 https://github.com/{USER}/{REPO}/milestones")
