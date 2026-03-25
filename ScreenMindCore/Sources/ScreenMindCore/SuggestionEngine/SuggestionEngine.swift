// =============================================================================
//  SuggestionEngine.swift
//  ScreenMindCore — 跨平台共享层
// =============================================================================
//
//  【里程碑 M6-Mac：放松建议引擎（完整重写）】
//
//  【产品需求：这个文件解决什么问题？】
//  当 ScreenMind 检测到用户焦虑时，它不只是"报警"，还要给出"解药"。
//  SuggestionEngine 就是负责"给出解药"的模块。
//
//  它从 Core Data 的 RelaxationSuggestion 表里读取用户预设的放松建议，
//  根据"当前用户最适合什么放松方式"来排序推荐。
//
//  【M6 扩展：从单一地点到六大服务类别】
//  M1 阶段：只支持"去附近地点"（公园、咖啡厅）
//  M6 阶段：扩展为六大类：
//    - place       附近地点（原有）
//    - fitness     健身运动（Keep 等）
//    - course      在线课程（得到等）
//    - food        外卖点餐（美团/饿了么）
//    - entertainment 娱乐（猫眼/大麦）
//    - homeService 到家服务（美团到家/58到家）
//
//  【Module 1 vs Module 2】
//  SuggestionEngine 管理 Module 1（用户预设列表）：
//    - 用户在设置里手动添加的地点、服务
//    - 由用户自己维护，代表个人偏好
//
//  Module 2（养生达人动态推荐）由 InfluencerTracker（M7）管理，不在本文件。
//
//  【数据流】
//  ┌───────────────────────────────────────────────────────────────────┐
//  │  AnxietyPipeline.onAlert（焦虑触发）                              │
//  │       ↓                                                           │
//  │  StatusBarController → SuggestionEngine.topSuggestions()         │
//  │       ↓ 从 Core Data 读取启用的建议                               │
//  │  按分类分组 → 每类取 top 1–2 条                                   │
//  │       ↓                                                           │
//  │  SuggestionEngine.refreshTravelTimes()（只针对 .place 类）        │
//  │   用 MapKit 计算各地点的驾车时间                                  │
//  │       ↓                                                           │
//  │  返回 [SuggestionItem]（已排序，有车程信息）                      │
//  │       ↓                                                           │
//  │  AlertPanel.swift（M8）展示给用户                                 │
//  └───────────────────────────────────────────────────────────────────┘
//
//  【部署位置】
//  ScreenMindCore/Sources/ScreenMindCore/SuggestionEngine/SuggestionEngine.swift
//  在共享包里，Mac 端和 iOS 端都能用（iOS 端的放松建议功能未来可以共享这个引擎）。
//
// =============================================================================

import Foundation      // 基础类型
import CoreLocation    // CLLocation（经纬度）、CLGeocoder（地址 → 经纬度）
import MapKit          // MKDirections（计算驾车时间）、MKPlacemark
import CoreData        // NSPredicate、NSSortDescriptor（Core Data 查询）

// =============================================================================
// MARK: - SuggestionEngine 主类
// =============================================================================

/// M6 放松建议引擎（Module 1：用户个人预设列表）。
///
/// 【@unchecked Sendable 说明】
/// SuggestionEngine 持有 PersistenceController 引用。
/// PersistenceController 内部的 NSPersistentContainer 不是标准 Sendable，
/// 但 SuggestionEngine 所有方法都通过 Core Data 的线程安全 API（ctx.perform）操作，
/// 手动保证了线程安全。
/// 用 @unchecked 告知编译器"我知道风险，已手动处理"。
public final class SuggestionEngine: @unchecked Sendable {

    // MARK: - 内部组件 ────────────────────────────────────────────────────────

    /// Core Data 存储控制器（用于从 RelaxationSuggestion 表读写数据）。
    ///
    /// 使用 .shared 单例：全 App 共用一个 SQLite 数据库连接，避免多实例竞争。
    private let persistence: PersistenceController

    // MARK: - 初始化 ──────────────────────────────────────────────────────────

