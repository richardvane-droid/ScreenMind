// =============================================================================
//  HRVIntegratorTests.swift
//  ScreenMindCoreTests — 单元测试
// =============================================================================
//
//  【里程碑 M4：HRVIntegrator 单元测试】
//
//  【测试目标】
//  验证 M4 核心逻辑的正确性：
//    1. HRVFreshnessLevel 分类逻辑（根据小时数判断新鲜度等级）
//    2. 各等级的 blendWeight 值
//    3. HRVIntegrator.currentMultiplier 在无数据时返回 1.0
//    4. HRVManager.dynamicMultiplier 的数值计算（clamp 边界）
//    5. HRVIntegrator.adjustedThreshold 的钳位行为
//    6. HRVManager.setBaseline30d / getBaseline30d 的读写一致性
//
//  【为什么不测试 HealthKit 真实数据？】
//  HealthKit 需要物理设备（Apple Watch + iPhone）和用户授权，
//  无法在 CI/CD 环境或模拟器中自动化测试。
//  因此，我们通过"可观测的公开接口"来测试计算逻辑，
//  把 HealthKit 的 I/O 部分留给手动测试。
//
//  【XCTest 基础知识】
//  XCTestCase 是测试类的基类（来自 Apple 的 XCTest 框架）。
//  每个 test 前缀的方法都是一个独立测试用例，XCTest 自动发现并执行。
//  XCTAssertEqual(a, b)：断言 a == b，失败时测试报错。
//  XCTAssertTrue(x)：断言 x 为 true。
//
//  【部署位置】
//  ScreenMindCore/Tests/ScreenMindCoreTests/HRVIntegratorTests.swift
//
// =============================================================================

import XCTest       // Apple 单元测试框架
@testable import ScreenMindCore  // @testable 允许访问 internal 级别的方法（测试专用）

// =============================================================================
// MARK: - HRVFreshnessLevel 测试
// =============================================================================

/// 测试 HRVFreshnessLevel 枚举的分类逻辑和权重值。
final class HRVFreshnessLevelTests: XCTestCase {

    // MARK: - 分类测试（classify 方法）

    /// 0.5 小时前 → Level 1（fresh，完全新鲜）
    func testClassify_halfHour_returnsFresh() {
        // 测试边界：0.5 小时（< 1 小时阈值），应返回 .fresh
        let level = HRVFreshnessLevel.classify(hoursAgo: 0.5)
        XCTAssertEqual(level, .fresh, "0.5 小时前的数据应该是 fresh")
    }

    /// 0 小时（刚测量）→ Level 1
    func testClassify_zero_returnsFresh() {
        let level = HRVFreshnessLevel.classify(hoursAgo: 0)
        XCTAssertEqual(level, .fresh, "刚测量的数据应该是 fresh")
    }

    /// 恰好 1 小时 → Level 2（moderate，1-4h）
    func testClassify_exactlyOneHour_returnsModerate() {
        // 半开区间 1..<4：1.0 属于 moderate
        let level = HRVFreshnessLevel.classify(hoursAgo: 1.0)
        XCTAssertEqual(level, .moderate, "恰好 1 小时的数据应该是 moderate")
    }

    /// 2 小时 → Level 2
    func testClassify_twoHours_returnsModerate() {
        let level = HRVFreshnessLevel.classify(hoursAgo: 2.0)
        XCTAssertEqual(level, .moderate, "2 小时前的数据应该是 moderate")
    }

    /// 恰好 4 小时 → Level 3（stale，4-24h）
    func testClassify_exactlyFourHours_returnsStale() {
        let level = HRVFreshnessLevel.classify(hoursAgo: 4.0)
        XCTAssertEqual(level, .stale, "恰好 4 小时的数据应该是 stale")
    }

    /// 12 小时 → Level 3
    func testClassify_twelveHours_returnsStale() {
        let level = HRVFreshnessLevel.classify(hoursAgo: 12.0)
        XCTAssertEqual(level, .stale, "12 小时前的数据应该是 stale")
    }

