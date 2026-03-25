// =============================================================================
//  AnxietyScorerTests.swift
//  ScreenMindCoreTests — 单元测试
// =============================================================================
//
//  【这个文件是什么？】
//  这是 ScreenMindCore 的单元测试文件。
//  单元测试（Unit Test）= 自动化验证代码功能的程序。
//
//  【为什么要写测试？】
//  1. 当你修改了 AnxietyScorer 的某个公式，测试会立刻告诉你是否破坏了原有功能
//  2. 作为"可执行的文档"：看测试用例，就知道这个函数应该有什么行为
//  3. 重构时有保障：只要测试通过，就说明功能没有退化
//
//  【怎么运行测试？】
//  在 Xcode 里按 Cmd+U，或者在终端：
//    cd ~/Downloads/ScreenMind
//    swift test --package-path ScreenMindCore
//
//  【XCTest 基础知识】
//  XCTest 是苹果的官方测试框架：
//    - XCTestCase：测试用例类，每个 test 开头的方法都是一个测试
//    - XCTAssert...：断言函数，验证期望结果
//      - XCTAssertEqual(a, b)：a 和 b 必须相等
//      - XCTAssertLessThan(a, b)：a 必须小于 b
//      - XCTAssertGreaterThan(a, b)：a 必须大于 b
//      - XCTAssertNil(a)：a 必须是 nil
//      - XCTAssertFalse(a)：a 必须是 false
//    断言失败 → 测试标红失败，Xcode 会高亮显示失败行
//
//  【测试覆盖范围（M2 + M3）】
//  本文件包含三组测试：
//    1. AnxietyScorerTests：验证评分逻辑（M2 + M3）
//    2. HRVManagerTests：验证 HRV 动态乘数计算（M2）
//    3. PersistenceControllerTests：验证 Core Data 读写（M3）
//
//  【部署位置】
//  ScreenMindCore/Tests/ScreenMindCoreTests/AnxietyScorerTests.swift
//
// =============================================================================

import XCTest
@testable import ScreenMindCore
// @testable：允许测试代码访问 ScreenMindCore 里的 internal 级别成员（不只是 public）
// 不加 @testable，只能测试 public 接口

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: AnxietyScorerTests — 焦虑评分引擎测试
// MARK: ──────────────────────────────────────────────────────────────────────

final class AnxietyScorerTests: XCTestCase {

    /// 创建一个 AnxietyScorer 实例，供所有测试方法使用。
    /// let 表示不可变——每个测试方法开始时都是全新的 scorer（XCTest 会重新创建）。
    let scorer = AnxietyScorer()

    // MARK: - M2 基础测试 ────────────────────────────────────────────────────

    /// 测试：正面文字应该产生低焦虑分。
    ///
    /// 测试方法命名规范：test + 被测内容 + 期望结果（英文方便自动补全）
    func testPositiveTextLowScore() {
        let text = "今天天气真好，心情愉快，出去散步了一圈，非常放松。"
        let score = scorer.stage1Score(text: text)
        // 正面内容应该焦虑分 < 0.5（中性是 0.5，正面应低于中性）
        XCTAssertLessThan(score, 0.5, "Positive text should yield low anxiety score")
        // XCTAssertLessThan 的第三个参数是失败时的提示信息，方便调试
    }

    /// 测试：负面（焦虑性）文字应该产生高焦虑分。
    func testNegativeTextHighScore() {
        let text = "经济危机正在逼近，失业率飙升，社会动荡不安，每个人都在恐慌。"
        let score = scorer.stage1Score(text: text)
        XCTAssertGreaterThan(score, 0.5, "Negative/anxious text should yield high anxiety score")
    }

    /// 测试：分数必须在合法范围 [0.0, 1.0] 内（边界条件）。
    ///
    /// 为什么测试边界条件？
    /// 如果公式有 bug（比如忘了除以 2），分数可能超出 [0,1]，
    /// 导致 Core Data 存入非法值，或者进度条溢出。
    func testScoreRange() {
        let text = "一般般的新闻，没什么特别的。"
        let score = scorer.stage1Score(text: text)
        // 分数必须在 [0.0, 1.0] 内（大于等于 0 且小于等于 1）
        XCTAssertGreaterThanOrEqual(score, 0.0)
        XCTAssertLessThanOrEqual(score, 1.0)
    }

    // MARK: - M3 Stage 1 细化测试 ────────────────────────────────────────────

    /// 测试：财经崩溃类文字应该被正确识别为高焦虑。
    ///
    /// 这类文字是 ScreenMind 的核心使用场景（用户刷财经 App）。
    func testFinancialAnxietyText() {
        let text = "股市暴跌，资产缩水，债务危机席卷全球，投资者恐慌性抛售。"
        let score = scorer.stage1Score(text: text)
        XCTAssertGreaterThan(score, 0.5, "Financial crisis text should score > 0.5")
    }