    /// 初始化引擎。
    ///
    /// persistence 有默认值 .shared，方便直接使用：
    ///   let engine = SuggestionEngine()
    ///
    /// 单元测试时可以注入 in-memory store：
    ///   let engine = SuggestionEngine(persistence: .inMemory)
    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 公开方法 1：获取所有启用的建议（按分类分组）
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 从 Core Data 获取所有"启用"的放松建议，按照 sortOrder 排序。
    ///
    /// 这是最基础的读取方法，返回全部启用的建议（不分类、不限数量）。
    /// 供设置界面展示完整列表使用。
    ///
    /// 【为什么是 async？】
    /// Core Data 的 fetch 操作需要在特定线程（viewContext 对应主线程）执行。
    /// 用 async/await 可以把"等待 fetch 完成"的操作非阻塞化，
    /// 调用方不会卡住主线程（即使 fetch 耗时，也只是暂停当前 Task）。
    ///
    /// - Returns: 所有启用的建议，按 sortOrder 升序排列
    public func enabledSuggestions() async -> [SuggestionItem] {
        let ctx = persistence.container.viewContext

        // NSFetchRequest<RelaxationSuggestion>：类型安全的 Core Data 查询请求
        // 等同于 SQL：SELECT * FROM RelaxationSuggestion WHERE isEnabled = 1 ORDER BY sortOrder ASC
        let request = RelaxationSuggestion.fetchRequest()
        request.predicate = NSPredicate(format: "isEnabled == YES")  // 过滤条件：只要启用的
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)] // 升序排列

        // ctx.fetch(request)：执行查询，返回 [RelaxationSuggestion]
        // try? ... ?? []：如果 fetch 失败（数据库损坏等），返回空数组，不崩溃
        let results = (try? ctx.fetch(request)) ?? []

        // 把 Core Data 对象（RelaxationSuggestion）映射成纯 Swift 值类型（SuggestionItem）
        // 这是"从数据库对象转换成 App 用的数据结构"的标准做法
        return results.map { entity in
            let categoryRaw = entity.category ?? SuggestionCategory.place.rawValue
            let category = SuggestionCategory(rawValue: categoryRaw) ?? .place

            // 解析 serviceConfig JSON（如果有）
            let serviceConfig = decodeServiceConfig(from: entity.serviceConfigJSON)

            return SuggestionItem(
                id: entity.id ?? UUID(),
                title: entity.title ?? "",
                detail: entity.detail,
                address: entity.address,
                latitude: entity.latitude == 0 ? nil : entity.latitude,
                longitude: entity.longitude == 0 ? nil : entity.longitude,
                travelMinutes: entity.travelMinutes == 0 ? nil : Int(entity.travelMinutes),
                category: category,
                serviceConfig: serviceConfig
            )
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 公开方法 2：获取焦虑触发时的推荐列表（分类路由）
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 焦虑触发时调用：返回最适合展示给用户的放松建议（每类 top 2）。
    ///
    /// 【分类路由逻辑】
    /// 从 Core Data 读取全部启用建议后，按 `SuggestionCategory` 分组。
    /// 每个分类最多取 2 条（避免 AlertPanel 显示太多选项造成选择困难）。
    /// 最终返回的顺序：
    ///   1. place（最直接的"离开屏幕"方式，排在最前）
    ///   2. fitness（运动发泄效果好，排第二）
    ///   3. food（即时奖励，用户接受度高）
    ///   4. entertainment（放松但还在屏幕前，排第四）
    ///   5. course（主动学习，需要一定意愿）
    ///   6. homeService（预约流程长，放最后）
    ///
    /// - Parameter maxPerCategory: 每类最多返回几条，默认 2
    /// - Returns: 按分类优先级排列的放松建议数组
    public func topSuggestions(maxPerCategory: Int = 2) async -> [SuggestionItem] {
        let all = await enabledSuggestions()

        // 用 Dictionary(grouping:) 按 category 分组
        // 结果是 [SuggestionCategory: [SuggestionItem]] 字典
        let grouped = Dictionary(grouping: all, by: { $0.category })

        // 定义展示优先级（按用户焦虑时最可能接受的顺序排列）
        let priorityOrder: [SuggestionCategory] = [
            .place,
            .fitness,
            .food,
            .entertainment,
            .course,
            .homeService
        ]

        // 按优先级顺序，从每个分类里取最多 maxPerCategory 条
        var result: [SuggestionItem] = []
        for category in priorityOrder {
            let items = grouped[category] ?? []
            // prefix(maxPerCategory)：取前 N 条（如果不足 N 条，全部取）
            result.append(contentsOf: items.prefix(maxPerCategory))
        }

        return result
    }

    /// 返回指定分类的放松建议（供用户在设置界面按分类浏览）。
    ///
    /// 使用场景：用户在设置里点击某个分类的 tab，显示该分类下所有建议。
    ///
    /// - Parameter category: 要查询的分类
    /// - Returns: 该分类下所有启用的建议，按 sortOrder 排序
    public func suggestions(for category: SuggestionCategory) async -> [SuggestionItem] {
        let ctx = persistence.container.viewContext
        let request = RelaxationSuggestion.fetchRequest()
        // 同时过滤：启用的 AND 指定分类
        request.predicate = NSPredicate(
            format: "isEnabled == YES AND category == %@",
            category.rawValue
        )
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        let results = (try? ctx.fetch(request)) ?? []

        return results.map { entity in
            let serviceConfig = decodeServiceConfig(from: entity.serviceConfigJSON)
            return SuggestionItem(
                id: entity.id ?? UUID(),
                title: entity.title ?? "",
                detail: entity.detail,
                address: entity.address,
                latitude: entity.latitude == 0 ? nil : entity.latitude,
                longitude: entity.longitude == 0 ? nil : entity.longitude,
                travelMinutes: entity.travelMinutes == 0 ? nil : Int(entity.travelMinutes),
                category: SuggestionCategory(rawValue: entity.category ?? "") ?? category,
                serviceConfig: serviceConfig
            )
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 公开方法 3：刷新地点类建议的车程信息
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 为所有地点类（.place 分类）建议计算或更新驾车时间。
    ///
    /// 【什么情况下需要刷新？】
    ///   - 用户第一次添加某个地点建议（travelMinutes 是 nil）
    ///   - 上次更新超过 1 天（用户位置可能变了，或地点距离变了）
    ///
    /// 【技术细节】
    ///   1. CLGeocoder：把地址文字（"长宁区中山公园"）转成经纬度坐标
    ///   2. MKDirections：计算从 origin 到目的地的驾车时间
    ///   3. 结果写回 Core Data
    ///
    /// 【为什么只针对 .place 类？】
    ///   其他类（fitness/food/course 等）是线上服务，不需要计算到达时间。
    ///   车程计算只对"需要去某个具体地点"的建议有意义。
    ///
    /// - Parameter origin: 用户当前位置（由 CLLocationManager 提供）
    public func refreshTravelTimes(from origin: CLLocation) async {
        let ctx = persistence.newBackgroundContext()

        // ctx.perform {} 是 Core Data 的线程安全调用方式
        // "在这个 context 对应的队列上执行这段代码"，避免多线程数据竞争
        await ctx.perform {
            // 只查询：有地址 + place 分类 + 车程需要更新的建议
            let request = RelaxationSuggestion.fetchRequest()
            request.predicate = NSPredicate(
                format: "address != nil AND address != '' AND category == %@",
                SuggestionCategory.place.rawValue
            )
            guard let suggestions = try? ctx.fetch(request) else { return }

            Task {
                for suggestion in suggestions {
                    guard let address = suggestion.address, !address.isEmpty else { continue }

                    // 判断车程是否需要刷新：
                    //   - travelUpdatedAt 是 nil → 从未计算过，需要计算
                    //   - travelUpdatedAt 超过 1 天（86400 秒）→ 过期，需要重新计算
                    if let updated = suggestion.travelUpdatedAt,
                       Date().timeIntervalSince(updated) < 86400 {
                        continue  // 1 天内已计算过，跳过
                    }

                    do {
                        // 调用 MapKit 计算驾车时间（可能需要网络）
                        let minutes = try await self.travelMinutes(from: origin, toAddress: address)
                        suggestion.travelMinutes = Int32(minutes)
                        suggestion.travelUpdatedAt = Date()  // 更新时间戳
                        try? ctx.save()  // 写回数据库
                    } catch {
                        // 地址识别失败或网络问题 → 静默跳过（不影响其他建议的计算）
                    }
                }
            }
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 公开方法 4：MapKit 路径规划（车程计算）
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 计算从起点到目标地址的驾车时间（分钟数）。
    ///
    /// 【两步流程】
    /// Step 1（CLGeocoder）：地址文字 → 经纬度坐标
    ///   "长宁区中山公园" → CLLocation(latitude: 31.22, longitude: 121.41)
    ///   这需要网络请求（Apple 地图服务器处理）
    ///
    /// Step 2（MKDirections）：起点坐标 + 终点坐标 → 驾车路线 → 预计时间
    ///   这也需要网络请求（Apple 地图路况服务）
    ///
    /// 两步都是异步的，所以整个方法是 async throws。
    /// throws 表示可能失败：地址识别失败（错别字/偏远地区）或无路可达（海岛）。
    ///
    /// - Parameters:
    ///   - origin: 出发地（用户当前位置）
    ///   - address: 目的地地址文字（中文地址，如 "上海市长宁区中山公园"）
    /// - Returns: 预计驾车时间（分钟数，四舍五入为整数）
    /// - Throws: SuggestionError.geocodingFailed 或 SuggestionError.noRouteFound
    public func travelMinutes(from origin: CLLocation, toAddress address: String) async throws -> Int {
        // ── 步骤 1：地理编码（地址文字 → 坐标）───────────────────────────
        // CLGeocoder 是苹果地图的地理编码器，支持中文地址
        let geocoder = CLGeocoder()

        // geocodeAddressString：异步方法，返回 [CLPlacemark]（可能多个结果）
        // 比如"中山公园"在上海、广州都有，可能返回多个结果
        let placemarks = try await geocoder.geocodeAddressString(address)

        // 取第一个结果（通常是最相关的）
        // .location：CLPlacemark 里的位置坐标（CLLocation）
        guard let destination = placemarks.first?.location else {
            throw SuggestionError.geocodingFailed  // 地址识别失败（拼写错误、偏远无数据）
        }

        // ── 步骤 2：路线规划（起点 + 终点 → 驾车时间）───────────────────
        // MKPlacemark 是 MapKit 的地标，包含坐标和地址信息
        let sourcePlacemark = MKPlacemark(coordinate: origin.coordinate)
        let destPlacemark   = MKPlacemark(coordinate: destination.coordinate)

        // MKDirections.Request：路线请求配置
        let request            = MKDirections.Request()
        request.source         = MKMapItem(placemark: sourcePlacemark) // 出发点
        request.destination    = MKMapItem(placemark: destPlacemark)   // 目的地
        request.transportType  = .automobile  // 驾车模式（不是步行或公交）

        // MKDirections：苹果地图路线计算器
        let directions = MKDirections(request: request)

        // calculate()：发起路线计算请求（异步，等待苹果服务器响应）
        let response = try await directions.calculate()

        // 取最优路线（response.routes 按质量排序，第一个是最佳路线）
        guard let route = response.routes.first else {
            throw SuggestionError.noRouteFound  // 没有可达路线（如两地之间是海洋）
        }

        // expectedTravelTime 是秒数，除以 60 得分钟数
        // Int(...)：向下取整（2.9 分钟 → 2 分钟，保守估计）
        return Int(route.expectedTravelTime / 60)
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 公开方法 5：添加/更新建议（设置界面保存时调用）
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 添加或更新一条放松建议到 Core Data。
    ///
    /// 使用"upsert"模式（update or insert）：
    ///   - 如果 suggestion.id 已存在于数据库 → 更新现有记录
    ///   - 如果不存在 → 插入新记录
    ///
    /// - Parameter suggestion: 要保存的建议条目
    public func saveSuggestion(_ suggestion: SuggestionItem) async {
        let ctx = persistence.newBackgroundContext()

        // 预先提取所有需要保存的值（值类型，线程安全）
        // 不能在 ctx.perform {} 里直接访问 suggestion，
        // 因为 SuggestionItem 虽然是 Sendable，但 actor 隔离规则下需要提前捕获
        let id              = suggestion.id
        let title           = suggestion.title
        let detail          = suggestion.detail
        let address         = suggestion.address
        let latitude        = suggestion.latitude ?? 0
        let longitude       = suggestion.longitude ?? 0
        let category        = suggestion.category.rawValue
        let serviceConfigJSON = encodeServiceConfig(suggestion.serviceConfig)

        ctx.perform {
            // 查找是否已有这个 id 的记录
            let request = RelaxationSuggestion.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let existing = try? ctx.fetch(request)

            // 没有找到 → 创建新记录；找到了 → 更新现有记录
            let entity = existing?.first ?? RelaxationSuggestion(context: ctx)
            entity.id         = id
            entity.title      = title
            entity.detail     = detail
            entity.address    = address
            entity.latitude   = latitude
            entity.longitude  = longitude
            entity.isEnabled  = true  // 新添加的默认启用
            entity.category   = category
            entity.serviceConfigJSON = serviceConfigJSON

            try? ctx.save()
        }
    }

    /// 删除一条放松建议（软删除：只是把 isEnabled 设为 false）。
    ///
    /// 为什么不直接删除？
    ///   - 保留历史记录（未来分析"用户喜欢什么放松方式"）
    ///   - 用户可能误删，软删除方便恢复
    ///   - isEnabled=false 的记录不会出现在建议列表里
    ///
    /// - Parameter id: 要禁用的建议 UUID
    public func disableSuggestion(id: UUID) async {
        let ctx = persistence.newBackgroundContext()
        let capturedID = id  // 提前捕获，避免 actor 隔离问题

        ctx.perform {
            let request = RelaxationSuggestion.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", capturedID as CVarArg)
            if let entity = (try? ctx.fetch(request))?.first {
                entity.isEnabled = false
                try? ctx.save()
            }
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 预设数据：首次安装时填充默认建议
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 首次安装时，向数据库写入一套默认的放松建议。
    ///
    /// 这样用户第一次触发焦虑提醒时，就有现成的建议可以看，
    /// 不会出现"建议列表是空的"的尴尬情况。
    ///
    /// 默认建议涵盖 6 个类别，各 1–2 条。
    /// 用户之后可以在设置里增删改。
    ///
    /// - Parameter location: 可选的用户当前城市提示（用于更贴合的默认地点名）
    public func seedDefaultSuggestions() async {
        // 先检查数据库是否已有数据（避免重复 seed）
        let existing = await enabledSuggestions()
        guard existing.isEmpty else { return }  // 已有数据，跳过

        // 构造六大类各一条示例建议
        let defaults: [SuggestionItem] = [

            // ── 地点类 ───────────────────────────────────────────────────────
            SuggestionItem(
                title: "去附近公园走走",
                detail: "离开屏幕，在绿色环境中走 15-30 分钟，对降低焦虑效果显著。",
                address: "附近公园",  // 用户可以在设置里改成具体地址
                category: .place
            ),

            // ── 健身类 ───────────────────────────────────────────────────────
            SuggestionItem(
                title: "Keep 15分钟瑜伽放松",
                detail: "跟着 Keep 做一节放松瑜伽，专注呼吸可以快速平复焦虑情绪。",
                category: .fitness,
                serviceConfig: ServiceOrderConfig(
                    provider: .keep,
                    searchKeyword: "瑜伽 放松 15分钟",
                    preferredPackageKeywords: ["新人", "体验", "免费", "月卡"],
                    serviceDescription: "Keep 放松瑜伽"
                )
            ),

            // ── 外卖类 ───────────────────────────────────────────────────────
            SuggestionItem(
                title: "点一份健康轻食",
                detail: "焦虑时避免油腻食物，选择沙拉或轻食，吃好了心情也会好一点。",
                category: .food,
                serviceConfig: ServiceOrderConfig(
                    provider: .meituanFood,
                    searchKeyword: "健康轻食 沙拉",
                    preferredPackageKeywords: ["满减", "新客", "优惠"],
                    serviceDescription: "健康轻食外卖"
                )
            ),

            // ── 娱乐类 ───────────────────────────────────────────────────────
            SuggestionItem(
                title: "看一部轻松喜剧",
                detail: "选一部轻松搞笑的电影，笑声是最好的压力释放剂。",
                category: .entertainment,
                serviceConfig: ServiceOrderConfig(
                    provider: .maoyan,
                    searchKeyword: "喜剧 轻松",
                    targetURL: "https://www.maoyan.com/films?showType=3",  // 今日上映
                    preferredPackageKeywords: ["喜剧", "轻松", "温馨"],
                    serviceDescription: "猫眼电影票"
                )
            ),

            // ── 课程类 ───────────────────────────────────────────────────────
            SuggestionItem(
                title: "听一节冥想课",
                detail: "得到上有很多冥想和减压课程，边学边放松。",
                category: .course,
                serviceConfig: ServiceOrderConfig(
                    provider: .dedao,
                    searchKeyword: "冥想 减压 正念",
                    preferredPackageKeywords: ["免费试听", "体验课", "7天"],
                    serviceDescription: "得到冥想减压课"
                )
            ),

            // ── 到家服务类 ───────────────────────────────────────────────────
            SuggestionItem(
                title: "预约上门按摩放松",
                detail: "专业按摩师上门服务，在家就能享受深度放松，适合长期焦虑积累。",
                category: .homeService,
                serviceConfig: ServiceOrderConfig(
                    provider: .meituanHome,
                    searchKeyword: "上门按摩 全身放松",
                    preferredPackageKeywords: ["新客优惠", "性价比", "高评分"],
                    serviceDescription: "美团到家上门按摩"
                )
            )
        ]

        // 逐条保存到 Core Data
        for item in defaults {
            await saveSuggestion(item)
        }
    }

    // MARK: - ─────────────────────────────────────────────────────────────────
    // MARK: 内部：ServiceOrderConfig 序列化/反序列化
    // MARK: ─────────────────────────────────────────────────────────────────

    /// 把 ServiceOrderConfig 编码成 JSON 字符串，存入 Core Data 的 serviceConfigJSON 字段。
    ///
    /// 【为什么不直接存到 Core Data 属性里？】
    /// ServiceOrderConfig 是自定义 struct，Core Data 原生不支持存复杂 struct。
    /// 解决方案：序列化成 JSON 字符串，存到 Core Data 的 String 字段里。
    /// 读取时再反序列化回来。
    ///
    /// 这是移动端存储复杂对象的常见模式，简单可靠。
    ///
    /// - Parameter config: 要序列化的配置，nil 时返回 nil
    /// - Returns: JSON 字符串，或 nil（config 为 nil 或序列化失败）
    private func encodeServiceConfig(_ config: ServiceOrderConfig?) -> String? {
        guard let config else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys  // 固定 key 顺序，方便对比和调试
        guard let data = try? encoder.encode(config),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// 把存在 Core Data 里的 JSON 字符串反序列化成 ServiceOrderConfig。
    ///
    /// - Parameter json: Core Data 里存的 JSON 字符串
    /// - Returns: ServiceOrderConfig，或 nil（json 为 nil、为空、或格式不对）
    private func decodeServiceConfig(from json: String?) -> ServiceOrderConfig? {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ServiceOrderConfig.self, from: data)
    }

    // MARK: - 错误类型 ────────────────────────────────────────────────────────

    /// SuggestionEngine 的错误枚举。
    ///
    /// Sendable：可以在 async/await 的 throws 里传递（跨线程安全）。
    public enum SuggestionError: Error, Sendable {

        /// CLGeocoder 无法解析地址（地址错误或网络不通）
        case geocodingFailed

        /// MKDirections 找不到可达路线（两地之间没有公路）
        case noRouteFound
    }
}