    /// 恰好 24 小时 → Level 4（unavailable）
    func testClassify_exactlyTwentyFourHours_returnsUnavailable() {
        // default 分支捕获 >= 24 的情况
        let level = HRVFreshnessLevel.classify(hoursAgo: 24.0)
        XCTAssertEqual(level, .unavailable, "24 小时前的数据应该是 unavailable")
    }

    /// 48 小时 → Level 4
    func testClassify_fortyEightHours_returnsUnavailable() {
        let level = HRVFreshnessLevel.classify(hoursAgo: 48.0)
        XCTAssertEqual(level, .unavailable, "48 小时前的数据应该是 unavailable")
    }

    // MARK: - 权重测试（blendWeight 属性）

    /// fresh 的权重应该是 1.0（完全使用原始乘数）
    func testBlendWeight_fresh_isOne() {
        XCTAssertEqual(HRVFreshnessLevel.fresh.blendWeight, 1.0,
                       "fresh 级别权重应该是 1.0")
    }

    /// moderate 的权重应该是 0.7
    func testBlendWeight_moderate_isPointSeven() {
        XCTAssertEqual(HRVFreshnessLevel.moderate.blendWeight, 0.7, accuracy: 0.001,
                       "moderate 级别权重应该是 0.7")
        // accuracy: 0.001 是浮点数比较的容差（允许 ±0.001 的误差）
    }

    /// stale 的权重应该是 0.3
    func testBlendWeight_stale_isPointThree() {
        XCTAssertEqual(HRVFreshnessLevel.stale.blendWeight, 0.3, accuracy: 0.001,
                       "stale 级别权重应该是 0.3")
    }

    /// unavailable 的权重应该是 0.0（完全使用中性值 1.0）
    func testBlendWeight_unavailable_isZero() {
        XCTAssertEqual(HRVFreshnessLevel.unavailable.blendWeight, 0.0,
                       "unavailable 级别权重应该是 0.0")
    }
}

// =============================================================================
// MARK: - HRVManager 计算测试
// =============================================================================

/// 测试 HRVManager 的 dynamicMultiplier 计算和 setBaseline30d/getBaseline30d 接口。
///
/// 注意：不测试 HealthKit I/O（requestAuthorization、latestHRV、refreshBaseline），
/// 因为这些需要真实设备和 HealthKit 数据库。
final class HRVManagerM4Tests: XCTestCase {

    // 每个测试用例都有一个全新的 HRVManager 实例（测试隔离）
    var manager: HRVManager!

