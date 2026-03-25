// FacePatterns.swift
// ScreenMindMac — M10 LED 矩阵表情图案定义
//
// 本文件定义 5 种情绪表情的 16×16 像素数组，
// 每个像素用 (r, g, b) 三元组表示颜色，(0,0,0) 表示熄灭。
//
// 情绪 → 表情对应关系（基于焦虑分数区间）：
//   < 0.40  → ID 0: 大笑脸    绿色    ：状态极好，放心刷
//   0.40–0.60 → ID 1: 微笑脸  浅绿色  ：正常，轻微关注
//   0.60–0.70 → ID 2: 中性脸  黄色    ：有点焦虑，建议留意
//   0.70–0.85 → ID 3: 担忧脸  橙色    ：焦虑升高，建议休息
//   ≥ 0.85  → ID 4: 痛苦脸    红色    ：高度焦虑，立即休息！
//
// 16×16 点阵存储方式：
//   二维数组 [行][列]，行 0 是顶行，行 15 是底行。
//   每个元素是 (UInt8, UInt8, UInt8) 元组，代表 RGB 颜色。
//   WS2812B 实际使用 GRB 顺序，转换在 LEDMatrixController 里做。
//
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

// MARK: - 颜色常量（降低亮度，避免刺眼，室内使用建议亮度 20–60/255）

/// 亮度系数（0.0–1.0），统一调整所有图案亮度。
/// 白天可调高到 1.0，夜间建议 0.3。
public let kLEDBrightnessScale: Double = 0.5

/// 把 RGB 三元组按亮度缩放（结果仍然是 UInt8，自动截断）
private func c(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
    let s = kLEDBrightnessScale
    return (
        UInt8(min(255, Double(r) * s)),
        UInt8(min(255, Double(g) * s)),
        UInt8(min(255, Double(b) * s))
    )
}

// MARK: - 颜色预设（便于图案设计时引用）

private let OFF: (UInt8, UInt8, UInt8) = (0, 0, 0)          // 熄灭

// 绿色系（大笑/微笑）
private let GN = c(0, 255, 80)    // 明亮绿（脸轮廓）
private let GD = c(0, 180, 50)    // 深绿（眼睛/嘴巴细节）

// 黄色（中性脸）
private let YL = c(255, 220, 0)   // 亮黄
private let YD = c(200, 160, 0)   // 深黄

// 橙色（担忧脸）
private let OR = c(255, 130, 0)   // 橙
private let OD = c(200, 90, 0)    // 深橙

// 红色（痛苦脸）
private let RD = c(255, 40, 40)   // 亮红
private let RS = c(200, 0, 0)     // 深红

// 白色（眼白 / 牙齿）
private let WH = c(180, 180, 180) // 浅灰白（避免纯白过亮）

// MARK: - FacePattern 结构体

/// 一个 16×16 LED 表情图案。
/// `pixels` 是 16 行 × 16 列的 RGB 颜色数组。
public struct FacePattern {
    public let id: Int
    public let name: String
    public let anxietyRange: ClosedRange<Double>?  // nil 表示手动模式
    public let pixels: [[(UInt8, UInt8, UInt8)]]   // [行][列] RGB

    /// 把二维像素展开成一维（WS2812B 矩阵逐行寻址用）
    /// 奇数行（index 1, 3, 5…）做"蛇形"折叠：从右向左
    /// （取决于实物接线方式，此处假设为 S 型蛇形接线）
    public func flatten(serpentine: Bool = true) -> [(UInt8, UInt8, UInt8)] {
        var result: [(UInt8, UInt8, UInt8)] = []
        for (rowIdx, row) in pixels.enumerated() {
            // 蛇形：偶数行从左到右，奇数行从右到左
            if serpentine && (rowIdx % 2 == 1) {
                result.append(contentsOf: row.reversed())
            } else {
                result.append(contentsOf: row)
            }
        }
        return result
    }
}

// MARK: - FacePatterns 静态图案库

/// 全局图案库，包含 5 种情绪表情。
/// LEDMatrixController 根据焦虑分数从这里查找对应图案。
public enum FacePatterns {

