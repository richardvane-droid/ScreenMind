// =============================================================================
//  PersistenceController.swift
//  ScreenMindCore — 跨平台共享层
// =============================================================================
//
//  【产品需求：这个文件解决什么问题？】
//  ScreenMind 需要在用户关闭 App 后，仍然保留：
//    - 每次检测到焦虑的历史记录（时间、分数、App、文字）
//    - 用户设置的放松建议（地点、路线时间）
//    - 用户关注的账号及其焦虑评估结果
//    - HRV 基线数据（30天滚动均值）
//    - App 配置项（采样间隔、阈值等）
//
//  以上数据都存储在 Core Data 里。
//
//  【Core Data 是什么？】
//  Core Data 是苹果官方的数据持久化框架，相当于一个"本地数据库"，但使用更 Swift-friendly 的 API。
//  它不是纯 SQL，而是把 Swift 对象直接存到磁盘文件里（底层用 SQLite）。
//
//  【NSPersistentCloudKitContainer 是什么？】
//  这是苹果官方的"Core Data + iCloud 同步"解决方案。
//  用了这个，本地数据会自动同步到 iCloud，用户换设备/换 Mac 后数据还在。
//  Mac 端的 AnxietyRecord 甚至可以同步到 iPhone，实现跨设备查看历史记录。
//
//  【数据模型图（Entity 关系）】
//  ScreenMind.xcdatamodeld 定义了 5 张"表"（Entity）：
//
//    AnxietyRecord ─── (1:1) ──→ RelaxationSuggestion
//    （每次焦虑记录）            （触发了哪个放松建议）
//
//    VideoAccountProfile    HRVBaseline    AppConfig
//    （账号焦虑档案）         （HRV 基线）   （配置项 K-V 存储）
//
//  【部署位置】
//  ScreenMindCore/Sources/ScreenMindCore/Persistence/PersistenceController.swift
//  在共享包里，Mac 端和 iOS 端都使用同一个 PersistenceController（共享 iCloud 数据）。
//
// =============================================================================

import CoreData    // Apple 的持久化框架，提供 NSManagedObjectContext、NSPersistentCloudKitContainer 等
import Foundation  // 提供 UUID、Date、TimeInterval 等基础类型

/// Core Data + CloudKit 的统一管理器。
///
/// 【单例模式（Singleton）是什么？】
/// 单例意味着整个 App 生命周期内只有一个实例。
/// 好处：所有模块访问同一个数据库连接，不会出现"各自连自己的数据库"的混乱。
/// 用法：PersistenceController.shared（静态属性，全局访问）
///
/// 【@unchecked Sendable 再次出现】
/// NSManagedObjectContext 不是天然线程安全的（不是 Sendable），
/// 但 Core Data 有自己的线程安全机制（perform {}），
/// 我们承诺"自己保证线程安全"，用 @unchecked 绕过编译器检查。
public final class PersistenceController: @unchecked Sendable {

    // MARK: - 单例（Shared Instance）──────────────────────────────────────

    /// 全局共享实例。正式运行时所有模块通过这个单例访问数据库。
    ///
    /// 使用示例：
    ///   let controller = PersistenceController.shared
    ///   let records = controller.fetchRecentAnxietyRecords()
    public static let shared = PersistenceController()

