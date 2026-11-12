//
//  DailyRadarCoverCompositionTests.swift
//  Starcat
//
//  验证封面稳定重放、跨期多样性与尺寸预算；不依赖网络、用户缓存或实际应用窗口。
//

import XCTest
@testable import Starcat

/// 只锁定产品约束，不把每条绘制路径的坐标固化为脆弱的像素快照。
final class DailyRadarCoverCompositionTests: XCTestCase {
    /// 同一报告重复构建的全部参数一致，中文及空身份也能稳定处理。
    func testReportIdentityReplaysExactly() {
        for seed in ["agents-radar:2026-11-02:ai-cli", "日报：人工智能", ""] {
            let expected = DailyRadarCoverComposition(category: "ai-cli", seed: seed)
            for _ in 0..<10 {
                XCTAssertEqual(DailyRadarCoverComposition(category: "ai-cli", seed: seed), expected)
            }
            XCTAssertNotEqual(expected.geometrySeed, expected.textureSeed)
        }
    }

    /// 每个分类均能产生六类构图；偏好不能退化为一分类一模板，日期也不能被忽略。
    /// 每个分类均能产生全部构图、配色与底场；偏好不能退化为一分类一模板。
    func testEveryCategoryHasAllStylesAndDistinctEditions() {
        let categories: [String?] = DailyRadarCatalog.fallbackCategories.map(\.id) + [nil, "future-category"]
        for category in categories {
            let compositions = (0..<256).map {
                DailyRadarCoverComposition(category: category, seed: "edition-\($0)")
            }
            let styles = Set(compositions.map(\.style))
            XCTAssertEqual(styles, Set(DailyRadarCoverStyle.allCases), category ?? "nil")
            XCTAssertEqual(Set(compositions.map(\.palette)), Set(DailyRadarCoverPalette.allCases), category ?? "nil")
            XCTAssertEqual(Set(compositions.map(\.background)), Set(DailyRadarCoverBackground.allCases), category ?? "nil")
            XCTAssertEqual(Set(compositions.map(\.geometrySeed)).count, compositions.count)
            for composition in compositions {
                XCTAssertTrue((0..<1).contains(composition.hue))
                XCTAssertTrue((0..<1).contains(composition.accentHue))
                XCTAssertTrue((0..<1).contains(composition.backgroundHue))
                XCTAssertNotEqual(composition.hue, composition.accentHue)
            }
        }
    }

    /// 历史行底色必须与封面身份一致，且始终落在 SwiftUI 可接受的色相范围内。
    func testDominantHueIsStableAndBounded() {
        for (category, seed) in [("ai-cli", "report-a"), ("ai-weekly-events", "weekly"), (nil, "中文身份")] {
            let hue = DailyRadarCoverComposition.dominantHue(category: category, seed: seed)
            XCTAssertEqual(hue, DailyRadarCoverComposition.dominantHue(category: category, seed: seed))
            XCTAssertTrue((0..<1).contains(hue))
        }
    }

    /// 分类只加权而不锁死风格，同时要使分类偏好在长期样本中确实生效。
    func testCategoryPreferenceIsWeighted() {
        let compositions = (0..<1_024).map {
            DailyRadarCoverComposition(category: "ai-agents", seed: "edition-\($0)")
        }
        let counts = Dictionary(grouping: compositions, by: \.style).mapValues(\.count)
        let preferred = counts[.network, default: 0]
        for style in DailyRadarCoverStyle.allCases where style != .network {
            XCTAssertGreaterThan(preferred, counts[style, default: 0])
        }
    }

    /// 缩略图、卡片和阅读页使用有上限的三档预算，超宽窗口不无限增加绘制开销。
    func testDetailBudgetUsesTheShortEdge() {
        XCTAssertEqual(DailyRadarCoverComposition.detailLevel(for: CGSize(width: 88, height: 56)), 0)
        XCTAssertEqual(DailyRadarCoverComposition.detailLevel(for: CGSize(width: 360, height: 160)), 1)
        XCTAssertEqual(DailyRadarCoverComposition.detailLevel(for: CGSize(width: 960, height: 320)), 2)
        XCTAssertEqual(DailyRadarCoverComposition.detailLevel(for: CGSize(width: 10_000, height: 56)), 0)
        XCTAssertEqual(DailyRadarCoverComposition.detailLevel(for: CGSize(width: 10_000, height: 10_000)), 2)
    }

    /// 异常布局输入不允许挤掉主体或把无穷坐标传给 Canvas。
    func testTextProtectionIsBounded() {
        XCTAssertEqual(DailyRadarCoverComposition.safeLeading(-1), 0)
        XCTAssertEqual(DailyRadarCoverComposition.safeLeading(0.38), 0.38)
        XCTAssertEqual(DailyRadarCoverComposition.safeLeading(1), 0.4)
        XCTAssertEqual(DailyRadarCoverComposition.safeLeading(.nan), 0)
        XCTAssertEqual(DailyRadarCoverComposition.safeLeading(.infinity), 0)
    }

    /// 参考向量锁定 PRNG 跨启动的序列；极值种子不能因无符号溢出而崩溃。
    func testRandomStreamMatchesReferenceAndHandlesExtremeSeeds() {
        var reference = SeededGenerator(seed: 0)
        XCTAssertEqual(reference.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(reference.next(), 0x6E78_9E6A_A1B9_65F4)
        for seed: UInt64 in [0, 1, .max] {
            var rng = SeededGenerator(seed: seed)
            for _ in 0..<100 {
                XCTAssertTrue((0..<1).contains(rng.double()))
                XCTAssertTrue((0..<6).contains(rng.int(6)))
            }
        }
    }
}