    // ─────────────────────────────────────────────────────────────────────
    // ID 0：大笑脸（焦虑分 < 0.40，绿色，状态极好）
    //
    //   ████████████████   ← 脸轮廓（绿色外圈）
    //   █ WH WH ... WH █
    //   █ WH GD WH GD █   ← 眼睛（深绿点）
    //   █ WH WH WH WH █
    //   █ GD WH ... GD █  ← 嘴角上扬（深绿弧线）
    //   █ WH GD GD WH █
    //   ████████████████
    //
    // 说明：每行 16 列，总共 16 行。
    // ─────────────────────────────────────────────────────────────────────
    public static let bigSmile = FacePattern(
        id: 0, name: "大笑脸",
        anxietyRange: 0.0...0.399,
        pixels: [
            // 行 0：顶部轮廓
            [OFF, OFF, GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  OFF, OFF],
            // 行 1
            [OFF, GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN,  OFF],
            // 行 2：眼睛行1（眼白背景）
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            // 行 3：眼睛（两只眼睛，各 2×2 的深绿块）
            [GN,  WH,  WH,  GD,  GD,  WH,  WH,  WH,  WH,  WH,  GD,  GD,  WH,  WH,  WH,  GN],
            // 行 4：眼睛下沿
            [GN,  WH,  WH,  GD,  GD,  WH,  WH,  WH,  WH,  WH,  GD,  GD,  WH,  WH,  WH,  GN],
            // 行 5：眼睛到嘴巴之间
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            // 行 6：嘴角两端上扬（大笑特征）
            [GN,  WH,  GD,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GD,  WH,  GN],
            // 行 7：嘴巴顶行（深绿弧线）
            [GN,  WH,  WH,  GD,  GD,  WH,  WH,  WH,  WH,  WH,  GD,  GD,  WH,  WH,  WH,  GN],
            // 行 8：嘴巴内（牙齿——白色横条）
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            // 行 9：嘴巴底行（深绿弧线收口）
            [GN,  WH,  WH,  WH,  GD,  GD,  GD,  GD,  GD,  GD,  GD,  WH,  WH,  WH,  WH,  GN],
            // 行 10：下巴区域
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            // 行 11
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            // 行 12
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            // 行 13
            [OFF, GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN,  OFF],
            // 行 14：底部轮廓
            [OFF, OFF, GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  OFF, OFF],
            // 行 15：空行（使图案不顶到矩阵边缘）
            [OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF],
        ]
    )

    // ─────────────────────────────────────────────────────────────────────
    // ID 1：微笑脸（焦虑分 0.40–0.60，浅绿色，正常状态）
    // 与大笑脸类似，但嘴巴弧度较小，眼睛稍小
    // ─────────────────────────────────────────────────────────────────────
    public static let smile = FacePattern(
        id: 1, name: "微笑脸",
        anxietyRange: 0.40...0.599,
        pixels: [
            [OFF, OFF, GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  OFF, OFF],
            [OFF, GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN,  OFF],
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            [GN,  WH,  WH,  GD,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GD,  WH,  WH,  WH,  GN],
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            [GN,  WH,  WH,  WH,  GD,  GD,  GD,  GD,  GD,  GD,  WH,  WH,  WH,  WH,  WH,  GN],
            [GN,  WH,  WH,  GD,  WH,  WH,  WH,  WH,  WH,  WH,  GD,  WH,  WH,  WH,  WH,  GN],
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            [GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN],
            [OFF, GN,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  GN,  OFF],
            [OFF, OFF, GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  GN,  OFF, OFF],
            [OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF],
        ]
    )

    // ─────────────────────────────────────────────────────────────────────
    // ID 2：中性脸（焦虑分 0.60–0.70，黄色，有点焦虑）
    // 嘴巴是一条直线（既不上扬也不下弯），眼睛平视
    // ─────────────────────────────────────────────────────────────────────
    public static let neutral = FacePattern(
        id: 2, name: "中性脸",
        anxietyRange: 0.60...0.699,
        pixels: [
            [OFF, OFF, YL,  YL,  YL,  YL,  YL,  YL,  YL,  YL,  YL,  YL,  YL,  YL,  OFF, OFF],
            [OFF, YL,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  YL,  OFF],
            [YL,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  YL],
            [YL,  WH,  WH,  YD,  YD,  WH,  WH,  WH,  WH,  WH,  YD,  YD,  WH,  WH,  WH,  YL],
            [YL,  WH,  WH,  YD,  YD,  WH,  WH,  WH,  WH,  WH,  YD,  YD,  WH,  WH,  WH,  YL],
            [YL,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  YL],
            [YL,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  YL],
            [YL,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  YL],
            // 嘴巴：一条直线
            [YL,  WH,  WH,  WH,  YD,  YD,  YD,  YD,  YD,  YD,  YD,  WH,  WH,  WH,  WH,  YL],
            [YL,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  YL],
            [YL,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  YL],
            [YL,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  YL],
            [YL,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  YL],
            [OFF, YL,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  YL,  OFF],
            [OFF, OFF, YL,  YL,  YL,  YL,  YL,  YL,  YL,  YL,  YL,  YL,  YL,  YL,  OFF, OFF],
            [OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF],
        ]
    )