    /// 用于 XCTest 单元测试 和 SwiftUI Preview 的内存版本。
    ///
    /// 【为什么测试要用 inMemory？】
    /// 如果测试写入磁盘数据库，测试之间会相互影响（A 测试留下的数据 B 测试看到了）。
    /// inMemory = true 时，数据只存在内存里，测试结束自动消失，互不干扰。
    ///
    /// preview 还会预先填入一条示例数据，这样 SwiftUI Preview 就能看到真实内容。
    public static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        // 为 Preview 填入一条示例 AnxietyRecord
        let ctx = controller.container.viewContext
        let record = AnxietyRecord(context: ctx) // 创建一个受 Core Data 追踪的对象
        record.id = UUID()
        record.timestamp = Date()
        record.anxietyScore = 0.72
        record.platform = "mac"
        record.appName = "Safari"
        record.notificationSent = true
        record.dynamicThreshold = 0.6
        try? ctx.save() // try? 表示：尝试保存，失败了也不崩溃
        return controller
    }()

    // MARK: - Core Data 容器 ───────────────────────────────────────────────

    /// Core Data 的核心：持久化存储容器。
    ///
    /// NSPersistentCloudKitContainer 是 NSPersistentContainer 的升级版，
    /// 额外提供了 iCloud CloudKit 自动同步能力。
    ///
    /// public 表示 Mac/iOS 两端的代码都可以直接访问这个 container 做高级查询。
    public let container: NSPersistentCloudKitContainer

    // MARK: - 初始化 ────────────────────────────────────────────────────────

    /// 初始化数据库。
    ///
    /// 一般不直接调用，通过 .shared 或 .preview 访问。
    ///
    /// - Parameter inMemory: true = 内存数据库（测试用），false = 磁盘数据库（正式运行）
    public init(inMemory: Bool = false) {
        // "ScreenMind" 对应 ScreenMind.xcdatamodeld 文件名（不含扩展名）
        container = NSPersistentCloudKitContainer(name: "ScreenMind")

        if inMemory {
            // /dev/null 是 Unix 的"黑洞"设备，写入数据立刻丢弃，永不存磁盘
            // 这样 Core Data 就在内存里运行，测试完全隔离
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // 正式环境：配置 CloudKit 同步

            let description = container.persistentStoreDescriptions.first!
            // CloudKit Container ID，必须和 ScreenMindMac.entitlements 里的配置一致
            description.cloudKitContainerOptions =
                NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.screenmind.app")
            // 开启"远程更改通知"：当其他设备（比如 iPhone）修改了数据库，本机会收到通知并刷新
            description.setOption(true as NSNumber,
                                  forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }

        // 加载持久化存储（实际打开/创建数据库文件）
        container.loadPersistentStores { _, error in
            if let error {
                // 数据库加载失败是严重错误（比如文件损坏、磁盘权限问题）
                // 生产环境应该改成显示错误 UI，但开发阶段直接 fatalError 更容易发现问题
                fatalError("Core Data failed to load: \(error.localizedDescription)")
            }
        }

        // automaticallyMergesChangesFromParent = true：
        //   当后台 context 保存数据后，主线程 context 自动同步最新数据
        //   没有这个设置，UI 可能还在显示旧数据
        container.viewContext.automaticallyMergesChangesFromParent = true

        // mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy：
        //   当主线程和后台线程同时修改同一个对象时的冲突解决策略
        //   "ObjectTrump" = 内存里的对象覆盖数据库里的（后修改者赢）
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - 通用写入辅助 ──────────────────────────────────────────────────

    /// 保存主线程 context 的所有待写入更改。
    ///
    /// 使用场景：在主线程上创建或修改 Core Data 对象后，调用 save() 写入磁盘。
    ///
    /// 注意：这个方法只保存 viewContext（主线程 context）的改动。
    /// 后台 context 的写入要用 ctx.save()，在 ctx.perform {} 块里调用。
    public func save() {
        let ctx = container.viewContext
        guard ctx.hasChanges else { return } // 如果没有改动，不需要写磁盘（省 I/O）
        do {
            try ctx.save()
        } catch {
            // assertionFailure 只在 Debug 模式下崩溃，Release 模式下只打印
            // 这样开发阶段能立刻发现问题，生产用户不受影响
            assertionFailure("Core Data save error: \(error)")
        }
    }

    /// 创建一个新的后台 context，供写入密集型操作使用。
    ///
    /// 【为什么要有 backgroundContext？】
    /// Core Data 的 context 不是线程安全的——同一个 context 不能在多个线程同时访问。
    /// viewContext 属于主线程，在主线程上做大量写入会卡 UI。
    /// 解决方案：专门创建后台 context，在后台线程写入，写完后自动同步给 viewContext。
    ///
    /// 使用示例：
    ///   let ctx = persistence.newBackgroundContext()
    ///   ctx.perform {
    ///       let record = AnxietyRecord(context: ctx)
    ///       // ... 设置属性 ...
    ///       try? ctx.save()
    ///   }
    public func newBackgroundContext() -> NSManagedObjectContext {
        let ctx = container.newBackgroundContext()
        // 后台 context 也用同样的冲突解决策略
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return ctx
    }

    // MARK: - M3 便捷写入：AnxietyRecord ──────────────────────────────────

    /// 在后台 context 中异步写入一条焦虑评分记录。
    ///
    /// 这是 AnxietyPipeline 之外的另一种写入方式：
    /// 当调用方不想自己管理 context 和线程时，调用这个方法即可。
    /// 方法内部自己创建 backgroundContext，在后台线程写入，调用方不需要知道这些细节。
    ///
    /// 【参数说明】
    /// - score: 焦虑分（0.0–1.0）
    /// - rawText: OCR 识别的原始文字（最多 500 字，超出会截断）
    /// - appName: 分析时的前景 App 名称（如 "Safari", "微信"），可选
    /// - platform: "mac" 或 "ios"，默认 "mac"
    /// - timestamp: 采集时间，默认为调用时刻
    /// - dynamicThreshold: 本次使用的动态阈值（供历史分析用）
    /// - notificationSent: 这次是否发送了系统通知
    public func saveAnxietyRecord(
        score: Double,
        rawText: String?,
        appName: String?,
        platform: String = "mac",
        timestamp: Date = .now,
        dynamicThreshold: Double,
        notificationSent: Bool
    ) {
        let ctx = newBackgroundContext()
        let id = UUID()  // 先在当前线程生成 UUID，避免在 perform 里用随机函数（虽然 UUID 是线程安全的，这是好习惯）
        ctx.perform {
            let record              = AnxietyRecord(context: ctx)
            record.id               = id
            record.timestamp        = timestamp
            record.anxietyScore     = score
            record.rawText          = rawText
            record.appName          = appName
            record.platform         = platform
            record.dynamicThreshold = dynamicThreshold
            record.notificationSent = notificationSent
            try? ctx.save() // 失败就忽略（后续版本可以加重试机制）
        }
    }

    // MARK: - M3 查询辅助 ──────────────────────────────────────────────────

    /// 获取最近 N 条焦虑记录（按时间降序，最新的排前面）。
    ///
    /// 用途：
    ///   - 历史记录列表页面（显示"今天共检测到 5 次高焦虑"）
    ///   - 调试窗口统计
    ///   - 单元测试验证数据写入
    ///
    /// - Parameters:
    ///   - limit: 最多返回多少条，默认 50
    ///   - context: 指定用哪个 context 查询，不传则使用主线程 viewContext
    /// - Returns: AnxietyRecord 数组（可能为空）
    public func fetchRecentAnxietyRecords(
        limit: Int = 50,
        context: NSManagedObjectContext? = nil
    ) -> [AnxietyRecord] {
        let ctx = context ?? container.viewContext
        let request = AnxietyRecord.fetchRequest()  // Core Data 自动生成的查询对象
        // NSSortDescriptor：指定排序方式（key = 要排序的字段，ascending = false 表示降序）
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = limit  // 最多返回 limit 条
        // try? 失败返回 nil，再用 ?? [] 替换成空数组（避免 crash）
        return (try? ctx.fetch(request)) ?? []
    }

    // MARK: - M4 便捷方法：HRVBaseline ────────────────────────────────────

    /// 查询 Core Data 中最近一条 HRVBaseline 记录（Mac 平台）。
    ///
    /// 调用方：HRVIntegrator.restoreBaselineFromCoreData()
    ///   App 冷启动时读取上次保存的基线，立刻提供合理的初始乘数。
    ///
    /// - Parameter context: 使用的 context，不传则用主线程 viewContext
    /// - Returns: 最新的 HRVBaseline 记录，没有则返回 nil
    public func fetchLatestHRVBaseline(
        context: NSManagedObjectContext? = nil
    ) -> HRVBaseline? {
        let ctx = context ?? container.viewContext
        let request = HRVBaseline.fetchRequest()
        // 按 date 降序（最新的排最前）
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchLimit = 1  // 只取最新一条
        // predicate 过滤 mac 平台的记录（iOS 端的基线数据虽然通过 CloudKit 同步过来，
        // 但 Mac 端应该优先使用自己平台的数据）
        request.predicate = NSPredicate(format: "platform == %@", "mac")
        return (try? ctx.fetch(request))?.first
    }

    /// 保存或更新 HRVBaseline 记录到 Core Data（后台写入）。
    ///
    /// 调用方：HRVIntegrator.saveBaselineToCoreData()
    ///   这是一个更高层次的便捷方法，HRVIntegrator 也可以选择直接使用，
    ///   或者自己管理 ctx.perform（HRVIntegrator 目前是自己管理，两者等效）。
    ///
    /// 【更新策略】
    ///   如果已有 Mac 平台的记录，更新它（不重复创建）。
    ///   这样数据库里 Mac 端只有一条 HRVBaseline 记录，保持干净。
    ///
    /// - Parameter rollingAvg30d: 当前 30 天 SDNN 均值（毫秒）
    public func saveHRVBaseline(rollingAvg30d: Double) {
        guard rollingAvg30d > 0 else { return }  // 防止写入无效数据

        let ctx = newBackgroundContext()
        let value = rollingAvg30d  // 提前捕获，避免在 ctx.perform 里捕获 self

        ctx.perform {
            // 查找已有的 Mac 端记录
            let request = HRVBaseline.fetchRequest()
            request.predicate = NSPredicate(format: "platform == %@", "mac")
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            request.fetchLimit = 1

            let baseline: HRVBaseline
            if let existing = (try? ctx.fetch(request))?.first {
                baseline = existing  // 更新已有记录
            } else {
                baseline = HRVBaseline(context: ctx)  // 首次写入
                baseline.id = UUID()
                baseline.platform = "mac"
            }

            baseline.date          = Date()   // 记录更新时间
            baseline.sdnn          = value    // 当前基线（ms）
            baseline.rollingAvg30d = value    // 30 天滚动均值（ms）

            try? ctx.save()
        }
    }

    /// 计算最近 24 小时内所有焦虑记录的平均分。
    ///
    /// 用途：
    ///   - 菜单栏 Tooltip 显示"今日焦虑均值：42%"
    ///   - 健康仪表盘的当日统计
    ///
    /// - Parameter context: 指定 context，不传则用主线程 viewContext
    /// - Returns: 均值（0.0–1.0），如果 24 小时内没有记录则返回 nil
    public func last24hMeanScore(context: NSManagedObjectContext? = nil) -> Double? {
        let ctx = context ?? container.viewContext
        let request = AnxietyRecord.fetchRequest()

        // 计算 24 小时前的时间点
        let cutoff = Date().addingTimeInterval(-86400) // 86400 秒 = 24 小时

        // NSPredicate：查询条件（类似 SQL WHERE 子句）
        // "timestamp >= %@" 表示：只查 timestamp 大于等于 cutoff 的记录
        // %@ 是占位符，对应后面的 cutoff as NSDate（Core Data 要求桥接为 NSDate）
        request.predicate = NSPredicate(format: "timestamp >= %@", cutoff as NSDate)

        guard let records = try? ctx.fetch(request), !records.isEmpty else { return nil }

        // 计算均值：把所有记录的 anxietyScore 加起来除以记录数
        // reduce(0.0) { 累加器, 当前记录 in 累加器 + 当前记录.anxietyScore }
        let sum = records.reduce(0.0) { $0 + $1.anxietyScore }
        return sum / Double(records.count)
    }
}