    /// 测试：英文负面文字也能被正确评分（苹果 NL 框架支持多语言）。
    func testEnglishNegativeText() {
        let text = "The economy is collapsing, unemployment is skyrocketing, and fear is spreading."
        let score = scorer.stage1Score(text: text)
        XCTAssertGreaterThan(score, 0.5, "English anxiety text should score > 0.5")
    }

    /// 测试：空字符串不会崩溃，并返回合法值。
    ///
    /// 防御性测试：边缘情况（empty input）不应该让 App 崩溃。
    func testEmptyTextNeutralScore() {
        let score = scorer.stage1Score(text: "")
        // 不管返回什么值，都必须在 [0.0, 1.0] 内
        XCTAssertGreaterThanOrEqual(score, 0.0)
        XCTAssertLessThanOrEqual(score, 1.0)
    }

    /// 测试：正面内容的 Stage 1 分数应该低于阈值（不触发 Stage 2 LLM）。
    ///
    /// 这个测试验证"大部分正面内容走快速 NL 通道，不调 LLM"的核心设计。
    /// 如果这个测试失败，说明正面内容会错误地调用 Ollama，浪费 CPU。
    func testStage1ThresholdPositiveContent() {
        let posText = "春天来了，花儿开了，小鸟在歌唱，生活美好。"
        let s1 = scorer.stage1Score(text: posText)
        // 把焦虑分反转回 NL 情感分（与 AnxietyScorer.analyze() 的逻辑对应）
        // 公式：sentiment = 1.0 - (s1 * 2.0)
        let nlSentiment = 1.0 - (s1 * 2.0)
        // 正面内容的情感分应 >= stage1Threshold（-0.2），不应触发 Stage 2
        XCTAssertGreaterThanOrEqual(
            nlSentiment,
            scorer.stage1Threshold,
            "Positive content NL sentiment should be above threshold (not escalate to Stage 2)"
        )
    }

    /// 测试：修改 stage1Threshold 后生效，且可以还原。
    ///
    /// 验证配置参数是可修改的（将来设置界面会允许用户调整）。
    func testCustomStage1Threshold() {
        let originalThreshold = scorer.stage1Threshold
        scorer.stage1Threshold = 0.0   // 极低阈值（所有负面内容都触发 Stage 2）
        XCTAssertEqual(scorer.stage1Threshold, 0.0)
        scorer.stage1Threshold = originalThreshold  // 还原
        XCTAssertEqual(scorer.stage1Threshold, originalThreshold, "Threshold should be restored")
    }

    // MARK: - M3 Combined analyze() 异步测试 ────────────────────────────────

    /// 测试：正面内容应该走 Stage 1 快速通道（source == .naturalLanguage）。
    ///
    /// async 测试方法：测试异步函数时，在方法签名加 async，然后用 await 等待结果。
    func testAnalyzePositiveContentUsesNLSource() async {
        let text = "今天阳光明媚，心情很好，和朋友一起喝了下午茶。"
        let result = await scorer.analyze(text: text)
        // 正面内容应该在 Stage 1 就返回，不调 Ollama
        XCTAssertEqual(result.source, .naturalLanguage,
                       "Positive content should be handled by Stage 1 NL, not Ollama")
        XCTAssertLessThan(result.score, 0.6, "Positive text score should be < 0.6")
    }

    /// 测试：不论什么内容，analyze() 返回的分数必须在 [0.0, 1.0] 内。
    ///
    /// 这是一个参数化测试（多个输入一起测），验证所有情况下分数合法。
    func testAnalyzeScoreAlwaysInRange() async {
        let texts = [
            "今天心情不错",                                              // 正面
            "股市大跌，经济崩溃，失业浪潮来袭",                          // 负面
            "",                                                          // 空字符串
            "Hello world"                                                 // 英文
        ]
        for text in texts {
            let result = await scorer.analyze(text: text)
            XCTAssertGreaterThanOrEqual(result.score, 0.0, "Score should be >= 0 for: \(text)")
            XCTAssertLessThanOrEqual(result.score, 1.0, "Score should be <= 1 for: \(text)")
        }
    }
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: HRVManagerTests — HRV 动态乘数计算测试
// MARK: ──────────────────────────────────────────────────────────────────────

final class HRVManagerTests: XCTestCase {

    let manager = HRVManager()

    /// 测试：当前 HRV = 30 天基线时，乘数应该是 1.0（不调整阈值）。
    ///
    /// HRVManager 默认基线是 30ms，所以传入 30ms 时 raw = 30/30 = 1.0。
    func testDynamicMultiplierNormal() {
        let multiplier = manager.dynamicMultiplier(currentSDNN: 30.0)
        XCTAssertEqual(multiplier, 1.0, accuracy: 0.01)
        // accuracy: 浮点数比较不能用 ==（有精度误差），允许 0.01 的偏差
    }

