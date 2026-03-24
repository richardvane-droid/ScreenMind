# ScreenMindCore

跨平台共享 Swift Package，包含 Mac 和 iOS 共用的核心逻辑。

## 模块

- `Models/` — Core Data 数据模型（AnxietyRecord, RelaxationSuggestion, VideoAccountProfile, HRVBaseline, AppConfig）
- `HRVManager/` — HealthKit HRV + 心率读取，动态阈值计算
- `AnxietyScorer/` — 焦虑分计算、滑动窗口均值
- `SuggestionEngine/` — 建议筛选（时段 + 焦虑分 + 疲劳度）+ MapKit 车程计算
- `CloudKitSync/` — NSPersistentCloudKitContainer 双端数据同步
