import XCTest
@testable import ScreenMindCore

final class AnxietyScorerTests: XCTestCase {

    let scorer = AnxietyScorer()

    func testPositiveTextLowScore() {
        let text = "今天天气真好，心情愉快，出去散步了一圈，非常放松。"
        let score = scorer.stage1Score(text: text)
        XCTAssertLessThan(score, 0.5, "Positive text should yield low anxiety score")
    }

    func testNegativeTextHighScore() {
        let text = "经济危机正在逼近，失业率飙升，社会动荡不安，每个人都在恐慌。"
        let score = scorer.stage1Score(text: text)
        XCTAssertGreaterThan(score, 0.5, "Negative/anxious text should yield high anxiety score")
    }

    func testScoreRange() {
        let text = "一般般的新闻，没什么特别的。"
        let score = scorer.stage1Score(text: text)
        XCTAssertGreaterThanOrEqual(score, 0.0)
        XCTAssertLessThanOrEqual(score, 1.0)
    }
}

final class HRVManagerTests: XCTestCase {

    let manager = HRVManager()

    func testDynamicMultiplierNormal() {
        // When current HRV equals baseline, multiplier should be 1.0
        let multiplier = manager.dynamicMultiplier(currentSDNN: 30.0)
        XCTAssertEqual(multiplier, 1.0, accuracy: 0.01)
    }

    func testDynamicMultiplierClampHigh() {
        // Very high HRV should clamp at 1.6
        let multiplier = manager.dynamicMultiplier(currentSDNN: 200.0)
        XCTAssertEqual(multiplier, 1.6, accuracy: 0.01)
    }

    func testDynamicMultiplierClampLow() {
        // Very low HRV should clamp at 0.4
        let multiplier = manager.dynamicMultiplier(currentSDNN: 1.0)
        XCTAssertLessThanOrEqual(multiplier, 0.5)
    }
}