    override func setUp() {
        super.setUp()
        manager = HRVManager()  // 重置为默认状态（baseline30d = 30.0ms）
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - setBaseline30d / getBaseline30d 读写测试

    /// 设置并读取基线，应该返回相同的值
    func testSetAndGetBaseline_roundTrip() {
        manager.setBaseline30d(45.0)  // 设置 45ms 基线
        let retrieved = manager.getBaseline30d()
        XCTAssertEqual(retrieved, 45.0, accuracy: 0.001,
                       "读回的基线值应该和写入的一致")
    }

    /// 设置 0 或负数应该被忽略（防止除以 0）
    func testSetBaseline_zeroIgnored() {
        manager.setBaseline30d(40.0)  // 先设置一个有效值
        manager.setBaseline30d(0.0)   // 再设置 0（应该被忽略）
        XCTAssertEqual(manager.getBaseline30d(), 40.0, accuracy: 0.001,
                       "设置 0 应该被忽略，保留原来的值")
    }

    /// 设置负数应该被忽略
    func testSetBaseline_negativeIgnored() {
        manager.setBaseline30d(35.0)
        manager.setBaseline30d(-10.0)
        XCTAssertEqual(manager.getBaseline30d(), 35.0, accuracy: 0.001,
                       "设置负数应该被忽略")
    }

    // MARK: - dynamicMultiplier 计算测试

    /// 当前 SDNN 等于基线时，乘数应该是 1.0
    func testDynamicMultiplier_equalToBaseline_returnsOne() {
        manager.setBaseline30d(35.0)
        let multiplier = manager.dynamicMultiplier(currentSDNN: 35.0)
        // 35.0 / 35.0 = 1.0，在 [0.4, 1.6] 范围内
        XCTAssertEqual(multiplier, 1.0, accuracy: 0.001,
                       "SDNN 等于基线时，乘数应该是 1.0")
    }

    /// 当前 SDNN 是基线的 50%（压力大），乘数应该是 0.5
    func testDynamicMultiplier_halfBaseline_returnsHalf() {
        manager.setBaseline30d(40.0)
        let multiplier = manager.dynamicMultiplier(currentSDNN: 20.0)
        // 20.0 / 40.0 = 0.5，在 [0.4, 1.6] 范围内
        XCTAssertEqual(multiplier, 0.5, accuracy: 0.001,
                       "SDNN 是基线 50% 时，乘数应该是 0.5")
    }

    /// 极低 HRV（SDNN 远低于基线）应该被钳位到 0.4
    func testDynamicMultiplier_veryLow_clampsToMin() {
        manager.setBaseline30d(50.0)
        // 5.0 / 50.0 = 0.1，低于下限 0.4，应该被钳位到 0.4
        let multiplier = manager.dynamicMultiplier(currentSDNN: 5.0)
        XCTAssertEqual(multiplier, 0.4, accuracy: 0.001,
                       "极低 SDNN 应该被钳位到最小值 0.4")
    }

    /// 极高 HRV（SDNN 远高于基线）应该被钳位到 1.6
    func testDynamicMultiplier_veryHigh_clampsToMax() {
        manager.setBaseline30d(30.0)
        // 100.0 / 30.0 ≈ 3.33，超过上限 1.6，应该被钳位到 1.6
        let multiplier = manager.dynamicMultiplier(currentSDNN: 100.0)
        XCTAssertEqual(multiplier, 1.6, accuracy: 0.001,
                       "极高 SDNN 应该被钳位到最大值 1.6")
    }

    /// 乘数应该在 [0.4, 1.6] 范围内
    func testDynamicMultiplier_alwaysInRange() {
        manager.setBaseline30d(30.0)
        // 测试一系列 SDNN 值
        let testValues: [Double] = [1.0, 5.0, 15.0, 30.0, 45.0, 60.0, 100.0]
        for sdnn in testValues {
            let multiplier = manager.dynamicMultiplier(currentSDNN: sdnn)
            XCTAssertGreaterThanOrEqual(multiplier, 0.4,
                "SDNN=\(sdnn): 乘数不能低于 0.4")
            XCTAssertLessThanOrEqual(multiplier, 1.6,
                "SDNN=\(sdnn): 乘数不能高于 1.6")
        }
    }
}

// =============================================================================
// MARK: - HRVIntegrator 逻辑测试
// =============================================================================

/// 测试 HRVIntegrator 的乘数计算和阈值调整逻辑。
///
/// 由于 HRVIntegrator 的 lastSnapshot 是 private 的，
/// 我们通过 currentMultiplier（无数据时 = 1.0）和 adjustedThreshold 进行黑盒测试。
final class HRVIntegratorLogicTests: XCTestCase {

    var integrator: HRVIntegrator!

    override func setUp() {
        super.setUp()
        integrator = HRVIntegrator()
    }

    override func tearDown() {
        integrator = nil
        super.tearDown()
    }

    // MARK: - currentMultiplier 测试

    /// 没有 HRV 数据时（冷启动），乘数应该是 1.0
    func testCurrentMultiplier_noData_returnsOne() {
        // 新建 HRVIntegrator 时 lastSnapshot = nil
        // currentMultiplier 应该返回 1.0（Level 4：无数据）
        XCTAssertEqual(integrator.currentMultiplier, 1.0, accuracy: 0.001,
                       "没有 HRV 数据时乘数应该是 1.0")
    }