    // ─────────────────────────────────────────────────────────────────────
    // ID 3：担忧脸（焦虑分 0.70–0.85，橙色，建议休息）
    // 眉毛下压（内侧上扬），嘴角轻微下弯
    // ─────────────────────────────────────────────────────────────────────
    public static let worried = FacePattern(
        id: 3, name: "担忧脸",
        anxietyRange: 0.70...0.849,
        pixels: [
            [OFF, OFF, OR,  OR,  OR,  OR,  OR,  OR,  OR,  OR,  OR,  OR,  OR,  OR,  OFF, OFF],
            [OFF, OR,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  OR,  OFF],
            [OR,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  OR],
            // 眉毛：两段内侧高、外侧低（皱眉）
            [OR,  WH,  WH,  OD,  WH,  OD,  WH,  WH,  WH,  OD,  WH,  OD,  WH,  WH,  WH,  OR],
            [OR,  WH,  OD,  WH,  OD,  WH,  WH,  WH,  WH,  WH,  OD,  WH,  OD,  WH,  WH,  OR],
            // 眼睛
            [OR,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  OR],
            [OR,  WH,  WH,  OD,  OD,  WH,  WH,  WH,  WH,  WH,  OD,  OD,  WH,  WH,  WH,  OR],
            [OR,  WH,  WH,  OD,  OD,  WH,  WH,  WH,  WH,  WH,  OD,  OD,  WH,  WH,  WH,  OR],
            [OR,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  OR],
            // 嘴巴：两角下弯（担忧）
            [OR,  WH,  WH,  WH,  OD,  OD,  OD,  OD,  OD,  OD,  OD,  WH,  WH,  WH,  WH,  OR],
            [OR,  WH,  WH,  OD,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  OD,  WH,  WH,  WH,  OR],
            [OR,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  OR],
            [OR,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  OR],
            [OFF, OR,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  OR,  OFF],
            [OFF, OFF, OR,  OR,  OR,  OR,  OR,  OR,  OR,  OR,  OR,  OR,  OR,  OR,  OFF, OFF],
            [OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF],
        ]
    )

    // ─────────────────────────────────────────────────────────────────────
    // ID 4：痛苦脸（焦虑分 ≥ 0.85，红色，高度焦虑，立即休息！）
    // 眉毛深度下压，眼睛变成 X 形，嘴巴大幅下弯
    // ─────────────────────────────────────────────────────────────────────
    public static let distressed = FacePattern(
        id: 4, name: "痛苦脸",
        anxietyRange: 0.85...1.0,
        pixels: [
            [OFF, OFF, RD,  RD,  RD,  RD,  RD,  RD,  RD,  RD,  RD,  RD,  RD,  RD,  OFF, OFF],
            [OFF, RD,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  RD,  OFF],
            [RD,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  RD],
            // 眉毛（大幅皱眉：内侧高，向外急剧下降）
            [RD,  WH,  WH,  RS,  WH,  RS,  WH,  WH,  WH,  RS,  WH,  RS,  WH,  WH,  WH,  RD],
            [RD,  WH,  RS,  WH,  RS,  WH,  WH,  WH,  WH,  WH,  RS,  WH,  RS,  WH,  WH,  RD],
            // 空行
            [RD,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  RD],
            // 眼睛：X 形（交叉，表示"眼泪汪汪"或"昏厥"）
            [RD,  WH,  WH,  RS,  WH,  RS,  WH,  WH,  WH,  RS,  WH,  RS,  WH,  WH,  WH,  RD],
            [RD,  WH,  WH,  WH,  RS,  WH,  WH,  WH,  WH,  WH,  RS,  WH,  WH,  WH,  WH,  RD],
            [RD,  WH,  WH,  RS,  WH,  RS,  WH,  WH,  WH,  RS,  WH,  RS,  WH,  WH,  WH,  RD],
            // 嘴巴：大幅下弯（痛苦哭脸）
            [RD,  WH,  WH,  RS,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  RS,  WH,  WH,  WH,  RD],
            [RD,  WH,  WH,  WH,  RS,  RS,  RS,  RS,  RS,  RS,  RS,  WH,  WH,  WH,  WH,  RD],
            [RD,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  RD],
            [RD,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  RD],
            [OFF, RD,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  WH,  RD,  OFF],
            [OFF, OFF, RD,  RD,  RD,  RD,  RD,  RD,  RD,  RD,  RD,  RD,  RD,  RD,  OFF, OFF],
            [OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF],
        ]
    )

    // MARK: - 图案查找

    /// 所有图案按 ID 排序（方便遍历）
    public static let all: [FacePattern] = [bigSmile, smile, neutral, worried, distressed]

    /// 根据焦虑分数返回对应表情图案。
    /// 如果分数不在任何区间内（理论上不会发生），返回中性脸作为默认值。
    public static func pattern(for anxietyScore: Double) -> FacePattern {
        // 按区间范围依次匹配，找到第一个包含该分数的图案
        return all.first { pattern in
            guard let range = pattern.anxietyRange else { return false }
            return range.contains(anxietyScore)
        } ?? neutral  // 找不到时兜底返回中性脸
    }

    /// 根据图案 ID 直接查找（Arduino 端通过 ID 触发，不用传完整像素）
    public static func pattern(id: Int) -> FacePattern? {
        return all.first { $0.id == id }
    }
}