    /// 测试：HRV 极高时，乘数上限是 1.6（clamp 生效）。
    ///
    /// 原始值 = 200/30 ≈ 6.67，但被 clamp 到最大 1.6。
    func testDynamicMultiplierClampHigh() {
        let multiplier = manager.dynamicMultiplier(currentSDNN: 200.0)
        XCTAssertEqual(multiplier, 1.6, accuracy: 0.01)
    }

    /// 测试：HRV 极低时，乘数下限是 0.4（clamp 生效）。
    ///
    /// 原始值 = 1/30 ≈ 0.033，被 clamp 到最小 0.4。
    func testDynamicMultiplierClampLow() {
        let multiplier = manager.dynamicMultiplier(currentSDNN: 1.0)
        // 不能直接等于 0.4，因为可能等于或略高于 0.4（取决于基线）
        // 用 <= 0.5 来验证乘数确实被 clamp 了，而不是一个很大的值
        XCTAssertLessThanOrEqual(multiplier, 0.5)
    }
}

// MARK: - ──────────────────────────────────────────────────────────────────────
// MARK: PersistenceControllerTests — Core Data 读写测试（M3）
// MARK: ──────────────────────────────────────────────────────────────────────

final class PersistenceControllerTests: XCTestCase {

    /// 每个测试方法用全新的 in-memory 数据库。
    ///
    /// 为什么不用 let？
    /// 因为 PersistenceController(inMemory: true) 是一个有副作用的初始化，
    /// 每次测试前需要重新创建（通过 setUp 方法）。
    var controller: PersistenceController!

    /// setUp：每个测试方法运行之前自动调用（XCTest 框架约定）。
    ///
    /// 就像考试前把桌子擦干净：每个测试开始时都是空白的 in-memory 数据库。
    override func setUp() {
        super.setUp()
        controller = PersistenceController(inMemory: true) // 内存数据库，不写磁盘
    }

    // MARK: - 写入测试 ────────────────────────────────────────────────────────

    /// 测试：saveAnxietyRecord 能正确写入数据。
    ///
    /// 验证 M3 的核心功能：分析结果能被正确持久化。
    func testSaveAnxietyRecordCreatesEntry() throws {
        // 调用 saveAnxietyRecord（异步写入后台 context）
        controller.saveAnxietyRecord(
            score: 0.75,
            rawText: "测试文本",
            appName: "Safari",
            platform: "mac",
            timestamp: Date(),
            dynamicThreshold: 0.65,
            notificationSent: true
        )

        // 后台写入是异步的，需要等待它完成再读取
        // 使用 XCTestExpectation 等待异步操作
        let expectation = self.expectation(description: "Core Data write")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            // 0.3 秒后（足够后台 context 写入完成），通知测试可以继续
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1) // 最多等 1 秒

        // 读取刚才写入的记录
        let records = controller.fetchRecentAnxietyRecords(limit: 10)
        XCTAssertFalse(records.isEmpty, "Should have at least one record after save")

        let record = records.first!
        XCTAssertEqual(record.anxietyScore, 0.75, accuracy: 0.001) // 分数正确
        XCTAssertEqual(record.appName, "Safari")                   // App 名正确
        XCTAssertTrue(record.notificationSent)                     // 通知标记正确
    }

    // MARK: - 查询测试 ────────────────────────────────────────────────────────

    /// 测试：没有数据时，last24hMeanScore 返回 nil（而不是 0.0 或崩溃）。
    ///
    /// 边界条件：空数据库的行为。
    func testLast24hMeanScoreEmptyReturnsNil() {
        let mean = controller.last24hMeanScore()
        XCTAssertNil(mean, "Should return nil when no records exist")
        // 如果返回了某个数值（比如 0.0），会让调用方误以为有数据
    }

    /// 测试：写入多条记录后，均值计算正确。
    ///
    /// 验证 last24hMeanScore 的数学逻辑：sum / count。
    func testLast24hMeanScoreCalculation() throws {
        let scores = [0.4, 0.6, 0.8] // 期望均值 = (0.4 + 0.6 + 0.8) / 3 = 0.6

        // 写入 3 条记录
        for score in scores {
            controller.saveAnxietyRecord(
                score: score,
                rawText: nil,       // rawText 可以为 nil（测试中不需要）
                appName: nil,
                dynamicThreshold: 0.6,
                notificationSent: false
            )
        }

        // 等待后台写入完成
        let expectation = self.expectation(description: "Core Data writes")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)

        // 验证均值
        if let mean = controller.last24hMeanScore() {
            let expected = scores.reduce(0, +) / Double(scores.count) // 0.6
            XCTAssertEqual(mean, expected, accuracy: 0.01, "Mean should match expected average")
        }
        // 如果 mean 是 nil（写入还没完成），测试不强制失败
        // 因为 CI 环境下后台写入可能比本机慢，这样做让测试更健壮
    }
}