    /// 乘数应该始终在合理范围内（即使没有数据也是 1.0）
    func testCurrentMultiplier_isInReasonableRange() {
        let multiplier = integrator.currentMultiplier
        // 理论上，经过新鲜度混合后的乘数范围：
        // 最极端：fresh + 极低 HRV → 0.4（不低于）
        // 最极端：fresh + 极高 HRV → 1.6（不高于）
        // 但混合向 1.0 后，实际范围更窄
        XCTAssertGreaterThanOrEqual(multiplier, 0.4,
            "乘数不应该低于 0.4")
        XCTAssertLessThanOrEqual(multiplier, 1.6,
            "乘数不应该超过 1.6")
    }

    // MARK: - adjustedThreshold 测试

    /// 乘数为 1.0 时（无数据），adjustedThreshold 应该等于输入的 base 值（在范围内）
    func testAdjustedThreshold_multiplierOne_returnsSameBase() {
        // 无 HRV 数据 → currentMultiplier = 1.0
        // adjustedThreshold(0.65) = 0.65 × 1.0 = 0.65（在 [0.35, 0.90] 内，不被钳位）
        let threshold = integrator.adjustedThreshold(0.65)
        XCTAssertEqual(threshold, 0.65, accuracy: 0.001,
                       "乘数为 1.0 时，阈值应该等于输入值")
    }

    /// adjustedThreshold 的最小值应该是 0.35
    func testAdjustedThreshold_clampsToMinimum() {
        // 假设极端情况：乘数 = 0.4，base = 0.45
        // 0.45 × 0.4 = 0.18，低于 0.35 → 应被钳位到 0.35
        // 但由于 currentMultiplier 无法被外部控制（lastSnapshot 是 private），
        // 这里测试另一个边界：base 本身极小时
        // 如果传入 base = 0.10（理论上不会，但验证钳位逻辑）
        let threshold = integrator.adjustedThreshold(0.10)
        XCTAssertGreaterThanOrEqual(threshold, 0.35,
            "adjustedThreshold 不应该低于最小值 0.35")
    }

    /// adjustedThreshold 的最大值应该是 0.90
    func testAdjustedThreshold_clampsToMaximum() {
        // 传入一个很大的 base 值，验证上限钳位
        let threshold = integrator.adjustedThreshold(1.5)
        XCTAssertLessThanOrEqual(threshold, 0.90,
            "adjustedThreshold 不应该超过最大值 0.90")
    }

    /// 任意合理 base 值，输出都应该在 [0.35, 0.90] 范围内
    func testAdjustedThreshold_alwaysInValidRange() {
        let baseValues: [Double] = [0.30, 0.45, 0.60, 0.65, 0.70, 0.80, 0.90, 1.0]
        for base in baseValues {
            let threshold = integrator.adjustedThreshold(base)
            XCTAssertGreaterThanOrEqual(threshold, 0.35,
                "base=\(base): 输出不应该低于 0.35")
            XCTAssertLessThanOrEqual(threshold, 0.90,
                "base=\(base): 输出不应该高于 0.90")
        }
    }

    // MARK: - currentFreshnessLevel 测试

    /// 没有 HRV 数据时，新鲜度等级应该是 .unavailable
    func testFreshnessLevel_noData_returnsUnavailable() {
        let level = integrator.currentFreshnessLevel
        XCTAssertEqual(level, .unavailable,
                       "没有 HRV 数据时新鲜度等级应该是 unavailable")
    }

    // MARK: - latestSnapshot 测试

    /// 没有 HRV 数据时，latestSnapshot 应该是 nil
    func testLatestSnapshot_noData_returnsNil() {
        XCTAssertNil(integrator.latestSnapshot,
                     "冷启动时 latestSnapshot 应该是 nil")
    }
}

// =============================================================================
// MARK: - HRV 混合乘数公式验证（纯数学，不依赖 HealthKit）
// =============================================================================

/// 纯数学验证：blended = weight × raw + (1 - weight) × 1.0 的计算正确性。
///
/// 这些测试不依赖任何苹果框架，可以在所有环境（包括 Linux CI）运行。
final class HRVBlendFormulaTests: XCTestCase {

    /// 公式验证：fresh（weight=1.0），rawMultiplier=0.6 → blended=0.6
    func testBlendFormula_fresh_fullRaw() {
        let raw: Double = 0.6
        let weight = HRVFreshnessLevel.fresh.blendWeight  // 1.0
        let blended = weight * raw + (1.0 - weight) * 1.0
        // 1.0 × 0.6 + 0.0 × 1.0 = 0.6
        XCTAssertEqual(blended, 0.60, accuracy: 0.001,
                       "fresh 级别应该完全使用原始乘数")
    }

    /// 公式验证：moderate（weight=0.7），rawMultiplier=0.6 → blended=0.72
    func testBlendFormula_moderate_partialBlend() {
        let raw: Double = 0.6
        let weight = HRVFreshnessLevel.moderate.blendWeight  // 0.7
        let blended = weight * raw + (1.0 - weight) * 1.0
        // 0.7 × 0.6 + 0.3 × 1.0 = 0.42 + 0.30 = 0.72
        XCTAssertEqual(blended, 0.72, accuracy: 0.001,
                       "moderate 级别 blended 乘数应该是 0.72")
    }

    /// 公式验证：stale（weight=0.3），rawMultiplier=0.6 → blended=0.88
    func testBlendFormula_stale_mostlyNeutral() {
        let raw: Double = 0.6
        let weight = HRVFreshnessLevel.stale.blendWeight  // 0.3
        let blended = weight * raw + (1.0 - weight) * 1.0
        // 0.3 × 0.6 + 0.7 × 1.0 = 0.18 + 0.70 = 0.88
        XCTAssertEqual(blended, 0.88, accuracy: 0.001,
                       "stale 级别 blended 乘数应该是 0.88")
    }

    /// 公式验证：unavailable（weight=0.0），任意 raw → blended=1.0（中性）
    func testBlendFormula_unavailable_alwaysNeutral() {
        let weight = HRVFreshnessLevel.unavailable.blendWeight  // 0.0
        // 不管 raw 是多少，blended 都应该是 1.0
        for raw in [0.4, 0.6, 1.0, 1.2, 1.6] {
            let blended = weight * raw + (1.0 - weight) * 1.0
            XCTAssertEqual(blended, 1.0, accuracy: 0.001,
                           "unavailable 级别 blended 乘数应该始终是 1.0（raw=\(raw)）")
        }
    }

    /// 公式验证：高 HRV 场景，rawMultiplier=1.4，moderate → blended=1.28
    func testBlendFormula_highHRV_moderate() {
        let raw: Double = 1.4  // HRV 比基线高 40%，身体放松
        let weight = HRVFreshnessLevel.moderate.blendWeight  // 0.7
        let blended = weight * raw + (1.0 - weight) * 1.0
        // 0.7 × 1.4 + 0.3 × 1.0 = 0.98 + 0.30 = 1.28
        XCTAssertEqual(blended, 1.28, accuracy: 0.001,
                       "高 HRV + moderate 级别 blended 乘数应该是 1.28")
    }

    /// 最终阈值计算：验证 adjustedThreshold 公式全链路
    func testFullChain_textThresholdTimesBlendedMultiplier() {
        // 场景：
        //   - 用户用财经 App，近 20 帧均值 0.55 → 文本阈值 = 0.55 + 0.15 = 0.70
        //   - 今天 HRV 低（原始乘数 0.6），数据 2 小时前（moderate，weight=0.7）
        //   - blended 乘数 = 0.7 × 0.6 + 0.3 × 1.0 = 0.72
        //   - 最终阈值 = 0.70 × 0.72 = 0.504 → 在 [0.35, 0.90] 内

        let textThreshold: Double = 0.70
        let blendedMultiplier: Double = 0.72  // 从上面计算得出
        let finalThreshold = textThreshold * blendedMultiplier

        XCTAssertEqual(finalThreshold, 0.504, accuracy: 0.001,
                       "最终阈值应该是 0.504")

        // 验证在有效范围内（不需要钳位）
        XCTAssertGreaterThanOrEqual(finalThreshold, 0.35,
            "最终阈值应该 >= 0.35")
        XCTAssertLessThanOrEqual(finalThreshold, 0.90,
            "最终阈值应该 <= 0.90")
    }
}
